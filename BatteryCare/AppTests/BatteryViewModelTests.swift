import XCTest
import Combine
import BatteryCareShared
@testable import BatteryCare

final class BatteryViewModelTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "com.batterycare.savedLimit")
        UserDefaults.standard.removeObject(forKey: "com.batterycare.savedSailingLower")
        super.tearDown()
    }

    // MARK: - Mock

    @MainActor
    final class MockDaemonClient: DaemonClientProtocol {
        private let statusSubject = PassthroughSubject<StatusUpdate, Never>()
        private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
        var sentCommands: [Command] = []

        var statusPublisher: AnyPublisher<StatusUpdate, Never> { statusSubject.eraseToAnyPublisher() }
        var connectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }

        func start() {}
        func stop() {}
        func send(_ command: Command) async { sentCommands.append(command) }

        func emit(_ update: StatusUpdate) { statusSubject.send(update) }
        func setConnected(_ value: Bool) { connectedSubject.send(value) }
    }

    private func makeUpdate(
        percentage: Int = 50, isCharging: Bool = true, isPluggedIn: Bool = true,
        chargingState: ChargingState = .charging, limit: Int = 80, sailingLower: Int = 80,
        pollingInterval: Int = 5, error: DaemonError? = nil, errorDetail: String? = nil
    ) -> StatusUpdate {
        StatusUpdate(
            currentPercentage: percentage, isCharging: isCharging, isPluggedIn: isPluggedIn,
            chargingState: chargingState, mode: .normal, limit: limit, sailingLower: sailingLower,
            pollingInterval: pollingInterval, error: error, errorDetail: errorDetail
        )
    }

    // MARK: - 1. Status update applied to published properties

    @MainActor func testStatusUpdateApplied() async {
        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        mock.emit(makeUpdate(percentage: 72, limit: 85))
        // Give Combine pipeline a run-loop turn
        await Task.yield()
        XCTAssertEqual(vm.percentage, 72)
        XCTAssertEqual(vm.limit, 85)
    }

    // MARK: - 2. isConnected mirrors client

    @MainActor func testIsConnectedMirrorsClient() async {
        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        mock.setConnected(true)
        await Task.yield()
        XCTAssertTrue(vm.isConnected)
    }

    // MARK: - 3. Error message set on daemon error

    @MainActor func testErrorMessageSetOnDaemonError() async {
        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        mock.emit(makeUpdate(error: .smcWriteFailed, errorDetail: "CH0B"))
        await Task.yield()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("CH0B") ?? false)
    }

    // MARK: - 4. Error message cleared when no error

    @MainActor func testErrorMessageClearedWhenNoError() async {
        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        mock.emit(makeUpdate(error: .smcWriteFailed))
        await Task.yield()
        mock.emit(makeUpdate(error: nil))
        await Task.yield()
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - 5. setLimit sends correct command

    @MainActor func testSetLimitSendsCommand() async {
        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        vm.setLimit(75)
        await Task.yield()
        let hasSetLimit = mock.sentCommands.contains {
            if case .setLimit(let p) = $0 { return p == 75 }
            return false
        }
        XCTAssertTrue(hasSetLimit)
    }

    // MARK: - 6. Restore limits: sends setLimit + setSailingLower on connect when UserDefaults has saved values

    @MainActor func testRestoresLimitsOnConnectWhenSaved() async {
        UserDefaults.standard.set(75, forKey: "com.batterycare.savedLimit")
        UserDefaults.standard.set(60, forKey: "com.batterycare.savedSailingLower")

        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)

        // Expect both restore commands to arrive. receive(on: DispatchQueue.main) schedules
        // the sink asynchronously, and the sink spawns an inner Task — use an expectation
        // so we wait until both commands actually land rather than guessing yield counts.
        let expectation = XCTestExpectation(description: "restore commands sent")
        expectation.expectedFulfillmentCount = 1
        var checkTimer: Timer?
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let hasLimit = mock.sentCommands.contains { if case .setLimit(let p) = $0 { return p == 75 }; return false }
            let hasSailing = mock.sentCommands.contains { if case .setSailingLower(let p) = $0 { return p == 60 }; return false }
            if hasLimit && hasSailing {
                checkTimer?.invalidate()
                expectation.fulfill()
            }
        }

        mock.setConnected(true)
        await fulfillment(of: [expectation], timeout: 2.0)
        checkTimer?.invalidate()

        let hasSetLimit = mock.sentCommands.contains {
            if case .setLimit(let p) = $0 { return p == 75 }
            return false
        }
        let hasSetSailingLower = mock.sentCommands.contains {
            if case .setSailingLower(let p) = $0 { return p == 60 }
            return false
        }
        XCTAssertTrue(hasSetLimit, "Expected setLimit(75) to be sent")
        XCTAssertTrue(hasSetSailingLower, "Expected setSailingLower(60) to be sent")
    }

    // MARK: - 7. Restore limits: does nothing on connect when UserDefaults is empty

    @MainActor func testNoRestoreOnConnectWhenNothingSaved() async {
        UserDefaults.standard.removeObject(forKey: "com.batterycare.savedLimit")
        UserDefaults.standard.removeObject(forKey: "com.batterycare.savedSailingLower")

        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        let commandCountBefore = mock.sentCommands.count
        mock.setConnected(true)
        await Task.yield()

        XCTAssertEqual(mock.sentCommands.count, commandCountBefore,
                       "Expected no commands sent when UserDefaults is empty")
    }

    // MARK: - 8. Restore limits: clears UserDefaults after restoring so reconnects don't re-restore

    @MainActor func testClearsUserDefaultsAfterRestoring() async {
        UserDefaults.standard.set(70, forKey: "com.batterycare.savedLimit")
        UserDefaults.standard.set(55, forKey: "com.batterycare.savedSailingLower")

        let mock = MockDaemonClient()
        let vm = BatteryViewModel(client: mock)
        mock.setConnected(true)
        await Task.yield()

        XCTAssertNil(UserDefaults.standard.object(forKey: "com.batterycare.savedLimit"),
                     "savedLimit should be cleared after restore")
        XCTAssertNil(UserDefaults.standard.object(forKey: "com.batterycare.savedSailingLower"),
                     "savedSailingLower should be cleared after restore")
    }
}
