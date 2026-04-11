import Foundation
import IOKit

// MARK: - Errors

public enum SMCError: Error, CustomStringConvertible {
    case connectionFailed(kern_return_t)
    case keyNotFound(String)
    case writeFailed(String, kern_return_t)
    case readFailed(String, kern_return_t)
    case noChargingKeyAvailable

    public var description: String {
        switch self {
        case .connectionFailed(let kr):  return "SMC open failed: \(kr)"
        case .keyNotFound(let key):      return "SMC key not found: \(key)"
        case .writeFailed(let key, let kr): return "SMC write failed for \(key): \(kr)"
        case .readFailed(let key, let kr):  return "SMC read failed for \(key): \(kr)"
        case .noChargingKeyAvailable:    return "Neither CH0B nor CH0C is writable on this Mac"
        }
    }
}

// MARK: - Write intent

public enum SMCWrite {
    case enableCharging   // 0x00 to CH0B + CH0C
    case disableCharging  // 0x02 to CH0B + CH0C
}

// MARK: - Protocol

public protocol SMCServiceProtocol: Sendable {
    /// Open SMC connection and probe which charging key is available.
    func open() throws
    /// Write charging enable/disable to all available keys.
    func perform(_ write: SMCWrite) throws
    /// Read a raw SMC key value (used for read-back verification and Phase 3+ features).
    func read(key: String) throws -> [UInt8]
    /// Close SMC connection.
    func close()
}

// MARK: - Implementation

public final class SMCService: SMCServiceProtocol, @unchecked Sendable {

    // Keys to try, in probe order. Both are written when available.
    private static let chargingKeys = ["CH0B", "CH0C"]

    private var conn: io_connect_t = 0
    private var availableKeys: [String] = []
    private let lock = NSLock()

    public init() {}

    public func open() throws {
        lock.lock()
        defer { lock.unlock() }

        var connection: io_connect_t = 0
        let kr = SMCOpen(&connection)
        guard kr == KERN_SUCCESS else {
            throw SMCError.connectionFailed(kr)
        }
        conn = connection
        availableKeys = try probeChargingKeys()
        if availableKeys.isEmpty {
            SMCClose(conn)
            conn = 0
            throw SMCError.noChargingKeyAvailable
        }
    }

    public func perform(_ write: SMCWrite) throws {
        lock.lock()
        defer { lock.unlock() }

        let byte: UInt8 = (write == .enableCharging) ? 0x00 : 0x02
        var errors: [SMCError] = []

        for key in availableKeys {
            do {
                try writeKey(key, byte: byte)
                // Read-back verification
                let readBack = try readKeyRaw(key)
                if readBack.first != byte {
                    // Log mismatch but don't throw — other key may succeed
                    errors.append(.writeFailed(key, kern_return_t(kIOReturnNotWritable)))
                }
            } catch let e as SMCError {
                errors.append(e)
            }
        }

        // Succeed if at least one key was written without error
        if errors.count == availableKeys.count {
            throw errors.first ?? SMCError.noChargingKeyAvailable
        }
    }

    public func read(key: String) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return try readKeyRaw(key)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if conn != 0 {
            SMCClose(conn)
            conn = 0
        }
        availableKeys = []
    }

    // MARK: - Private helpers

    /// Probe each charging key with a harmless read; keep those that respond.
    private func probeChargingKeys() throws -> [String] {
        var found: [String] = []
        for key in Self.chargingKeys {
            var keyBuf = UInt32Char_t()
            _ = key.withCString { src in
                withUnsafeMutableBytes(of: &keyBuf) { dst in
                    memcpy(dst.baseAddress!, src, min(key.utf8.count, 4))
                }
            }
            var val = SMCVal_t()
            let kr = SMCReadKey2(&keyBuf, &val, conn)
            if kr == KERN_SUCCESS {
                found.append(key)
            }
        }
        return found
    }

    private func writeKey(_ key: String, byte: UInt8) throws {
        var b = byte
        let kr = withUnsafeMutablePointer(to: &b) { ptr in
            SMCWriteSimple(
                UnsafeMutablePointer(mutating: (key as NSString).utf8String)!,
                ptr,
                1,
                conn
            )
        }
        guard kr == KERN_SUCCESS else {
            throw SMCError.writeFailed(key, kr)
        }
    }

    private func readKeyRaw(_ key: String) throws -> [UInt8] {
        var keyBuf = UInt32Char_t()
        _ = key.withCString { src in
            withUnsafeMutableBytes(of: &keyBuf) { dst in
                memcpy(dst.baseAddress!, src, min(key.utf8.count, 4))
            }
        }
        var val = SMCVal_t()
        let kr = SMCReadKey2(&keyBuf, &val, conn)
        guard kr == KERN_SUCCESS else {
            if kr == kern_return_t(kIOReturnNotFound) {
                throw SMCError.keyNotFound(key)
            }
            throw SMCError.readFailed(key, kr)
        }
        let size = Int(val.dataSize)
        return withUnsafeBytes(of: val.bytes) { Array($0.prefix(size)) }
    }
}
