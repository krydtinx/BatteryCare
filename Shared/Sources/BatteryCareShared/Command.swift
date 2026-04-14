public enum Command: Sendable {
    case getStatus
    case setLimit(percentage: Int)          // clamped 20–100 by daemon
    case setSailingLower(percentage: Int)   // clamped 20–limit by daemon
    case enableCharging
    case disableCharging
    case setPollingInterval(seconds: Int)   // clamped 1–30 by daemon
}

extension Command: Codable {
    private enum CodingKeys: String, CodingKey { case type, percentage, seconds }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getStatus:
            try c.encode("getStatus", forKey: .type)
        case .setLimit(let p):
            try c.encode("setLimit", forKey: .type)
            try c.encode(p, forKey: .percentage)
        case .setSailingLower(let p):
            try c.encode("setSailingLower", forKey: .type)
            try c.encode(p, forKey: .percentage)
        case .enableCharging:
            try c.encode("enableCharging", forKey: .type)
        case .disableCharging:
            try c.encode("disableCharging", forKey: .type)
        case .setPollingInterval(let s):
            try c.encode("setPollingInterval", forKey: .type)
            try c.encode(s, forKey: .seconds)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "getStatus":           self = .getStatus
        case "enableCharging":      self = .enableCharging
        case "disableCharging":    self = .disableCharging
        case "setLimit":
            self = .setLimit(percentage: try c.decode(Int.self, forKey: .percentage))
        case "setSailingLower":
            self = .setSailingLower(percentage: try c.decode(Int.self, forKey: .percentage))
        case "setPollingInterval":
            self = .setPollingInterval(seconds: try c.decode(Int.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown command type: \(type)")
        }
    }
}