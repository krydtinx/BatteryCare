import SwiftUI
import Combine
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "viewmodel")

@MainActor
public final class BatteryViewModel: ObservableObject {

    // MARK: - Published state (UI reads these)

    @Published public private(set) var percentage: Int = 0
    @Published public private(set) var isCharging: Bool = false
    @Published public private(set) var isPluggedIn: Bool = false
    @Published public private(set) var chargingState: ChargingState = .idle
    @Published public private(set) var limit: Int = 80
    @Published public private(set) var sailingLower: Int = 80
    @Published public private(set) var pollingInterval: Int = 5
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var isOptimizedChargingEnabled: Bool = false

    // MARK: - Dependencies

    private let client: DaemonClientProtocol

    // MARK: - Internal state

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(client: DaemonClientProtocol = DaemonClient.shared) {
        self.client = client
        bindClient()
        client.start()
        checkOptimizedCharging()
    }

    // MARK: - User actions

    public func setLimit(_ value: Int) {
        Task { await client.send(.setLimit(percentage: value)) }
    }

    public func setSailingLower(_ value: Int) {
        Task { await client.send(.setSailingLower(percentage: value)) }
    }

    public func setPollingInterval(_ value: Int) {
        Task { await client.send(.setPollingInterval(seconds: value)) }
    }

    public func enableCharging() {
        Task { await client.send(.enableCharging) }
    }

    public func disableCharging() {
        Task { await client.send(.disableCharging) }
    }

    // MARK: - Private

    private func bindClient() {
        client.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.apply(update)
            }
            .store(in: &cancellables)

        client.connectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                if connected {
                    self?.restoreLimitsIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    private func apply(_ update: StatusUpdate) {
        percentage = update.currentPercentage
        isCharging = update.isCharging
        isPluggedIn = update.isPluggedIn
        chargingState = update.chargingState
        limit = update.limit
        sailingLower = update.sailingLower
        pollingInterval = update.pollingInterval

        if let error = update.error {
            errorMessage = "\(error)" + (update.errorDetail.map { ": \($0)" } ?? "")
            logger.warning("Daemon error: \(error.rawValue) \(update.errorDetail ?? "")")
        } else {
            errorMessage = nil
        }
    }

    private func restoreLimitsIfNeeded() {
        let defaults = UserDefaults.standard
        let savedLimit = defaults.object(forKey: "com.batterycare.savedLimit") as? Int
        let savedSailingLower = defaults.object(forKey: "com.batterycare.savedSailingLower") as? Int
        guard savedLimit != nil || savedSailingLower != nil else { return }
        defaults.removeObject(forKey: "com.batterycare.savedLimit")
        defaults.removeObject(forKey: "com.batterycare.savedSailingLower")
        Task {
            if let limit = savedLimit { await client.send(.setLimit(percentage: limit)) }
            if let lower = savedSailingLower { await client.send(.setSailingLower(percentage: lower)) }
        }
    }

    private func checkOptimizedCharging() {
        Task.detached(priority: .utility) { [weak self] in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset")
            process.arguments = ["-g", "batt"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let enabled = output.contains("optimized")
                await MainActor.run { [weak self] in
                    self?.isOptimizedChargingEnabled = enabled
                }
            } catch {
                logger.error("pmset check failed: \(error)")
            }
        }
    }
}