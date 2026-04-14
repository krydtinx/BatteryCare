import XCTest
import BatteryCareShared

final class ChargingStateMachineTests: XCTestCase {

    private func reading(percentage: Int, isCharging: Bool, isPluggedIn: Bool) -> BatteryReading {
        BatteryReading(percentage: percentage, isCharging: isCharging, isPluggedIn: isPluggedIn)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let sm = ChargingStateMachine()
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - evaluate transitions (sailingLower=80 == limit → old behaviour)

    func testNotPluggedInIsIdle() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: false, isPluggedIn: false),
                    limit: 80, sailingLower: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .idle)
    }

    func testPluggedInBelowLimitIsCharging() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 60, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)
    }

    func testPluggedInAtLimitIsLimitReached() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 80, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    func testPluggedInAboveLimitIsLimitReached() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 85, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    func testIsDisabledOverridesPluggedIn() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 80, isDisabled: true)
        XCTAssertEqual(sm.state, .disabled)
    }

    func testIsDisabledOverridesUnplugged() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: false, isPluggedIn: false),
                    limit: 80, sailingLower: 80, isDisabled: true)
        XCTAssertEqual(sm.state, .disabled)
    }

    // MARK: - Return value (changed flag)

    func testEvaluateReturnsTrueOnStateChange() {
        var sm = ChargingStateMachine()
        let changed = sm.evaluate(
            reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
            limit: 80, sailingLower: 80, isDisabled: false
        )
        XCTAssertTrue(changed)
    }

    func testEvaluateReturnsFalseWhenStateUnchanged() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 50, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 80, isDisabled: false)
        let changed = sm.evaluate(
            reading: reading(percentage: 55, isCharging: true, isPluggedIn: true),
            limit: 80, sailingLower: 80, isDisabled: false
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
                    limit: 80, sailingLower: 80, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)

        let changed = sm.evaluate(
            reading: reading(percentage: 80, isCharging: true, isPluggedIn: true),
            limit: 80, sailingLower: 80, isDisabled: false
        )
        XCTAssertEqual(sm.state, .limitReached)
        XCTAssertTrue(changed)
    }

    // MARK: - Sailing mode hysteresis (sailingLower < limit)

    /// Plug in at zone level (75%) from idle → limitReached (wait for drop to lower)
    func testPlugInAtSailingZoneLevelStaysPaused() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 75, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    /// Hit upper limit, drop into zone → stays limitReached (hysteresis)
    func testSailingZoneFromLimitReachedStaysPaused() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 80, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
        sm.evaluate(reading: reading(percentage: 75, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    /// Drop below sailingLower after hitting upper → charging resumes
    func testBelowSailingLowerTriggersCharging() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 80, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        sm.evaluate(reading: reading(percentage: 69, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)
    }

    /// Once charging, keeps charging through the zone (doesn't stop at lower bound)
    func testChargingContinuesThroughSailingZone() {
        var sm = ChargingStateMachine()
        // Start below lower → charging
        sm.evaluate(reading: reading(percentage: 65, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)
        // Rise into zone → still charging
        sm.evaluate(reading: reading(percentage: 75, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .charging)
    }

    /// Charging through zone stops only at upper limit
    func testChargingStopsAtUpperLimitFromSailingZone() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 65, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        sm.evaluate(reading: reading(percentage: 75, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        sm.evaluate(reading: reading(percentage: 80, isCharging: false, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .limitReached)
    }

    /// Unplug while charging in the zone → idle (not limitReached)
    func testUnplugWhileChargingInSailingZoneGoesToIdle() {
        var sm = ChargingStateMachine()
        sm.evaluate(reading: reading(percentage: 65, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        sm.evaluate(reading: reading(percentage: 72, isCharging: true, isPluggedIn: true),
                    limit: 80, sailingLower: 70, isDisabled: false)
        sm.evaluate(reading: reading(percentage: 71, isCharging: false, isPluggedIn: false),
                    limit: 80, sailingLower: 70, isDisabled: false)
        XCTAssertEqual(sm.state, .idle)
    }

    /// forceEnable in sailing zone (75%) → charging (ignores lower bound by design)
    func testForceEnableInSailingZoneStartsCharging() {
        var sm = ChargingStateMachine()
        sm.forceDisable()
        sm.forceEnable(reading: reading(percentage: 75, isCharging: false, isPluggedIn: true),
                       limit: 80)
        XCTAssertEqual(sm.state, .charging)
    }
}