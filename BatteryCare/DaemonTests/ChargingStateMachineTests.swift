import XCTest
import BatteryCareShared

// ChargingStateMachine is in the Daemon module — import via @testable when wired in Xcode.
// For now the test file lives here and is added to the DaemonTests target.

final class ChargingStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func reading(percentage: Int, isCharging: Bool, isPluggedIn: Bool) -> BatteryReading {
        BatteryReading(percentage: percentage, isCharging: isCharging, isPluggedIn: isPluggedIn)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let sm = ChargingStateMachine()
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - evaluate transitions

    func testNotPluggedInIsIdle() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: false, isPluggedIn: false),
                    limit: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .idle)
    }

    func testPluggedInBelowLimitIsCharging() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 60, isCharging: true, isPluggedIn: true),
                    limit: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)
    }

    func testPluggedInAtLimitIsLimitReached() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 80, isCharging: false, isPluggedIn: true),
                    limit: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    func testPluggedInAboveLimitIsLimitReached() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 85, isCharging: false, isPluggedIn: true),
                    limit: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    func testIsDisabledOverridesPluggedIn() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
                    limit: 80, isDisabled: true)
        XCTAssertEqual(sm.state, .disabled)
    }

    func testIsDisabledOverridesUnplugged() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: false, isPluggedIn: false),
                    limit: 80, isDisabled: true)
        XCTAssertEqual(sm.state, .disabled)
    }

    // MARK: - Return value (changed flag)

    func testEvaluateReturnsTrueOnStateChange() {
        var sm = ChargingStateMachine()  // starts .idle
        let changed = sm.evaluate(
            reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
            limit: 80, isDisabled: false
        )
        XCTAssertTrue(changed)
    }

    func testEvaluateReturnsFalseWhenStateUnchanged() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
                    limit: 80, isDisabled: false)
        // Same reading again
        let changed = sm.evaluate(
            reading: reading(percentage: 55, isCharging: true, isPluggedIn: true),
            limit: 80, isDisabled: false
        )
        XCTAssertFalse(changed)
    }

    // MARK: - forceDisable / forceEnable

    func testForceDisableSetsDisabledState() {
        var sm = ChargingStateMachine()
        sm.forceDisable()
        XCTAssertEqual(sm.state, .disabled)
    }

    func testForceEnableBelowLimitTransitionsToCharging() {
        var sm = ChargingStateMachine()
        sm.forceDisable()
        sm.forceEnable(reading: reading(percentage: 60, isCharging: false, isPluggedIn: true),
                       limit: 80)
        XCTAssertEqual(sm.state, .charging)
    }

    func testForceEnableAboveLimitTransitionsToLimitReached() {
        var sm = ChargingStateMachine()
        sm.forceDisable()
        sm.forceEnable(reading: reading(percentage: 85, isCharging: false, isPluggedIn: true),
                       limit: 80)
        XCTAssertEqual(sm.state, .limitReached)
    }

    func testForceEnableUnpluggedTransitionsToIdle() {
        var sm = ChargingStateMachine()
        sm.forceDisable()
        sm.forceEnable(reading: reading(percentage: 60, isCharging: false, isPluggedIn: false),
                       limit: 80)
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Multi-step transition

    func testChargingToLimitReachedTransition() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 79, isCharging: true, isPluggedIn: true),
                    limit: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)

        let changed = sm.evaluate(
            reading: reading(percentage: 80, isCharging: true, isPluggedIn: true),
            limit: 80, isDisabled: false
        )
        XCTAssertEqual(sm.state, .limitReached)
        XCTAssertTrue(changed)
    }
}
