# Sleep Charging: Scheduled Maintenance Wakes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent overnight battery overcharge by scheduling periodic dark maintenance wakes so the daemon can poll battery state, correct SMC charging control, and reschedule — cycling until the charge limit is reached.

**Architecture:** On `willSleep`, if plugged in and below the charge limit, the daemon writes `disableCharging` (best-effort safety net) and schedules a `kIOPMMaintenanceScheduled` dark wake via `IOPMSchedulePowerEvent`. On `hasPoweredOn`, the daemon cancels the pending wake, runs `pollOnce()` (which re-enables charging if still below limit via `applyState()`), and lets the system return to sleep naturally — triggering `willSleep` again and repeating the cycle. A new `FileLogger` writes structured log lines to `/Library/Logs/BatteryCare/daemon.log`, rotated by `newsyslog`.

**Tech Stack:** Swift 6.0, IOKit (`IOPMSchedulePowerEvent`, `IOPMCancelScheduledPowerEvent`), `DispatchSource` (SIGHUP), `newsyslog`, XCTest

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift` | Modify | Add `sleepWakeInterval` field with decoder fallback |
| `Shared/Sources/BatteryCareShared/Command.swift` | Modify | Add `setSleepWakeInterval(minutes:)` case + codable |
| `BatteryCare/battery-care-daemon/Logging/FileLogger.swift` | **Create** | `FileLoggerProtocol` + `FileLogger`: write to file, `reopen()` on rotation |
| `BatteryCare/battery-care-daemon/Power/WakeScheduler.swift` | **Create** | `WakeSchedulerProtocol` + `WakeScheduler`: wraps `IOPMSchedulePowerEvent` |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Modify | Inject new deps, `shouldScheduleWake()`, `scheduleWake()`, `cancelScheduledWake()`, updated `sleepLoop()`, new command handler |
| `BatteryCare/battery-care-daemon/main.swift` | Modify | Wire `FileLogger`, `WakeScheduler`; install SIGHUP handler via `DispatchSource` |
| `Resources/newsyslog/com.batterycare.daemon.conf` | **Create** | `newsyslog` log rotation config |
| `BatteryCare/AppTests/CommandCodableTests.swift` | Modify | Roundtrip test for `setSleepWakeInterval` |
| `BatteryCare/DaemonTests/DaemonCoreTests.swift` | Modify | Add `sleepWakeInterval` decoder test, mock `WakeScheduler`/`FileLogger`, clamping tests |

---

## Task 1: `DaemonSettings` — add `sleepWakeInterval`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift`
- Modify: `BatteryCare/DaemonTests/DaemonCoreTests.swift`

- [ ] **Step 1: Write the failing test**

Open `BatteryCare/DaemonTests/DaemonCoreTests.swift`. Add this test at the bottom of `DaemonCoreTests`:

```swift
// MARK: - sleepWakeInterval decoder fallback

func testSleepWakeIntervalDecoderFallback() throws {
    // settings.json written before sleepWakeInterval existed must load with default 5
    let json = """
    {
        "limit": 80,
        "sailingLower": 80,
        "pollingInterval": 5,
        "isChargingDisabled": false,
        "allowedUID": 501
    }
    """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(DaemonSettings.self, from: json)
    XCTAssertEqual(settings.sleepWakeInterval, 5)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: compile error — `DaemonSettings` has no `sleepWakeInterval`.

- [ ] **Step 3: Add `sleepWakeInterval` to `DaemonSettings`**

In `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift`, add the field and update `init` and the custom decoder:

```swift
public struct DaemonSettings: Codable {
    public var limit: Int
    public var sailingLower: Int
    public var pollingInterval: Int
    public var isChargingDisabled: Bool
    public var allowedUID: uid_t
    /// How long between maintenance wakes during sleep (minutes), clamped 5–30 by DaemonCore.
    public var sleepWakeInterval: Int

