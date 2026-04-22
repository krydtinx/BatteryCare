import Foundation

public struct BatteryDetail: Codable, Sendable, Equatable {
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
