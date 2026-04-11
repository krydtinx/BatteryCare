import Foundation
import Darwin
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "client")

private struct FramingParser {
    private var buffer = Data()
    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<idx]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: idx)...])
        }
        return lines
    }
}

@MainActor
public final class DaemonClient: ObservableObject {
    public static let shared = DaemonClient()

    @Published public private(set) var latestStatus: StatusUpdate?
    @Published public private(set) var isConnected: Bool = false

    private let socketPath = "/var/run/battery-care/daemon.sock"
    private var fd: Int32 = -1
    private var streamTask: Task<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Public API

    /// Start listening for status updates. Reconnects with exponential backoff (1s → 30s cap).
    public func start() {
        streamTask = Task { await self.readLoop() }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        disconnect()
    }

    /// Send a command and ignore the reply (reply arrives as a broadcast StatusUpdate).
    public func send(_ command: Command) async {
        guard fd >= 0 else { return }
        guard var data = try? encoder.encode(command) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    // MARK: - Private

    private func readLoop() async {
        var delay: UInt64 = 1_000_000_000  // 1 second in nanoseconds
        let maxDelay: UInt64 = 30_000_000_000  // 30 seconds

        while !Task.isCancelled {
            if connect() {
                await MainActor.run { self.isConnected = true }
                delay = 1_000_000_000  // reset backoff on successful connect
                await readUpdates()
                await MainActor.run { self.isConnected = false }
                disconnect()
            }

            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, maxDelay)
        }
    }

    private func readUpdates() async {
        var parser = FramingParser()
        var buf = [UInt8](repeating: 0, count: 4096)

        while !Task.isCancelled {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            let lines = parser.feed(Data(buf[0..<n]))
            for lineData in lines {
                guard let update = try? decoder.decode(StatusUpdate.self, from: lineData) else { continue }
                await MainActor.run { self.latestStatus = update }
            }
        }
    }

    private func connect() -> Bool {
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            socketPath.withCString { src in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(newFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(newFD); return false }
        fd = newFD
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}
