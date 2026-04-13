import Foundation
import Darwin
import os.log
import BatteryCareShared

// MARK: - Protocol (enables mock injection in tests)

public protocol SocketServerProtocol: AnyObject, Sendable {
    func start(onCommand: @escaping @Sendable (Command) async -> StatusUpdate) throws
    func broadcast(_ update: StatusUpdate)
    func stop()
}

// MARK: - Framing parser

/// Accumulates raw bytes and yields complete newline-delimited JSON messages.
public struct FramingParser {
    private var buffer = Data()

    public init() {}

    /// Feed new bytes; returns zero or more complete message payloads (newline stripped).
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<idx]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer = Data(buffer[buffer.index(after: idx)...])
        }
        return lines
    }
}

// MARK: - Socket errors

public enum SocketError: Error {
    case createFailed
    case bindFailed
    case listenFailed
    case acceptFailed
}

// MARK: - Implementation

public final class SocketServer: SocketServerProtocol, @unchecked Sendable {

    private let socketPath: String
    private let allowedUID: uid_t
    private var serverFD: Int32 = -1
    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "socket")
    private let clientLock = NSLock()
    private var clientFDs: [Int32] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String, allowedUID: uid_t) {
        self.socketPath = socketPath
        self.allowedUID = allowedUID
    }

    /// Set up the socket and launch the accept loop on a dedicated thread.
    public func start(onCommand: @escaping @Sendable (Command) async -> StatusUpdate) throws {
        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed }
        serverFD = fd

        // Create socket directory
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            socketPath.withCString { src in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd); serverFD = -1
            throw SocketError.bindFailed
        }

        chmod(socketPath, 0o666)

        guard listen(fd, 5) == 0 else {
            close(fd); serverFD = -1
            throw SocketError.listenFailed
        }

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(onCommand: onCommand)
        }
    }

    /// Write a status update to every connected client.
    public func broadcast(_ update: StatusUpdate) {
        guard let data = try? encoder.encode(update) else { return }
        var frame = data; frame.append(UInt8(ascii: "\n"))
        clientLock.lock()
        let fds = clientFDs
        clientLock.unlock()
        frame.withUnsafeBytes { ptr in
            for fd in fds { _ = write(fd, ptr.baseAddress!, ptr.count) }
        }
    }

    /// Close server socket and all client connections.
    public func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        unlink(socketPath)
        clientLock.lock()
        clientFDs.forEach { close($0) }
        clientFDs = []
        clientLock.unlock()
    }

    // MARK: - Private

    private func acceptLoop(onCommand: @escaping @Sendable (Command) async -> StatusUpdate) {
        while serverFD >= 0 {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &addrLen)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                logger.critical("accept() failed with errno \(errno) — socket server shutting down")
                return
            }

            // UID gate: only the app's UID may send commands
            var peerUID: uid_t = UInt32.max
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == allowedUID else {
                close(clientFD)
                continue
            }

            addClient(clientFD)
            Task {
                await self.handleClient(clientFD, onCommand: onCommand)
                self.removeClient(clientFD)
                close(clientFD)
            }
        }
    }

    private func handleClient(
        _ fd: Int32,
        onCommand: @escaping @Sendable (Command) async -> StatusUpdate
    ) async {
        var parser = FramingParser()
        var buf = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            let lines = parser.feed(Data(buf[0..<n]))
            for lineData in lines {
                guard let command = try? decoder.decode(Command.self, from: lineData) else { continue }
                let response = await onCommand(command)
                guard var frame = try? encoder.encode(response) else { continue }
                frame.append(UInt8(ascii: "\n"))
                frame.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, ptr.count) }
            }
        }
    }

    private func addClient(_ fd: Int32) {
        clientLock.lock(); clientFDs.append(fd); clientLock.unlock()
    }

    private func removeClient(_ fd: Int32) {
        clientLock.lock(); clientFDs.removeAll { $0 == fd }; clientLock.unlock()
    }
}
