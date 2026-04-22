import Foundation
import IOKit
import IOKit.ps
import BatteryCareShared

// MARK: - Protocol

public protocol BatteryMonitorProtocol: Sendable {
    func read() throws -> BatteryReading
}

// MARK: - Reading

public struct BatteryReading: Sendable {
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let detail: BatteryDetail?

    public init(percentage: Int, isCharging: Bool, isPluggedIn: Bool, detail: BatteryDetail? = nil) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.detail = detail
    }
}

// MARK: - Errors

public enum BatteryMonitorError: Error {
    case serviceNotFound
    case readFailed(String)
}

// MARK: - Implementation

/// Reads battery state via IOPSCopyPowerSourcesInfo — the standard public API for all Mac types.
public final class BatteryMonitor: BatteryMonitorProtocol, Sendable {

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

        let source: CFTypeRef = list[0] as AnyObject

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
        let (isCharging, detail) = ioregRead()

        return BatteryReading(
            percentage: min(max(percentage, 0), 100),
            isCharging: isPluggedIn && isCharging,
            isPluggedIn: isPluggedIn,
            detail: detail
        )
    }

    /// Opens AppleSmartBattery once and reads IsCharging + all detail keys in one pass.
    /// Returns (isCharging: Bool, detail: BatteryDetail?) — detail is nil if any key is missing
    /// or if AppleRawMaxCapacity/DesignCapacity are zero (guards against divide-by-zero).
    ///
    /// Temperature: Apple Smart Battery Spec unit is 0.1 Kelvin.
    /// Formula: (raw / 10.0) - 273.15 = °C
    ///
    /// Capacity: On Apple Silicon, CurrentCapacity is a percentage (not mAh).
    /// AppleRawCurrentCapacity / AppleRawMaxCapacity are the true mAh values.
    private func ioregRead() -> (isCharging: Bool, detail: BatteryDetail?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                          IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (false, nil) }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString,
                                            kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let isCharging = (prop("IsCharging") as? NSNumber)?.boolValue ?? false

        let rawCurrent = (prop("AppleRawCurrentCapacity") as? NSNumber)?.intValue
        let rawMax     = (prop("AppleRawMaxCapacity")     as? NSNumber)?.intValue
        let design     = (prop("DesignCapacity")          as? NSNumber)?.intValue
        let cycles     = (prop("CycleCount")              as? NSNumber)?.intValue
        let tempRaw    = (prop("Temperature")             as? NSNumber)?.intValue
        let voltage    = (prop("Voltage")                 as? NSNumber)?.intValue

        guard let c = rawCurrent, let m = rawMax, let d = design,
              let cy = cycles, let t = tempRaw, let v = voltage,
              m > 0, d > 0 else {
            return (isCharging, nil)
        }

        let detail = BatteryDetail(
            rawPercentage:      c * 100 / m,
            cycleCount:         cy,
            healthPercent:      m * 100 / d,
            maxCapacityMAh:     m,
            designCapacityMAh:  d,
            temperatureCelsius: (Double(t) / 10.0) - 273.15,
            voltageMillivolts:  v
        )
        return (isCharging, detail)
    }
}
