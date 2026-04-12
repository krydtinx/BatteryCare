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
        case .noChargingKeyAvailable:    return "No writable charging key found (tried CHTE, CH0B, CH0C)"
        }
    }
}

// MARK: - Write intent

public enum SMCWrite {
    case enableCharging
    case disableCharging
}

// MARK: - Detected key variant

/// Represents a charging key and the byte values it uses.
private enum ChargingKey {
    /// M4 Tahoe key: CHTE — 4-byte, pass-through mode (stop charging, keep adapter power)
    case tahoe(String)
    /// Pre-Tahoe legacy key: disable=0x02, enable=0x00
    case legacy(String)

    var name: String {
        switch self { case .tahoe(let k), .legacy(let k): return k }
    }

    func bytes(for write: SMCWrite) -> [UInt8] {
        switch self {
        case .tahoe:  return write == .disableCharging ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00]
        case .legacy: return write == .disableCharging ? [0x02] : [0x00]
        }
    }
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

    private var conn: io_connect_t = 0
    private var detectedKeys: [ChargingKey] = []
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
        detectedKeys = probeChargingKeys()
        if detectedKeys.isEmpty {
            SMCClose(conn)
            conn = 0
            throw SMCError.noChargingKeyAvailable
        }
    }

    public func perform(_ write: SMCWrite) throws {
        lock.lock()
        defer { lock.unlock() }

        var errors: [SMCError] = []

        for chargingKey in detectedKeys {
            let writeBytes = chargingKey.bytes(for: write)
            do {
                try writeKey(chargingKey.name, bytes: writeBytes)
                // For legacy keys, verify the written byte echoes back exactly.
                // Tahoe keys (CHTE) may report different values — skip verification.
                if case .legacy = chargingKey {
                    let readBack = try readKeyRaw(chargingKey.name)
                    if readBack.first != writeBytes.first {
                        errors.append(.writeFailed(chargingKey.name, kern_return_t(kIOReturnNotWritable)))
                    }
                }
            } catch let e as SMCError {
                errors.append(e)
            }
        }

        if errors.count == detectedKeys.count {
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
        detectedKeys = []
    }

    // MARK: - Private helpers

    /// Probe charging keys in priority order. Returns the first working variant found.
    /// Tahoe (M4): CHTE (4-byte pass-through) with dataSize > 0
    /// Legacy (M1/M2/M3): CH0B and CH0C
    private func probeChargingKeys() -> [ChargingKey] {
        // Tahoe key — M4 Tahoe firmware exposes CHTE (4-byte pass-through mode)
        if probeRawKey("CHTE") { return [.tahoe("CHTE")] }

        // Legacy keys — both written together on pre-Tahoe chips
        let legacyFound = ["CH0B", "CH0C"].filter { probeRawKey($0) }
        return legacyFound.map { .legacy($0) }
    }

    /// Returns true if the key responds with dataSize > 0.
    private func probeRawKey(_ key: String) -> Bool {
        var keyBuf = UInt32Char_t()
        _ = key.withCString { src in
            withUnsafeMutableBytes(of: &keyBuf) { dst in
                memcpy(dst.baseAddress!, src, min(key.utf8.count, 4))
            }
        }
        var val = SMCVal_t()
        let kr = SMCReadKey2(&keyBuf, &val, conn)
        return kr == KERN_SUCCESS && val.dataSize > 0
    }

    private func writeKey(_ key: String, bytes: [UInt8]) throws {
        var buf = bytes
        let kr = buf.withUnsafeMutableBufferPointer { ptr in
            SMCWriteSimple(
                UnsafeMutablePointer(mutating: (key as NSString).utf8String)!,
                ptr.baseAddress!,
                Int32(ptr.count),
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
