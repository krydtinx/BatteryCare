import Foundation

/// Persisted daemon configuration. Stored at /Library/Application Support/BatteryCare/settings.json.
/// Survives daemon restarts and reboots.
public struct DaemonSettings: Codable {
    /// Charge limit percentage, clamped 20–100 by DaemonCore before saving.
    public var limit: Int
    /// How often DaemonCore polls battery state, clamped 1–30 by DaemonCore before saving.
    public var pollingInterval: Int
    /// When true the daemon actively keeps charging disabled regardless of percentage.
    /// Set by .disableCharging command; cleared by .enableCharging command.
    public var isChargingDisabled: Bool
    /// UID of the app process that installed the daemon. Only this UID may send IPC commands.
    public var allowedUID: uid_t

    public init(
        limit: Int = 80,
        pollingInterval: Int = 5,
        isChargingDisabled: Bool = false,
        allowedUID: uid_t = 0
    ) {
        self.limit = limit
        self.pollingInterval = pollingInterval
        self.isChargingDisabled = isChargingDisabled
        self.allowedUID = allowedUID
    }

    // MARK: - Persistence

    private static let storageURL: URL = {
        URL(fileURLWithPath: "/Library/Application Support/BatteryCare/settings.json")
    }()

    public static func load() -> DaemonSettings {
        guard let data = try? Data(contentsOf: storageURL),
              let settings = try? JSONDecoder().decode(DaemonSettings.self, from: data)
        else {
            return DaemonSettings()
        }
        return settings
    }

    public func save() throws {
        let dir = Self.storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.storageURL, options: .atomic)
    }
}
