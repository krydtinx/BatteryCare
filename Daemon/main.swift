import Foundation
import os.log

signal(SIGPIPE, SIG_IGN)

let logger = Logger(subsystem: "com.batterycare.daemon", category: "main")

// Create log directory
let logDir = "/Library/Logs/BatteryCare"
try? FileManager.default.createDirectory(
    atPath: logDir,
    withIntermediateDirectories: true,
    attributes: nil
)

// Load settings
let settings = DaemonSettings.load()

guard settings.allowedUID != 0 else {
    logger.critical("settings.json missing or allowedUID not seeded — refusing to start. Run the app first to install the daemon.")
    exit(1)
}

// Wire up dependencies
let smc = SMCService()
let battery = BatteryMonitor()
let sleepWatcher = SleepWatcher()
let socketServer = SocketServer(
    socketPath: "/var/run/battery-care/daemon.sock",
    allowedUID: settings.allowedUID
)

let core = DaemonCore(
    settings: settings,
    smc: smc,
    battery: battery,
    sleepWatcher: sleepWatcher,
    socketServer: socketServer
)

// Launch core on a detached task; crash on unrecoverable error
Task {
    do {
        try await core.run()
    } catch {
        logger.critical("DaemonCore exited with error: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}

// Keep the process alive for IOKit run-loop notifications
RunLoop.main.run()
