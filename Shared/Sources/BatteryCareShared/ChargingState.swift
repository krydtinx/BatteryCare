public enum ChargingState: String, Codable, Sendable {
    case charging       // below limit, actively charging — CH0B/CH0C = 0x00
    case limitReached   // at/above limit, charging paused — CH0B/CH0C = 0x02
    case idle           // unplugged
    case disabled       // user explicitly paused via .disableCharging command
}
