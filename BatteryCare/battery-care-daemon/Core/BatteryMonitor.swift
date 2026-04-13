import Foundation
import IOKit
import IOKit.ps

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

/// Reads battery state via IOPSCopyPowerSourcesInfo — the standard public API for all Mac types.
public final class BatteryMonitor: BatteryMonitorProtocol, @unchecked Sendable {

    public init() {}

    public func read() throws -> BatteryReading {
        guard let rawInfo = IOPSCopyPowerSourcesInfo() else {
            throw BatteryMonitorError.serviceNotFound
        }
        let info = rawInfo.takeRetainedValue()

        guard let rawList = IOPSCopyPowerSourcesList(info) else {
            throw BatteryMonitorError.serviceNotFound
        }
        let list = rawList.takeRetainedValue() as NSArray

        guard list.count > 0 else {
            throw BatteryMonitorError.readFailed("No power sources found")
        }

        // swiftlint:disable force_cast
        let source = list[0] as! CFTypeRef
        // swiftlint:enable force_cast

        // IOPSGetPowerSourceDescription is NOT a Copy — must use takeUnretainedValue
        guard let rawDesc = IOPSGetPowerSourceDescription(info, source) else {
            throw BatteryMonitorError.readFailed("No power source description")
        }
        // CFDictionary must be bridged via NSDictionary (direct [String:Any] cast fails)
        guard let desc = rawDesc.takeUnretainedValue() as? NSDictionary else {
            throw BatteryMonitorError.readFailed("Cannot read power source description")
        }

        let percentage  = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue ?? 0
        let sourceState = desc[kIOPSPowerSourceStateKey] as? String ?? kIOPSBatteryPowerValue
        let isPluggedIn = sourceState != kIOPSBatteryPowerValue

        // IOPS IsCharging lags after SMC writes; read directly from IORegistry for accuracy
        let isCharging  = isPluggedIn && ioregIsCharging()

        return BatteryReading(
            percentage: min(max(percentage, 0), 100),
            isCharging: isCharging,
            isPluggedIn: isPluggedIn
        )
    }

    /// Reads IsCharging from AppleSmartBattery IORegistry — updates immediately after SMC writes.
    private func ioregIsCharging() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                          IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(service,
                        "IsCharging" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }
}
