import Foundation
import IOKit
import os.log

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
        case .noChargingKeyAvailable:    return "No writable charging key found (tried CHTE, CH0B, CH0C, BCLM)"
        }
    }
}

// MARK: - Write intent

public enum SMCWrite {
    case enableCharging
    case disableCharging
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

// MARK: - Key strategy

/// Describes how a key should be written for enable/disable.
private enum ChargingKey {
    /// M4 Tahoe: CHTE — 4-byte key, pass-through mode (stop charging, keep adapter power)
    case tahoe(String)
    /// Pre-Tahoe: CH0B / CH0C — 0x00 = enable, 0x02 = disable
    case inhibit(String)
    /// Pre-Tahoe: BCLM — 100 = enable (no cap), 1 = disable
    case bclm(String)

    var name: String {
        switch self {
        case .tahoe(let n), .inhibit(let n), .bclm(let n): return n
        }
    }

    func bytes(for write: SMCWrite) -> [UInt8] {
        switch (self, write) {
        case (.tahoe,   .disableCharging):  return [0x01, 0x00, 0x00, 0x00]
        case (.tahoe,   .enableCharging):   return [0x00, 0x00, 0x00, 0x00]
        case (.inhibit, .enableCharging):   return [0x00]
        case (.inhibit, .disableCharging):  return [0x02]
        case (.bclm,    .enableCharging):   return [100]
        case (.bclm,    .disableCharging):  return [1]
        }
    }
}

// MARK: - Implementation

public final class SMCService: SMCServiceProtocol, @unchecked Sendable {

    /// Probe order: Tahoe key first (M4), then legacy keys.
    private static let candidates: [ChargingKey] = [
        .tahoe("CHTE"), .inhibit("CH0B"), .inhibit("CH0C"), .bclm("BCLM")
    ]

    private var conn: io_connect_t = 0
    private var availableKeys: [ChargingKey] = []
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "smc")

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
        availableKeys = probeChargingKeys()
        if availableKeys.isEmpty {
            SMCClose(conn)
            conn = 0
            throw SMCError.noChargingKeyAvailable
        }
        logger.info("SMC opened. Active charging keys: \(self.availableKeys.map(\.name), privacy: .public)")
    }

    public func perform(_ write: SMCWrite) throws {
        lock.lock()
        defer { lock.unlock() }

        var errors: [SMCError] = []

        for key in availableKeys {
            do {
                try writeKey(key.name, bytes: key.bytes(for: write))
                logger.info("SMC \(write == .enableCharging ? "enable" : "disable", privacy: .public) via \(key.name, privacy: .public) OK")
            } catch let e as SMCError {
                logger.error("SMC \(write == .enableCharging ? "enable" : "disable", privacy: .public) via \(key.name, privacy: .public) failed: \(String(describing: e), privacy: .public)")
                errors.append(e)
            }
        }

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

    private func probeChargingKeys() -> [ChargingKey] {
        // Detect Tahoe (M4) firmware by probing CHIE (dataSize=1 on M4, 0 on legacy).
        // If Tahoe, use CHTE for writes (pass-through: stops charging, keeps adapter power).
        if probeKeyReadable("CHIE") {
            logger.info("SMC probe: Tahoe firmware detected via CHIE — using CHTE for charge control")
            var keys: [ChargingKey] = [.tahoe("CHTE")]
            // CH0K is a companion inhibit key on some Tahoe firmware that updates
            // ExternalChargeCapable in IORegistry — what macOS reads for the battery icon.
            // Write it alongside CHTE if available to get the plug icon (not bolt) when paused.
            if probeKeyReadable("CH0K") {
                logger.info("SMC probe: CH0K available — will write alongside CHTE for icon fix")
                keys.append(.inhibit("CH0K"))
            }
            return keys
        }

        // Legacy (M1/M2/M3): CH0B + CH0C, fallback BCLM
        var found: [ChargingKey] = []
        for candidate in Self.candidates {
            guard case .tahoe = candidate else {
                if probeKeyReadable(candidate.name) {
                    found.append(candidate)
                }
                continue
            }
        }
        return found
    }

    /// Returns true if the key responds with dataSize > 0.
    private func probeKeyReadable(_ key: String) -> Bool {
        var keyInt: UInt32 = 0
        key.withCString { src in
            _ = withUnsafeMutableBytes(of: &keyInt) { dst in
                memcpy(dst.baseAddress!, src, min(key.utf8.count, 4))
            }
        }
        var val = SMCVal_t()
        let kr = withUnsafeMutablePointer(to: &keyInt) { ptr in
            ptr.withMemoryRebound(to: UInt32Char_t.self, capacity: 1) {
                SMCReadKey2($0, &val, conn)
            }
        }
        let ok = kr == KERN_SUCCESS && val.dataSize > 0
        logger.info("SMC probe \(key, privacy: .public): kr=\(kr, privacy: .public) dataSize=\(val.dataSize, privacy: .public) -> \(ok ? "available" : "not available", privacy: .public)")
        return ok
    }

    private func writeKey(_ key: String, bytes: [UInt8]) throws {
        var buf = bytes
        // For single-byte writes, try forced write first (bypasses dataSize pre-check;
        // needed on some firmware where SMCGetKeyInfo returns 0 but driver accepts writes).
        if buf.count == 1 {
            let forcedKr = (key as NSString).utf8String.map { SMCWriteForced($0, buf[0], conn) } ?? kern_return_t(kIOReturnError)
            if forcedKr == KERN_SUCCESS {
                return
            }
        }
        // Size-aware write (supports multi-byte keys like CHTE)
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
        var keyInt: UInt32 = 0
        key.withCString { src in
            _ = withUnsafeMutableBytes(of: &keyInt) { dst in
                memcpy(dst.baseAddress!, src, min(key.utf8.count, 4))
            }
        }
        var val = SMCVal_t()
        let kr = withUnsafeMutablePointer(to: &keyInt) { ptr in
            ptr.withMemoryRebound(to: UInt32Char_t.self, capacity: 1) {
                SMCReadKey2($0, &val, conn)
            }
        }
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
