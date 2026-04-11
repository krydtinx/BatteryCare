import Foundation
import BatteryCareShared

public actor DaemonCore {

    // MARK: - State

    private var settings: DaemonSettings
    private var stateMachine = ChargingStateMachine()

    // MARK: - Dependencies

    private let smc: SMCServiceProtocol
    private let battery: BatteryMonitorProtocol
    private let sleepWatcher: SleepWatcherProtocol
    private let socketServer: SocketServerProtocol

    // MARK: - Init

    public init(
        settings: DaemonSettings,
        smc: SMCServiceProtocol,
        battery: BatteryMonitorProtocol,
        sleepWatcher: SleepWatcherProtocol,
        socketServer: SocketServerProtocol
    ) {
        self.settings = settings
        self.smc = smc
        self.battery = battery
        self.sleepWatcher = sleepWatcher
        self.socketServer = socketServer
    }

    // MARK: - Run

    /// Start all subsystems. Throws if a subsystem fails; cancels all others.
    public func run() async throws {
        try smc.open()
        deriveInitialState()

        try socketServer.start { [weak self] command in
            guard let self else { return StatusUpdate.empty }
            return await self.handle(command)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.pollingLoop() }
            group.addTask { await self.sleepLoop() }
            // Rethrow the first error, which cancels the group and all remaining tasks.
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Command handler (called by SocketServer per incoming command)

    public func handle(_ command: Command) async -> StatusUpdate {
        switch command {

        case .getStatus:
            return makeStatusUpdate()

        case .setLimit(let p):
            settings.limit = max(20, min(100, p))
            try? settings.save()
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
                applyState()
            }
            let update = makeStatusUpdate()
            socketServer.broadcast(update)
            return update

        case .disableCharging:
            settings.isChargingDisabled = true
            try? settings.save()
            stateMachine.forceDisable()
            do {
                try smc.perform(.disableCharging)
            } catch {
                return makeStatusUpdate(error: .smcWriteFailed, errorDetail: "\(error)")
            }
            let update = makeStatusUpdate()
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
            if case .hasPoweredOn = event {
                pollOnce()
            }
        }
    }

    // MARK: - Helpers

    private func pollOnce() {
        do {
            let reading = try battery.read()
            let changed = stateMachine.evaluate(
                reading: reading,
                limit: settings.limit,
                isDisabled: settings.isChargingDisabled
            )
            if changed { applyState() }
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
            stateMachine.evaluate(reading: reading, limit: settings.limit, isDisabled: false)
            applyState()
        }
    }

    private func applyState() {
        switch stateMachine.state {
        case .charging:
            try? smc.perform(.enableCharging)
        case .limitReached, .disabled:
            try? smc.perform(.disableCharging)
        case .idle:
            break
        }
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
            chargingState: .idle, mode: .normal, limit: 80, pollingInterval: 5
        )
    }
}
