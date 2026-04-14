import XCTest
import BatteryCareShared

// MARK: - Mocks

final class MockSMCService: SMCServiceProtocol, @unchecked Sendable {
    var lastWrite: SMCWrite?
    func open() throws {}
    func perform(_ write: SMCWrite) throws { lastWrite = write }
    func read(key: String) throws -> [UInt8] { [0x00] }
    func close() {}
}

final class MockBatteryMonitor: BatteryMonitorProtocol, @unchecked Sendable {
    var reading = BatteryReading(percentage: 50, isCharging: true, isPluggedIn: true)
    func read() throws -> BatteryReading { reading }
}

final class MockSleepWatcher: SleepWatcherProtocol, @unchecked Sendable {
    func events() -> AsyncStream<SleepEvent> { AsyncStream { _ in } }
}

final class MockSocketServer: SocketServerProtocol, @unchecked Sendable {
    var broadcastedUpdates: [StatusUpdate] = []
    func start(onCommand: @escaping @Sendable (Command) async -> StatusUpdate) throws {}
    func broadcast(_ update: StatusUpdate) { broadcastedUpdates.append(update) }
    func stop() {}
}

final class MockSleepAssertion: SleepAssertionProtocol, @unchecked Sendable {
    var acquireCount = 0
    var releaseCount = 0
    var isActive: Bool { acquireCount > releaseCount }
    func acquire() {
        guard !isActive else { return }
        acquireCount += 1
    }
    func release() {
        guard isActive else { return }
        releaseCount += 1
    }
}

// MARK: - Tests

final class DaemonCoreTests: XCTestCase {

    private func makeCore(
        limit: Int = 80,
        sailingLower: Int = 80,
        pollingInterval: Int = 5,
        isChargingDisabled: Bool = false,
        smc: MockSMCService = MockSMCService(),
        battery: MockBatteryMonitor = MockBatteryMonitor(),
        sleepAssertion: MockSleepAssertion = MockSleepAssertion()
    ) -> DaemonCore {
        let settings = DaemonSettings(
            limit: limit,
            sailingLower: sailingLower,
            pollingInterval: pollingInterval,
            isChargingDisabled: isChargingDisabled,
            allowedUID: getuid()
        )
        return DaemonCore(
            settings: settings,
            smc: smc,
            battery: battery,
            sleepWatcher: MockSleepWatcher(),
            socketServer: MockSocketServer(),
            sleepAssertion: sleepAssertion
        )
    }

    // MARK: - 1. getStatus returns current reading

    func testGetStatusReturnsCurrentReading() async {
        let battery = MockBatteryMonitor()
        battery.reading = BatteryReading(percentage: 72, isCharging: true, isPluggedIn: true)
        let core = makeCore(limit: 80, battery: battery)
        let update = await core.handle(.getStatus)
        XCTAssertEqual(update.currentPercentage, 72)
        XCTAssertEqual(update.limit, 80)
    }

    // MARK: - 2. setLimit clamps low

    func testSetLimitClampsToMinimum() async {
        let core = makeCore()
        let update = await core.handle(.setLimit(percentage: 10))
        XCTAssertEqual(update.limit, 20)
    }

    // MARK: - 3. setLimit clamps high

    func testSetLimitClampsToMaximum() async {
        let core = makeCore()
        let update = await core.handle(.setLimit(percentage: 110))
        XCTAssertEqual(update.limit, 100)
    }

    // MARK: - 4. setPollingInterval clamps low

    func testSetPollingIntervalClampsToMinimum() async {
        let core = makeCore()
        let update = await core.handle(.setPollingInterval(seconds: 0))
        XCTAssertEqual(update.pollingInterval, 1)
    }

    // MARK: - 5. setPollingInterval clamps high

    func testSetPollingIntervalClampsToMaximum() async {
        let core = makeCore()
        let update = await core.handle(.setPollingInterval(seconds: 60))
        XCTAssertEqual(update.pollingInterval, 30)
    }

    // MARK: - 6. enableCharging clears disabled flag

    func testEnableChargingClearsDisabledFlag() async {
        let core = makeCore(isChargingDisabled: true)
        _ = await core.handle(.enableCharging)
        let update = await core.handle(.getStatus)
        XCTAssertNotEqual(update.chargingState, .disabled)
    }

    // MARK: - 7. disableCharging writes to SMC

    func testDisableChargingCallsSMC() async {
        let smc = MockSMCService()
        let core = makeCore(smc: smc)
        _ = await core.handle(.disableCharging)
        XCTAssertEqual(smc.lastWrite, .disableCharging)
    }

    // MARK: - 8. Assertion acquired during charging

    func testAssertionAcquiredDuringCharging() async {
        let assertion = MockSleepAssertion()
        let battery = MockBatteryMonitor()
        battery.reading = BatteryReading(percentage: 60, isCharging: true, isPluggedIn: true)
        let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
        _ = await core.handle(.setLimit(percentage: 80))
        XCTAssertTrue(assertion.isActive)
    }

    // MARK: - 9. Assertion released at limit reached

    func testAssertionReleasedAtLimitReached() async {
        let assertion = MockSleepAssertion()
        let battery = MockBatteryMonitor()
        battery.reading = BatteryReading(percentage: 80, isCharging: false, isPluggedIn: true)
        let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
        _ = await core.handle(.setLimit(percentage: 80))
        XCTAssertFalse(assertion.isActive)
    }

    // MARK: - 10. Assertion released when idle (unplugged)

    func testAssertionReleasedWhenIdle() async {
        let assertion = MockSleepAssertion()
        let battery = MockBatteryMonitor()
        battery.reading = BatteryReading(percentage: 60, isCharging: false, isPluggedIn: false)
        let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
        _ = await core.handle(.setLimit(percentage: 80))
        XCTAssertFalse(assertion.isActive)
    }

    // MARK: - 11. Assertion released when charging disabled

    func testAssertionReleasedWhenChargingDisabled() async {
        let assertion = MockSleepAssertion()
        let battery = MockBatteryMonitor()
        battery.reading = BatteryReading(percentage: 60, isCharging: true, isPluggedIn: true)
        let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
        _ = await core.handle(.disableCharging)
        XCTAssertFalse(assertion.isActive)
    }

    // MARK: - 12. setSailingLower clamps to [20, limit]

    func testSetSailingLowerClampsToLimit() async {
        let core = makeCore(limit: 80)
        let update = await core.handle(.setSailingLower(percentage: 90))
        XCTAssertEqual(update.sailingLower, 80)
    }

    func testSetSailingLowerClampsToMinimum() async {
        let core = makeCore(limit: 80)
        let update = await core.handle(.setSailingLower(percentage: 10))
        XCTAssertEqual(update.sailingLower, 20)
    }

    func testSetSailingLowerAcceptsValidValue() async {
        let core = makeCore(limit: 80)
        let update = await core.handle(.setSailingLower(percentage: 60))
        XCTAssertEqual(update.sailingLower, 60)
    }

    // MARK: - 13. setLimit lowers sailingLower when needed

    func testSetLimitClampsSailingLower() async {
        let core = makeCore(limit: 80, sailingLower: 70)
        _ = await core.handle(.setSailingLower(percentage: 70))
        let update = await core.handle(.setLimit(percentage: 60))
        XCTAssertEqual(update.sailingLower, 60)
    }

    // MARK: - 14. StatusUpdate includes sailingLower

    func testStatusUpdateIncludesSailingLower() async {
        let core = makeCore(limit: 80, sailingLower: 65)
        let update = await core.handle(.getStatus)
        XCTAssertEqual(update.sailingLower, 65)
    }
}