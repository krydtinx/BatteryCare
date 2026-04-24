import Foundation
import IOKit.pwr_mgt

// MARK: - Protocol

public protocol WakeSchedulerProtocol: Sendable {
    /// Schedule a maintenance (dark) wake at the given date.
    /// Returns true on success.
    @discardableResult
    func schedule(at date: Date) -> Bool
    /// Cancel a previously scheduled wake at the given date.
    func cancel(at date: Date)
}

// MARK: - Implementation

public final class WakeScheduler: WakeSchedulerProtocol, @unchecked Sendable {

    // IOPMSchedulePowerEvent only accepts the documented auto event types from
    // IOPMLib.h. "MaintenanceWakeCalendarDate" is a settings key, not a valid
    // schedule type for this API.
    private let scheduleType = "wake" as CFString
    private let clientID = "com.batterycare.daemon" as CFString

    public init() {}

    @discardableResult
    public func schedule(at date: Date) -> Bool {
        let result = IOPMSchedulePowerEvent(date as CFDate, clientID, scheduleType)
        return result == kIOReturnSuccess
    }

    public func cancel(at date: Date) {
        IOPMCancelScheduledPowerEvent(date as CFDate, clientID, scheduleType)
    }
}
