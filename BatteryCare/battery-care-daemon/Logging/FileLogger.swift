import Foundation

// MARK: - Protocol

public protocol FileLoggerProtocol: Sendable {
    func info(_ message: String)
    func reopen()
}

// MARK: - No-op (for tests)

public struct NoOpFileLogger: FileLoggerProtocol {
    public init() {}
    public func info(_ message: String) {}
    public func reopen() {}
}

// MARK: - Implementation

public final class FileLogger: FileLoggerProtocol, @unchecked Sendable {

    private let path: String
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(path: String) {
        self.path = path
        openFile()
    }

    /// Appends an info-level line: `2026-04-21T02:15:00.000Z INFO <message>\n`
    public func info(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) INFO \(message)\n"
        fileHandle?.write(Data(line.utf8))
    }

    /// Closes and reopens the log file. Called after `newsyslog` rotates the file.
    public func reopen() {
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.closeFile()
        fileHandle = nil
        openFile()
    }

    // MARK: - Private

    private func openFile() {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }
}
