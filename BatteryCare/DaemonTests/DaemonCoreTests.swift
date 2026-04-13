import XCTest
import BatteryCareShared

// DaemonCore, SMCServiceProtocol, BatteryMonitorProtocol, SleepWatcherProtocol
// are in the Daemon module — added to DaemonTests target in Xcode.

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

// MARK: - Tests

final class DaemonCoreTests: XCTestCase {

    private func makeCore(
        limit: Int = 80,
        pollingInterval: Int = 5,
        isChargingDisabled: Bool = false,
        smc: MockSMCService = MockSMCService(),
        battery: MockBatteryMonitor = MockBatteryMonitor()
    ) -> DaemonCore {
        let settings = DaemonSettings(
            limit: limit,
            pollingInterval: pollingInterval,
            isChargingDisabled: isChargingDisabled,
            allowedUID: getuid()
        )
        return DaemonCore(
            settings: settings,
            smc: smc,
            battery: battery,
            sleepWatcher: MockSleepWatcher(),
            socketServer: MockSocketServer()
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
}
