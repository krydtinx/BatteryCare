import Foundation
import IOKit

// MARK: - Protocol

public protocol BatteryMonitorProtocol: Sendable {
    func read() throws -> BatteryReading
}

// MARK: - Reading

public struct BatteryReading: Sendable {
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool

    public init(percentage: Int, isCharging: Bool, isPluggedIn: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
    }
}

// MARK: - Errors

public enum BatteryMonitorError: Error {
    case serviceNotFound
    case readFailed(String)
}

// MARK: - Implementation

/// Reads battery state from the AppleSmartBattery IORegistry entry.
/// Uses IOServiceGetMatchingService (NOT IOPSCopyPowerSourcesInfo) for accurate M-series data.
public final class BatteryMonitor: BatteryMonitorProtocol, @unchecked Sendable {

    public init() {}

    public func read() throws -> BatteryReading {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else {
            throw BatteryMonitorError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        // CurrentCapacity is already a percentage (0–100) on Apple Silicon.
        // AppleRawCurrentCapacity / AppleRawMaxCapacity are in mAh — not used for % here.
        let percentage    = try intProperty(service, key: "CurrentCapacity")
        let isCharging    = boolProperty(service, key: "IsCharging")
        let externalConnected = boolProperty(service, key: "ExternalConnected")

        return BatteryReading(
            percentage: min(max(percentage, 0), 100),
            isCharging: isCharging,
            isPluggedIn: externalConnected
        )
    }

    // MARK: - Helpers

    private func intProperty(_ service: io_service_t, key: String) throws -> Int {
        guard let cfVal = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int else {
            throw BatteryMonitorError.readFailed("Missing or non-integer property: \(key)")
        }
        return cfVal
    }

    private func boolProperty(_ service: io_service_t, key: String) -> Bool {
        guard let cfVal = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return false }
        return cfVal as? Bool ?? false
    }
}
