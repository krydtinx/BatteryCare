import Foundation
import os.log
import Dispatch

signal(SIGPIPE, SIG_IGN)

let logger = Logger(subsystem: "com.batterycare.daemon", category: "main")

// Create log directory
let logDir = "/Library/Logs/BatteryCare"
try? FileManager.default.createDirectory(
    atPath: logDir,
    withIntermediateDirectories: true,
    attributes: nil
)

// Create FileLogger before setting up SIGHUP handler
let fileLogger = FileLogger(path: "/Library/Logs/BatteryCare/daemon.log")

// Set up SIGHUP handler for log rotation
signal(SIGHUP, SIG_IGN)
let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
sighupSource.setEventHandler { fileLogger.reopen() }
sighupSource.resume()

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
let sleepAssertion = SleepAssertionManager()
let socketServer = SocketServer(
    socketPath: "/var/run/battery-care/daemon.sock",
    allowedUID: settings.allowedUID
)
let wakeScheduler = WakeScheduler()

let core = DaemonCore(
    settings: settings,
    smc: smc,
    battery: battery,
    sleepWatcher: sleepWatcher,
    socketServer: socketServer,
    sleepAssertion: sleepAssertion,
    wakeScheduler: wakeScheduler,
    fileLogger: fileLogger
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
