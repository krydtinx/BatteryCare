import Foundation
import IOKit.pwr_mgt

// MARK: - Protocol

protocol WakeSchedulerProtocol: Sendable {
    /// Schedule a maintenance (dark) wake at the given date.
    /// Returns true on success.
    @discardableResult
    func schedule(at date: Date) -> Bool
    /// Cancel a previously scheduled wake at the given date.
    func cancel(at date: Date)
}

// MARK: - Implementation

final class WakeScheduler: WakeSchedulerProtocol, @unchecked Sendable {

    // Attempting to use "MaintenanceScheduled" as a raw string for dark wakes.
    // Do NOT use kIOPMAutoWake — it causes a full user wake on Apple Silicon.
    // Verify the exact constant string in IOPMLib.h if the build fails:
    //   grep -r "MaintenanceScheduled" $(xcrun --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Headers/
    private let scheduleType = "MaintenanceScheduled" as CFString
    private let clientID = "com.batterycare.daemon" as CFString

    @discardableResult
    func schedule(at date: Date) -> Bool {
        let result = IOPMSchedulePowerEvent(date as CFDate, clientID, scheduleType)
        return result == kIOReturnSuccess
    }

    func cancel(at date: Date) {
        IOPMCancelScheduledPowerEvent(date as CFDate, clientID, scheduleType)
    }
}
