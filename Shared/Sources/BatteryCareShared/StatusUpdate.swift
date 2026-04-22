public enum DaemonError: String, Codable, Sendable {
    case smcConnectionFailed
    case smcKeyNotFound
    case smcWriteFailed
    case batteryReadFailed
}

public struct StatusUpdate: Sendable {
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
    public let detail: BatteryDetail?

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
        errorDetail: String? = nil,
        detail: BatteryDetail? = nil
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
        self.detail = detail
    }
}

extension StatusUpdate: Codable {
    private enum CodingKeys: String, CodingKey {
        case currentPercentage, isCharging, isPluggedIn, chargingState, mode, limit, sailingLower, pollingInterval, sleepWakeInterval, error, errorDetail, detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPercentage = try container.decode(Int.self, forKey: .currentPercentage)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        isPluggedIn = try container.decode(Bool.self, forKey: .isPluggedIn)
        chargingState = try container.decode(ChargingState.self, forKey: .chargingState)
        mode = try container.decode(DaemonMode.self, forKey: .mode)
        limit = try container.decode(Int.self, forKey: .limit)
        sailingLower = try container.decode(Int.self, forKey: .sailingLower)
        pollingInterval = try container.decode(Int.self, forKey: .pollingInterval)
        sleepWakeInterval = try container.decodeIfPresent(Int.self, forKey: .sleepWakeInterval) ?? 5
        error = try container.decodeIfPresent(DaemonError.self, forKey: .error)
        errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
        detail = try container.decodeIfPresent(BatteryDetail.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPercentage, forKey: .currentPercentage)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(isPluggedIn, forKey: .isPluggedIn)
        try container.encode(chargingState, forKey: .chargingState)
        try container.encode(mode, forKey: .mode)
        try container.encode(limit, forKey: .limit)
        try container.encode(sailingLower, forKey: .sailingLower)
        try container.encode(pollingInterval, forKey: .pollingInterval)
        try container.encode(sleepWakeInterval, forKey: .sleepWakeInterval)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(errorDetail, forKey: .errorDetail)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}