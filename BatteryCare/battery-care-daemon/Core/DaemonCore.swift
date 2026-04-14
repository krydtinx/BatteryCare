import Foundation
import BatteryCareShared
import os.log

public actor DaemonCore {

    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "smc")

    // MARK: - State

    private var settings: DaemonSettings
    private var stateMachine = ChargingStateMachine()

    // MARK: - Dependencies

    private let smc: SMCServiceProtocol
    private let battery: BatteryMonitorProtocol
    private let sleepWatcher: SleepWatcherProtocol
    private let socketServer: SocketServerProtocol
    private let sleepAssertion: SleepAssertionProtocol

    // MARK: - Init

    public init(
        settings: DaemonSettings,
        smc: SMCServiceProtocol,
        battery: BatteryMonitorProtocol,
        sleepWatcher: SleepWatcherProtocol,
        socketServer: SocketServerProtocol,
        sleepAssertion: SleepAssertionProtocol
    ) {
        self.settings = settings
        self.smc = smc
        self.battery = battery
        self.sleepWatcher = sleepWatcher
        self.socketServer = socketServer
        self.sleepAssertion = sleepAssertion
    }

    // MARK: - Run

    public func run() async throws {
        defer { sleepAssertion.release() }
        try smc.open()
        deriveInitialState()

        try socketServer.start { [weak self] command in
            guard let self else { return StatusUpdate.empty }
            return await self.handle(command)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.pollingLoop() }
            group.addTask { await self.sleepLoop() }
            for try await _ in group {}
        }
    }

    // MARK: - Command handler

    public func handle(_ command: Command) async -> StatusUpdate {
        switch command {

        case .getStatus:
            return makeStatusUpdate()

        case .setLimit(let p):
            settings.limit = max(20, min(100, p))
            settings.sailingLower = min(settings.sailingLower, settings.limit)
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.evaluate(reading: reading, limit: settings.limit,
                                      sailingLower: settings.sailingLower,
                                      isDisabled: settings.isChargingDisabled)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .setSailingLower(let p):
            settings.sailingLower = max(20, min(settings.limit, p))
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.evaluate(reading: reading, limit: settings.limit,
                                      sailingLower: settings.sailingLower,
                                      isDisabled: settings.isChargingDisabled)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .setPollingInterval(let s):
            settings.pollingInterval = max(1, min(30, s))
            try? settings.save()
            return makeStatusUpdate()

        case .enableCharging:
            settings.isChargingDisabled = false
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.forceEnable(reading: reading, limit: settings.limit)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .disableCharging:
            settings.isChargingDisabled = true
            try? settings.save()
            stateMachine.forceDisable()
            let smcError = applyState()
            let update = makeStatusUpdate(error: smcError)
            socketServer.broadcast(update)
            return update
        }
    }

    // MARK: - Loops

    private func pollingLoop() async throws {
        while true {
            try Task.checkCancellation()
            pollOnce()
            try await Task.sleep(for: .seconds(settings.pollingInterval))
        }
    }

    private func sleepLoop() async {
        for await event in sleepWatcher.events() {
            switch event {
            case .willSleep:
                // Re-apply SMC state immediately before sleep so powerd cannot override
                // the charge limit. The sleep assertion is already in the correct state
                // from the last poll tick; acquire/release here are no-ops.
                applyState()
            case .hasPoweredOn:
                applyState()
                pollOnce()
            }
        }
    }

    // MARK: - Helpers

    private func pollOnce() {
        do {
            let reading = try battery.read()
            stateMachine.evaluate(
                reading: reading,
                limit: settings.limit,
                sailingLower: settings.sailingLower,
                isDisabled: settings.isChargingDisabled
            )
            applyState()
            socketServer.broadcast(makeStatusUpdate(from: reading))
        } catch {
            let update = makeStatusUpdate(error: .batteryReadFailed, errorDetail: "\(error)")
            socketServer.broadcast(update)
        }
    }

    private func deriveInitialState() {
        guard let reading = try? battery.read() else { return }
        if settings.isChargingDisabled {
            stateMachine.forceDisable()
            try? smc.perform(.disableCharging)
        } else {
            stateMachine.evaluate(reading: reading, limit: settings.limit,
                                  sailingLower: settings.sailingLower, isDisabled: false)
            applyState()
        }
    }

    @discardableResult
    private func applyState() -> DaemonError? {
        if stateMachine.state == .charging {
            sleepAssertion.acquire()
        } else {
            sleepAssertion.release()
        }

        switch stateMachine.state {
        case .charging:
            do { try smc.perform(.enableCharging) } catch {
                logger.error("SMC enableCharging failed: \(String(describing: error), privacy: .public)")
                return .smcWriteFailed
            }
        case .limitReached, .disabled:
            do { try smc.perform(.disableCharging) } catch {
                logger.error("SMC disableCharging failed: \(String(describing: error), privacy: .public)")
                return .smcWriteFailed
            }
        case .idle:
            break
        }
        return nil
    }

    private func makeStatusUpdate(
        from reading: BatteryReading? = nil,
        error: DaemonError? = nil,
        errorDetail: String? = nil
    ) -> StatusUpdate {
        let r = reading ?? (try? battery.read()) ?? BatteryReading(percentage: 0, isCharging: false, isPluggedIn: false)
        return StatusUpdate(
            currentPercentage: r.percentage,
            isCharging: r.isCharging,
            isPluggedIn: r.isPluggedIn,
            chargingState: stateMachine.state,
            mode: .normal,
            limit: settings.limit,
            sailingLower: settings.sailingLower,
            pollingInterval: settings.pollingInterval,
            error: error,
            errorDetail: errorDetail
        )
    }
}

// MARK: - Empty status sentinel

private extension StatusUpdate {
    static var empty: StatusUpdate {
        StatusUpdate(
            currentPercentage: 0, isCharging: false, isPluggedIn: false,
            chargingState: .idle, mode: .normal, limit: 80, sailingLower: 80, pollingInterval: 5
        )
    }
}