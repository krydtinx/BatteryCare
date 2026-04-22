import Foundation

public struct BatteryDetail: Sendable, Equatable {
    public let rawPercentage: Int
    public let cycleCount: Int
    public let healthPercent: Int
    public let maxCapacityMAh: Int
    public let designCapacityMAh: Int
    public let temperatureCelsius: Double
    public let voltageMillivolts: Int

    public init(
        rawPercentage: Int,
        cycleCount: Int,
        healthPercent: Int,
        maxCapacityMAh: Int,
        designCapacityMAh: Int,
        temperatureCelsius: Double,
        voltageMillivolts: Int
    ) {
        self.rawPercentage = rawPercentage
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.maxCapacityMAh = maxCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.temperatureCelsius = temperatureCelsius
        self.voltageMillivolts = voltageMillivolts
    }
}

extension BatteryDetail: Codable {
    private enum CodingKeys: String, CodingKey {
        case rawPercentage, cycleCount, healthPercent, maxCapacityMAh,
             designCapacityMAh, temperatureCelsius, voltageMillivolts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawPercentage      = try container.decode(Int.self,    forKey: .rawPercentage)
        cycleCount         = try container.decode(Int.self,    forKey: .cycleCount)
        healthPercent      = try container.decode(Int.self,    forKey: .healthPercent)
        maxCapacityMAh     = try container.decode(Int.self,    forKey: .maxCapacityMAh)
        designCapacityMAh  = try container.decode(Int.self,    forKey: .designCapacityMAh)
        temperatureCelsius = try container.decode(Double.self, forKey: .temperatureCelsius)
        voltageMillivolts  = try container.decode(Int.self,    forKey: .voltageMillivolts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawPercentage,      forKey: .rawPercentage)
        try container.encode(cycleCount,         forKey: .cycleCount)
        try container.encode(healthPercent,      forKey: .healthPercent)
        try container.encode(maxCapacityMAh,     forKey: .maxCapacityMAh)
        try container.encode(designCapacityMAh,  forKey: .designCapacityMAh)
        try container.encode(temperatureCelsius, forKey: .temperatureCelsius)
        try container.encode(voltageMillivolts,  forKey: .voltageMillivolts)
    }
}