    public init(
        limit: Int = 80,
        sailingLower: Int = 80,
        pollingInterval: Int = 5,
        isChargingDisabled: Bool = false,
        allowedUID: uid_t = 0,
        sleepWakeInterval: Int = 5
    ) {
        self.limit = limit
        self.sailingLower = sailingLower
        self.pollingInterval = pollingInterval
        self.isChargingDisabled = isChargingDisabled
        self.allowedUID = allowedUID
        self.sleepWakeInterval = sleepWakeInterval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = try c.decode(Int.self, forKey: .limit)
        sailingLower = try c.decodeIfPresent(Int.self, forKey: .sailingLower) ?? limit
        pollingInterval = try c.decode(Int.self, forKey: .pollingInterval)
        isChargingDisabled = try c.decode(Bool.self, forKey: .isChargingDisabled)
        allowedUID = try c.decode(uid_t.self, forKey: .allowedUID)
        sleepWakeInterval = try c.decodeIfPresent(Int.self, forKey: .sleepWakeInterval) ?? 5
    }
    // ... save() and storageURL unchanged
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: all tests PASS including `testSleepWakeIntervalDecoderFallback`.

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift BatteryCare/DaemonTests/DaemonCoreTests.swift
git commit -m "feat: add sleepWakeInterval to DaemonSettings with decoder fallback"
```

---

## Task 2: `Command` — add `setSleepWakeInterval` case

**Files:**
- Modify: `Shared/Sources/BatteryCareShared/Command.swift`
- Modify: `BatteryCare/AppTests/CommandCodableTests.swift`

- [ ] **Step 1: Write the failing test**

In `BatteryCare/AppTests/CommandCodableTests.swift`, add:

```swift
func testSetSleepWakeIntervalRoundtrip() throws {
    guard case .setSleepWakeInterval(let m) = try roundtrip(.setSleepWakeInterval(minutes: 10)) else {
        XCTFail("Expected .setSleepWakeInterval"); return
    }
    XCTAssertEqual(m, 10)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: compile error — `.setSleepWakeInterval` does not exist on `Command`.

- [ ] **Step 3: Add the case and codable support**

Replace the entire contents of `Shared/Sources/BatteryCareShared/Command.swift`:

```swift
public enum Command: Sendable {
    case getStatus
    case setLimit(percentage: Int)              // clamped 20–100 by daemon
    case setSailingLower(percentage: Int)       // clamped 20–limit by daemon
    case enableCharging
    case disableCharging
    case setPollingInterval(seconds: Int)       // clamped 1–30 by daemon
    case setSleepWakeInterval(minutes: Int)     // clamped 5–30 by daemon
}

extension Command: Codable {
    private enum CodingKeys: String, CodingKey { case type, percentage, seconds, minutes }

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
        case .setSleepWakeInterval(let m):
            try c.encode("setSleepWakeInterval", forKey: .type)
            try c.encode(m, forKey: .minutes)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "getStatus":           self = .getStatus
        case "enableCharging":      self = .enableCharging
        case "disableCharging":     self = .disableCharging
        case "setLimit":
            self = .setLimit(percentage: try c.decode(Int.self, forKey: .percentage))
        case "setSailingLower":
            self = .setSailingLower(percentage: try c.decode(Int.self, forKey: .percentage))
        case "setPollingInterval":
            self = .setPollingInterval(seconds: try c.decode(Int.self, forKey: .seconds))
        case "setSleepWakeInterval":
            self = .setSleepWakeInterval(minutes: try c.decode(Int.self, forKey: .minutes))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown command type: \(type)")
        }
    }
}
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: all tests PASS in both schemes.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/BatteryCareShared/Command.swift BatteryCare/AppTests/CommandCodableTests.swift
git commit -m "feat: add setSleepWakeInterval command to IPC protocol"
```

---

## Task 3: `FileLogger` — new file

**Files:**
- Create: `BatteryCare/battery-care-daemon/Logging/FileLogger.swift`

- [ ] **Step 1: Create the `Logging/` directory and `FileLogger.swift`**

```bash
mkdir -p BatteryCare/battery-care-daemon/Logging
```

Create `BatteryCare/battery-care-daemon/Logging/FileLogger.swift`:

```swift
import Foundation

// MARK: - Protocol

public protocol FileLoggerProtocol: Sendable {
    func info(_ message: String)
    func reopen()
}

// MARK: - No-op (for tests)

public struct NoOpFileLogger: FileLoggerProtocol {
    public init() {}
    public func info(_ message: String) {}
    public func reopen() {}
}

// MARK: - Implementation

public final class FileLogger: FileLoggerProtocol, @unchecked Sendable {

    private let path: String
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(path: String) {
        self.path = path
        openFile()
    }

    /// Appends an info-level line: `2026-04-21T02:15:00.000Z INFO <message>\n`
    public func info(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) INFO \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.write(Data(line.utf8))
    }

    /// Closes and reopens the log file. Called after `newsyslog` rotates the file.
    public func reopen() {
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.closeFile()
        fileHandle = nil
        openFile()
    }

    // MARK: - Private

    private func openFile() {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }
}
```

- [ ] **Step 2: Add `FileLogger.swift` to the Xcode target**

Open `BatteryCare/BatteryCare.xcodeproj` in Xcode. In the Project Navigator, right-click `battery-care-daemon/` → Add Files → select `Logging/FileLogger.swift`. Ensure the target membership is `battery-care-daemon` only.

- [ ] **Step 3: Build to verify it compiles**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build 2>&1 | grep -E "(error:|BUILD)" | head -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BatteryCare/battery-care-daemon/Logging/FileLogger.swift BatteryCare/BatteryCare.xcodeproj
git commit -m "feat: add FileLogger with reopen() for newsyslog rotation"
```

---

## Task 4: `WakeScheduler` — new file

**Files:**
- Create: `BatteryCare/battery-care-daemon/Power/WakeScheduler.swift`

- [ ] **Step 1: Create `WakeScheduler.swift`**

Create `BatteryCare/battery-care-daemon/Power/WakeScheduler.swift`:

```swift
import Foundation
import IOKit.pwr_mgt

// MARK: - Protocol

protocol WakeSchedulerProtocol: Sendable {
    /// Schedule a maintenance (dark) wake at the given date.
    /// Returns true on success.
    @discardableResult
    func schedule(at date: Date) -> Bool
    /// Cancel a previously scheduled wake at the given date.
    func cancel(at date: Date)
}

// MARK: - Implementation

final class WakeScheduler: WakeSchedulerProtocol, @unchecked Sendable {

    // kIOPMMaintenanceScheduled triggers a dark wake (display stays off).
    // Do NOT use kIOPMAutoWake — it causes a full user wake on Apple Silicon.
    // Verify the exact constant string in IOPMLib.h if the build fails:
    //   grep -r "MaintenanceScheduled" $(xcrun --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Headers/
    private let scheduleType = kIOPMMaintenanceScheduled as CFString
    private let clientID = "com.batterycare.daemon" as CFString

    @discardableResult
    func schedule(at date: Date) -> Bool {
        let result = IOPMSchedulePowerEvent(date as CFDate, clientID, scheduleType)
        return result == kIOReturnSuccess
    }

    func cancel(at date: Date) {
        IOPMCancelScheduledPowerEvent(date as CFDate, clientID, scheduleType)
    }
}
```

- [ ] **Step 2: Add `WakeScheduler.swift` to the Xcode target**

In Xcode Project Navigator, right-click `battery-care-daemon/Power/` → Add Files → select `WakeScheduler.swift`. Ensure the target membership is `battery-care-daemon` only.

- [ ] **Step 3: Build to verify it compiles**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build 2>&1 | grep -E "(error:|BUILD)" | head -20
```

Expected: `BUILD SUCCEEDED`. If `kIOPMMaintenanceScheduled` is undefined, use the raw string `"MaintenanceScheduled"` instead.

- [ ] **Step 4: Commit**

```bash
git add BatteryCare/battery-care-daemon/Power/WakeScheduler.swift BatteryCare/BatteryCare.xcodeproj
git commit -m "feat: add WakeScheduler wrapping IOPMSchedulePowerEvent for dark wakes"
```

---

## Task 5: `DaemonCore` — wake scheduling + logging + new command

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Core/DaemonCore.swift`
- Modify: `BatteryCare/DaemonTests/DaemonCoreTests.swift`

- [ ] **Step 1: Add mocks and failing tests to `DaemonCoreTests.swift`**

Add these mocks after `MockSleepAssertion` (around line 42):

```swift
final class MockWakeScheduler: WakeSchedulerProtocol, @unchecked Sendable {
    var scheduledDates: [Date] = []
    var cancelledDates: [Date] = []
    var scheduleResult = true

    @discardableResult
    func schedule(at date: Date) -> Bool {
        scheduledDates.append(date)
        return scheduleResult
    }

    func cancel(at date: Date) {
        cancelledDates.append(date)
    }
}

final class MockFileLogger: FileLoggerProtocol, @unchecked Sendable {
    var lines: [String] = []
    func info(_ message: String) { lines.append(message) }
    func reopen() {}
}
```

Update `makeCore()` to include the new dependencies:

```swift
private func makeCore(
    limit: Int = 80,
    sailingLower: Int = 80,
    pollingInterval: Int = 5,
    sleepWakeInterval: Int = 5,
    isChargingDisabled: Bool = false,
    smc: MockSMCService = MockSMCService(),
    battery: MockBatteryMonitor = MockBatteryMonitor(),
    sleepAssertion: MockSleepAssertion = MockSleepAssertion(),
    wakeScheduler: MockWakeScheduler = MockWakeScheduler(),
    fileLogger: MockFileLogger = MockFileLogger()
) -> DaemonCore {
    let settings = DaemonSettings(
        limit: limit,
        sailingLower: sailingLower,
        pollingInterval: pollingInterval,
        isChargingDisabled: isChargingDisabled,
        allowedUID: getuid(),
        sleepWakeInterval: sleepWakeInterval
    )
    return DaemonCore(
        settings: settings,
        smc: smc,
        battery: battery,
        sleepWatcher: MockSleepWatcher(),
        socketServer: MockSocketServer(),
        sleepAssertion: sleepAssertion,
        wakeScheduler: wakeScheduler,
        fileLogger: fileLogger
    )
}
```

Add failing tests after `testStatusUpdateIncludesSailingLower`:

```swift
// MARK: - 15. setSleepWakeInterval clamps low

func testSetSleepWakeIntervalClampsToMinimum() async {
    let core = makeCore()
    let update = await core.handle(.setSleepWakeInterval(minutes: 1))
    XCTAssertEqual(update.sleepWakeInterval, 5)
}

// MARK: - 16. setSleepWakeInterval clamps high

func testSetSleepWakeIntervalClampsToMaximum() async {
    let core = makeCore()
    let update = await core.handle(.setSleepWakeInterval(minutes: 60))
    XCTAssertEqual(update.sleepWakeInterval, 30)
}

// MARK: - 17. setSleepWakeInterval accepts valid value

func testSetSleepWakeIntervalAcceptsValidValue() async {
    let core = makeCore()
    let update = await core.handle(.setSleepWakeInterval(minutes: 15))
    XCTAssertEqual(update.sleepWakeInterval, 15)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: compile errors — `DaemonCore.init` missing new parameters; `StatusUpdate` has no `sleepWakeInterval`.

- [ ] **Step 3: Update `StatusUpdate` to include `sleepWakeInterval`**

Replace the full contents of `Shared/Sources/BatteryCareShared/StatusUpdate.swift`:

```swift
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
```

- [ ] **Step 4: Update `DaemonCore.swift` — add new dependencies, helpers, command handler, and updated `sleepLoop()`**

Replace the full contents of `BatteryCare/battery-care-daemon/Core/DaemonCore.swift`:

```swift
import Foundation
import BatteryCareShared
import IOKit.pwr_mgt
import os.log

public actor DaemonCore {

    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "smc")

    // MARK: - State

    private var settings: DaemonSettings
    private var stateMachine = ChargingStateMachine()
    private var scheduledWakeDate: Date? = nil

    // MARK: - Dependencies

    private let smc: SMCServiceProtocol
    private let battery: BatteryMonitorProtocol
    private let sleepWatcher: SleepWatcherProtocol
    private let socketServer: SocketServerProtocol
    private let sleepAssertion: SleepAssertionProtocol
    private let wakeScheduler: WakeSchedulerProtocol
    private let fileLogger: FileLoggerProtocol

    // MARK: - Init

    public init(
        settings: DaemonSettings,
        smc: SMCServiceProtocol,
        battery: BatteryMonitorProtocol,
        sleepWatcher: SleepWatcherProtocol,
        socketServer: SocketServerProtocol,
        sleepAssertion: SleepAssertionProtocol,
        wakeScheduler: WakeSchedulerProtocol,
        fileLogger: FileLoggerProtocol
    ) {
        self.settings = settings
        self.smc = smc
        self.battery = battery
        self.sleepWatcher = sleepWatcher
        self.socketServer = socketServer
        self.sleepAssertion = sleepAssertion
        self.wakeScheduler = wakeScheduler
        self.fileLogger = fileLogger
    }

    // MARK: - Run

    public func run() async throws {
        defer { sleepAssertion.release() }
        try smc.open()
        deriveInitialState()

        try socketServer.start { [weak self] command in
            guard let self else { return StatusUpdate.empty }
            return await self.handle(command)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.pollingLoop() }
            group.addTask { await self.sleepLoop() }
            for try await _ in group {}
        }
    }

    // MARK: - Command handler

    public func handle(_ command: Command) async -> StatusUpdate {
        switch command {

        case .getStatus:
            return makeStatusUpdate()

        case .setLimit(let p):
            settings.limit = max(20, min(100, p))
            settings.sailingLower = min(settings.sailingLower, settings.limit)
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.evaluate(reading: reading, limit: settings.limit,
                                      sailingLower: settings.sailingLower,
                                      isDisabled: settings.isChargingDisabled)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .setSailingLower(let p):
            settings.sailingLower = max(20, min(settings.limit, p))
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.evaluate(reading: reading, limit: settings.limit,
                                      sailingLower: settings.sailingLower,
                                      isDisabled: settings.isChargingDisabled)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .setPollingInterval(let s):
            settings.pollingInterval = max(1, min(30, s))
            try? settings.save()
            return makeStatusUpdate()

        case .setSleepWakeInterval(let m):
            settings.sleepWakeInterval = max(5, min(30, m))
            try? settings.save()
            return makeStatusUpdate()

        case .enableCharging:
            settings.isChargingDisabled = false
            try? settings.save()
            if let reading = try? battery.read() {
                stateMachine.forceEnable(reading: reading, limit: settings.limit)
                let smcError = applyState()
                let update = makeStatusUpdate(error: smcError)
                socketServer.broadcast(update)
                return update
            }
            return makeStatusUpdate()

        case .disableCharging:
            settings.isChargingDisabled = true
            try? settings.save()
            stateMachine.forceDisable()
            let smcError = applyState()
            let update = makeStatusUpdate(error: smcError)
            socketServer.broadcast(update)
            return update
        }
    }

    // MARK: - Loops

    private func pollingLoop() async throws {
        while true {
            try Task.checkCancellation()
            pollOnce()
            try await Task.sleep(for: .seconds(settings.pollingInterval))
        }
    }

    private func sleepLoop() async {
        for await event in sleepWatcher.events() {
            switch event {
            case .willSleep:
                if shouldScheduleWake() {
                    let reading = (try? battery.read())
                    let pct = reading?.percentage ?? -1
                    // Best-effort: race with IOAllowPowerChange means this may not execute before sleep.
                    try? smc.perform(.disableCharging)
                    sleepAssertion.release()
                    scheduleWake()
                    let msg = "[sleep] willSleep: battery=\(pct)% limit=\(settings.limit)% → disableCharging, wake scheduled in \(settings.sleepWakeInterval) min"
                    logger.info("\(msg, privacy: .public)")
                    fileLogger.info(msg)
                } else {
                    applyState()
                    let reading = (try? battery.read())
                    let pct = reading?.percentage ?? -1
                    let msg = "[sleep] willSleep: battery=\(pct)% limit=\(settings.limit)% → applyState (no wake scheduled)"
                    logger.info("\(msg, privacy: .public)")
                    fileLogger.info(msg)
                }

            case .hasPoweredOn:
                cancelScheduledWake()
                let reading = (try? battery.read())
                let pct = reading?.percentage ?? -1
                let msg = "[sleep] hasPoweredOn: battery=\(pct)% limit=\(settings.limit)%"
                logger.info("\(msg, privacy: .public)")
                fileLogger.info(msg)
                pollOnce()
            }
        }
    }

    // MARK: - Wake scheduling

    private func shouldScheduleWake() -> Bool {
        guard let reading = try? battery.read() else { return false }
        return reading.isPluggedIn
            && reading.percentage < settings.limit
            && !settings.isChargingDisabled
    }

    private func scheduleWake() {
        cancelScheduledWake()
        let date = Date().addingTimeInterval(Double(settings.sleepWakeInterval) * 60)
        let ok = wakeScheduler.schedule(at: date)
        if ok {
            scheduledWakeDate = date
            let msg = "[sleep] scheduleWake: scheduled at \(date) OK"
            logger.info("\(msg, privacy: .public)")
            fileLogger.info(msg)
        } else {
            let msg = "[sleep] scheduleWake: FAILED (IOPMSchedulePowerEvent returned error)"
            logger.warning("\(msg, privacy: .public)")
            fileLogger.info(msg)
        }
    }

    private func cancelScheduledWake() {
        guard let date = scheduledWakeDate else { return }
        wakeScheduler.cancel(at: date)
        scheduledWakeDate = nil
        let msg = "[sleep] cancelScheduledWake: cancelled \(date)"
        logger.info("\(msg, privacy: .public)")
        fileLogger.info(msg)
    }

    // MARK: - Helpers

    private func pollOnce() {
        do {
            let reading = try battery.read()
            stateMachine.evaluate(
                reading: reading,
                limit: settings.limit,
                sailingLower: settings.sailingLower,
                isDisabled: settings.isChargingDisabled
            )
            applyState()
            let update = makeStatusUpdate(from: reading)
            socketServer.broadcast(update)
            let msg = "[poll] battery=\(reading.percentage)% plugged=\(reading.isPluggedIn) charging=\(reading.isCharging) state=\(stateMachine.state) limit=\(settings.limit)%"
            logger.info("\(msg, privacy: .public)")
            fileLogger.info(msg)
        } catch {
            let update = makeStatusUpdate(error: .batteryReadFailed, errorDetail: "\(error)")
            socketServer.broadcast(update)
        }
    }

    private func deriveInitialState() {
        guard let reading = try? battery.read() else { return }
        if settings.isChargingDisabled {
            stateMachine.forceDisable()
            try? smc.perform(.disableCharging)
        } else {
            stateMachine.evaluate(reading: reading, limit: settings.limit,
                                  sailingLower: settings.sailingLower, isDisabled: false)
            applyState()
        }
    }

    @discardableResult
    private func applyState() -> DaemonError? {
        if stateMachine.state == .charging {
            sleepAssertion.acquire()
        } else {
            sleepAssertion.release()
        }

        switch stateMachine.state {
        case .charging:
            do { try smc.perform(.enableCharging) } catch {
                logger.error("SMC enableCharging failed: \(String(describing: error), privacy: .public)")
                return .smcWriteFailed
            }
        case .limitReached, .disabled:
            do { try smc.perform(.disableCharging) } catch {
                logger.error("SMC disableCharging failed: \(String(describing: error), privacy: .public)")
                return .smcWriteFailed
            }
        case .idle:
            break
        }
        return nil
    }

    private func makeStatusUpdate(
        from reading: BatteryReading? = nil,
        error: DaemonError? = nil,
        errorDetail: String? = nil
    ) -> StatusUpdate {
        let r = reading ?? (try? battery.read()) ?? BatteryReading(percentage: 0, isCharging: false, isPluggedIn: false)
        return StatusUpdate(
            currentPercentage: r.percentage,
            isCharging: r.isCharging,
            isPluggedIn: r.isPluggedIn,
            chargingState: stateMachine.state,
            mode: .normal,
            limit: settings.limit,
            sailingLower: settings.sailingLower,
            pollingInterval: settings.pollingInterval,
            sleepWakeInterval: settings.sleepWakeInterval,
            error: error,
            errorDetail: errorDetail
        )
    }
}

// MARK: - Empty status sentinel

private extension StatusUpdate {
    static var empty: StatusUpdate {
        StatusUpdate(
            currentPercentage: 0, isCharging: false, isPluggedIn: false,
            chargingState: .idle, mode: .normal, limit: 80, sailingLower: 80,
            pollingInterval: 5, sleepWakeInterval: 5
        )
    }
}
```

- [ ] **Step 5: Run failing tests to verify they now compile and pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -30
```

Expected: all tests PASS including the three new `sleepWakeInterval` tests.

- [ ] **Step 6: Run all tests to verify no regressions**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add BatteryCare/battery-care-daemon/Core/DaemonCore.swift \
        BatteryCare/DaemonTests/DaemonCoreTests.swift \
        Shared/Sources/BatteryCareShared/StatusUpdate.swift
git commit -m "feat: add sleep wake scheduling and file logging to DaemonCore"
```

---

## Task 6: Wire `FileLogger` and SIGHUP in `main.swift`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/main.swift`

- [ ] **Step 1: Replace `main.swift` contents**

```swift
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

// Set up file logger
let fileLogger = FileLogger(path: "\(logDir)/daemon.log")

// Install SIGHUP handler for newsyslog log rotation.
// DispatchSource is safe for Swift code — unlike raw signal()/sigaction() which
// cannot call Swift runtime functions (allocations, locks, reference counting).
signal(SIGHUP, SIG_IGN)   // suppress default handling before DispatchSource is ready
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
let wakeScheduler = WakeScheduler()
let socketServer = SocketServer(
    socketPath: "/var/run/battery-care/daemon.sock",
    allowedUID: settings.allowedUID
)

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
```

- [ ] **Step 2: Build both targets**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "(error:|BUILD)" | head -20
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build 2>&1 | grep -E "(error:|BUILD)" | head -20
```

Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 3: Run all tests**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "(FAIL|PASS|error:)" | head -20
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add BatteryCare/battery-care-daemon/main.swift
git commit -m "feat: wire FileLogger and SIGHUP handler in daemon main"
```

---

## Task 7: `newsyslog` rotation config

**Files:**
- Create: `Resources/newsyslog/com.batterycare.daemon.conf`

- [ ] **Step 1: Create the config file**

```bash
mkdir -p Resources/newsyslog
```

Create `Resources/newsyslog/com.batterycare.daemon.conf`:

```
# BatteryCare daemon log rotation
# Fields: logfile_name  owner:group  mode  count  size(KB)  when  flags  pid_file/sig_str
"/Library/Logs/BatteryCare/daemon.log"	root:admin	644	5	256	*	JN	com.batterycare.daemon
```

Field reference:
- `5` — keep 5 rotated archives
- `256` — rotate when file reaches 256 KB
- `*` — size-based only, no time trigger
- `J` — bzip2-compress rotated archives
- `N` — no signal needed to rotate (daemon receives SIGHUP for file reopen separately)
- `com.batterycare.daemon` — send SIGHUP to the process with this label (matches the LaunchDaemon `Label` key)

- [ ] **Step 2: Verify the config parses correctly**

```bash
sudo newsyslog -nrv -f Resources/newsyslog/com.batterycare.daemon.conf 2>&1
```

Expected: output shows the log file entry without errors. (`-n` = dry run, `-r` = no restrictions, `-v` = verbose)

- [ ] **Step 3: Commit**

```bash
git add Resources/newsyslog/com.batterycare.daemon.conf
git commit -m "feat: add newsyslog rotation config for daemon log (256KB, 5 archives)"
```

---

## Manual Verification Checklist

After deploying the daemon binary:

```bash
# Deploy
sudo cp <DerivedData>/Release/battery-care-daemon /Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.batterycare.daemon.plist

# Install newsyslog config
sudo cp Resources/newsyslog/com.batterycare.daemon.conf /etc/newsyslog.d/
```

**Test 1 — Log file created:**
```bash
ls -lh /Library/Logs/BatteryCare/daemon.log
tail -f /Library/Logs/BatteryCare/daemon.log
```
Expected: file exists; `[poll]` lines appear every 5 seconds.

**Test 2 — Wake scheduled on sleep (plugged in, below limit):**
- Set limit to 90%, confirm battery is below 90%
- Close lid
- Open lid after 10+ seconds
- Check log: `[sleep] willSleep: … wake scheduled`, `[sleep] hasPoweredOn: …`

**Test 3 — No wake scheduled when at limit:**
- Set limit to current battery % (e.g. 75%)
- Close lid
- Check log: `[sleep] willSleep: … applyState (no wake scheduled)`

**Test 4 — Log rotation:**
```bash
sudo newsyslog -v -f /etc/newsyslog.d/com.batterycare.daemon.conf
ls /Library/Logs/BatteryCare/
```
Expected: `daemon.log.0.bz2` created, `daemon.log` reset.
