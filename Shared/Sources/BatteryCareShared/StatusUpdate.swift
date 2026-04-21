public enum DaemonError: String, Codable, Sendable {
    case smcConnectionFailed
    case smcKeyNotFound
    case smcWriteFailed
    case batteryReadFailed
}

public struct StatusUpdate: Codable, Sendable {
    public let currentPercentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let chargingState: ChargingState
    public let mode: DaemonMode
    public let limit: Int
    public let sailingLower: Int
    public let pollingInterval: Int
    public let sleepWakeInterval: Int
    public let error: DaemonError?
    public let errorDetail: String?

    public init(
        currentPercentage: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        chargingState: ChargingState,
        mode: DaemonMode = .normal,
        limit: Int,
        sailingLower: Int,
        pollingInterval: Int,
        sleepWakeInterval: Int = 5,
        error: DaemonError? = nil,
        errorDetail: String? = nil
    ) {
        self.currentPercentage = currentPercentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.chargingState = chargingState
        self.mode = mode
        self.limit = limit
        self.sailingLower = sailingLower
        self.pollingInterval = pollingInterval
        self.sleepWakeInterval = sleepWakeInterval
        self.error = error
        self.errorDetail = errorDetail
    }
}