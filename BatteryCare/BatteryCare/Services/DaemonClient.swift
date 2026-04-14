import Foundation
import Darwin
import Combine
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "client")

// MARK: - Protocol

public protocol DaemonClientProtocol: AnyObject {
    var statusPublisher: AnyPublisher<StatusUpdate, Never> { get }
    var connectedPublisher: AnyPublisher<Bool, Never> { get }
    func start()
    func stop()
    func send(_ command: Command) async
}

// MARK: - Framing parser (inline copy — App target cannot import Daemon module)

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

// MARK: - Client

/// Connects to the Battery Care daemon socket and publishes status updates.
/// The blocking read loop runs on a dedicated Thread to avoid starving the Swift cooperative pool.
@MainActor
public final class DaemonClient: ObservableObject, DaemonClientProtocol {
    public static let shared = DaemonClient()

    @Published public private(set) var latestStatus: StatusUpdate?
    @Published public private(set) var isConnected: Bool = false

    // MARK: - DaemonClientProtocol publishers

    public var statusPublisher: AnyPublisher<StatusUpdate, Never> {
        $latestStatus.compactMap { $0 }.eraseToAnyPublisher()
    }

    public var connectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }

    private let socketPath = "/var/run/battery-care/daemon.sock"

    // fd is written/read only on `readThread`, except `stop()` which closes it under `fdLock`
    private var fd: Int32 = -1
    private let fdLock = NSLock()
    private var readThread: Thread?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Public API

    public func start() {
        guard readThread == nil else { return }
        let t = Thread { [weak self] in self?.readThreadMain() }
        t.name = "com.batterycare.daemon-client"
        t.qualityOfService = .utility
        readThread = t
        t.start()
    }

    public func stop() {
        readThread?.cancel()
        readThread = nil
        // Closing fd unblocks any in-progress read() on the read thread
        fdLock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        fdLock.unlock()
    }

    /// Send a command; reply arrives as a broadcast StatusUpdate via the read loop.
    public func send(_ command: Command) async {
        sendNow(command)
    }

    /// Synchronous variant for use in termination handlers where `await` is not available.
    public func sendNow(_ command: Command) {
        fdLock.lock()
        let currentFD = fd
        fdLock.unlock()
        guard currentFD >= 0,
              var data = try? encoder.encode(command) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { write(currentFD, $0.baseAddress!, $0.count) }
    }

    // MARK: - Read thread (runs on a dedicated Thread, not the cooperative pool)

    private func readThreadMain() {
        // Retry every 0.5s for the first 20 attempts (~10s), then back off to max 10s.
        // This ensures fast reconnect after daemon startup without hammering indefinitely.
        var attempt = 0
        var delaySeconds: Double = 0.5
        let maxDelay: Double = 10.0

        while !Thread.current.isCancelled {
            if connectSocket() {
                DispatchQueue.main.async { self.isConnected = true }
                attempt = 0
                delaySeconds = 0.5  // reset on successful connect
                readUntilDisconnect()
                closeSocket()
                DispatchQueue.main.async { self.isConnected = false }
            }

            guard !Thread.current.isCancelled else { break }
            Thread.sleep(forTimeInterval: delaySeconds)
            attempt += 1
            if attempt >= 20 {
                delaySeconds = min(delaySeconds * 2, maxDelay)
            }
        }
    }

    private func readUntilDisconnect() {
        var parser = FramingParser()
        var buf = [UInt8](repeating: 0, count: 4096)

        while !Thread.current.isCancelled {
            fdLock.lock()
            let currentFD = fd
            fdLock.unlock()
            guard currentFD >= 0 else { break }

            let n = read(currentFD, &buf, buf.count)
            guard n > 0 else { break }  // 0 = EOF, negative = error

            let lines = parser.feed(Data(buf[0..<n]))
            for lineData in lines {
                guard let update = try? decoder.decode(StatusUpdate.self, from: lineData) else { continue }
                let captured = update
                DispatchQueue.main.async { self.latestStatus = captured }
            }
        }
    }

    private func connectSocket() -> Bool {
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

        fdLock.lock()
        fd = newFD
        fdLock.unlock()
        logger.info("Connected to daemon socket")
        return true
    }

    private func closeSocket() {
        fdLock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        fdLock.unlock()
    }
}
