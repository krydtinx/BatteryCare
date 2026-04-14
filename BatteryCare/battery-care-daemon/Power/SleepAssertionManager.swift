import Foundation
import IOKit.pwr_mgt
import os.log

// MARK: - Protocol

public protocol SleepAssertionProtocol: Sendable {
    func acquire()
    func release()
}

// MARK: - Implementation

public final class SleepAssertionManager: SleepAssertionProtocol, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "power")
    private var assertionID: IOPMAssertionID? = nil

    public init() {}

    /// Acquires a system idle-sleep prevention assertion. No-op if already held.
    public func acquire() {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BatteryCare: actively charging battery" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            logger.debug("Sleep assertion acquired (id=\(id))")
        } else {
            logger.warning("Failed to acquire sleep assertion: \(result, privacy: .public)")
        }
    }

    /// Releases the held assertion. No-op if none is held.
    public func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
        logger.debug("Sleep assertion released")
    }

    deinit {
        release()
    }
}
