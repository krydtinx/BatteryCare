import AppKit
import ServiceManagement
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "install")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let daemonPlistName = "com.batterycare.daemon.plist"

    var daemonStatus: SMAppService.Status {
        SMAppService.daemon(plistName: daemonPlistName).status
    }

    /// Seeds settings.json with current user's UID, then registers the daemon via SMAppService.
    /// Must be called BEFORE register() so the daemon reads the correct allowedUID on first start.
    func installDaemon() throws {
        try seedInitialSettings()
        try SMAppService.daemon(plistName: daemonPlistName).register()
        logger.info("Daemon registered via SMAppService")
    }

    func uninstallDaemon() throws {
        try SMAppService.daemon(plistName: daemonPlistName).unregister()
        logger.info("Daemon unregistered")
    }

    // MARK: - Private

    private func seedInitialSettings() throws {
        let settingsURL = URL(filePath: "/Library/Application Support/BatteryCare/settings.json")
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Inline minimal settings struct — mirrors DaemonSettings without importing the Daemon module
        struct MinimalSettings: Encodable {
            let limit: Int = 80
            let pollingInterval: Int = 5
            let isChargingDisabled: Bool = false
            let allowedUID: uid_t
        }
        let settings = MinimalSettings(allowedUID: getuid())
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        logger.info("Seeded settings.json with allowedUID=\(getuid())")
    }
}
