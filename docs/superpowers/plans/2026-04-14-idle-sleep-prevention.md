# Idle Sleep Prevention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent macOS idle-sleep while the daemon is actively charging the battery toward the configured limit, and release the assertion as soon as charging stops.

**Architecture:** A new `SleepAssertionManager` wraps `IOPMAssertionCreateWithName`/`IOPMAssertionRelease` behind a `SleepAssertionProtocol`. `DaemonCore` receives it via constructor injection and calls `acquire()`/`release()` inside `applyState()` based on whether the current state is `.charging`.

**Tech Stack:** Swift 6, IOKit (`IOPMAssertionCreateWithName`, `IOPMAssertionRelease`), XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `BatteryCare/battery-care-daemon/Power/SleepAssertionManager.swift` | Protocol + IOKit implementation |
| Modify | `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Inject dependency, call in `applyState()`, release on exit |
| Modify | `BatteryCare/battery-care-daemon/main.swift` | Wire up `SleepAssertionManager()` |
| Modify | `BatteryCare/DaemonTests/DaemonCoreTests.swift` | `MockSleepAssertion` + 4 new tests |

---

## Task 1: Write failing tests

**Files:**
- Modify: `BatteryCare/DaemonTests/DaemonCoreTests.swift`

- [ ] **Step 1: Add `MockSleepAssertion` after the existing mocks (after line 31)**

```swift
final class MockSleepAssertion: SleepAssertionProtocol, @unchecked Sendable {
    var acquireCount = 0
    var releaseCount = 0
    var isActive: Bool { acquireCount > releaseCount }
    func acquire() { acquireCount += 1 }
    func release() { releaseCount += 1 }
}
```

- [ ] **Step 2: Update `makeCore()` to accept an optional `sleepAssertion` parameter**

Replace the existing `makeCore()` function (lines 37–57) with:

```swift
private func makeCore(
    limit: Int = 80,
    pollingInterval: Int = 5,
    isChargingDisabled: Bool = false,
    smc: MockSMCService = MockSMCService(),
    battery: MockBatteryMonitor = MockBatteryMonitor(),
    sleepAssertion: MockSleepAssertion = MockSleepAssertion()
) -> DaemonCore {
    let settings = DaemonSettings(
        limit: limit,
        pollingInterval: pollingInterval,
        isChargingDisabled: isChargingDisabled,
        allowedUID: getuid()
    )
    return DaemonCore(
        settings: settings,
        smc: smc,
        battery: battery,
        sleepWatcher: MockSleepWatcher(),
        socketServer: MockSocketServer(),
        sleepAssertion: sleepAssertion
    )
}
```

- [ ] **Step 3: Add 4 new test methods at the end of `DaemonCoreTests`**

```swift
// MARK: - 8. Assertion acquired during charging

func testAssertionAcquiredDuringCharging() async {
    let assertion = MockSleepAssertion()
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 60, isCharging: true, isPluggedIn: true)
    let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
    _ = await core.handle(.setLimit(percentage: 80))
    XCTAssertTrue(assertion.isActive)
    XCTAssertEqual(assertion.acquireCount, 1)
}

// MARK: - 9. Assertion released at limit reached

func testAssertionReleasedAtLimitReached() async {
    let assertion = MockSleepAssertion()
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 80, isCharging: false, isPluggedIn: true)
    let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
    _ = await core.handle(.setLimit(percentage: 80))
    XCTAssertFalse(assertion.isActive)
    XCTAssertEqual(assertion.acquireCount, 0)
}

// MARK: - 10. Assertion released when idle (unplugged)

func testAssertionReleasedWhenIdle() async {
    let assertion = MockSleepAssertion()
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 60, isCharging: false, isPluggedIn: false)
    let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
    _ = await core.handle(.setLimit(percentage: 80))
    XCTAssertFalse(assertion.isActive)
    XCTAssertEqual(assertion.acquireCount, 0)
}

// MARK: - 11. Assertion released when charging disabled

func testAssertionReleasedWhenChargingDisabled() async {
    let assertion = MockSleepAssertion()
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 60, isCharging: true, isPluggedIn: true)
    let core = makeCore(limit: 80, battery: battery, sleepAssertion: assertion)
    _ = await core.handle(.disableCharging)
    XCTAssertFalse(assertion.isActive)
    XCTAssertEqual(assertion.acquireCount, 0)
}
```

- [ ] **Step 4: Run tests — expect compile failure (DaemonCore init doesn't accept `sleepAssertion` yet)**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "error:|FAILED|PASSED"
```

Expected: compile error — `extra argument 'sleepAssertion' in call`

---

## Task 2: Create `SleepAssertionManager`

**Files:**
- Create: `BatteryCare/battery-care-daemon/Power/SleepAssertionManager.swift`

- [ ] **Step 1: Create the file with protocol and implementation**

```swift
import Foundation
import IOKit.pwr_mgt
import os.log

// MARK: - Protocol

public protocol SleepAssertionProtocol: Sendable {
    func acquire()
    func release()
}

// MARK: - Implementation

public final class SleepAssertionManager: SleepAssertionProtocol, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.batterycare.daemon", category: "power")
    private var assertionID: IOPMAssertionID? = nil

    public init() {}

    /// Acquires a system idle-sleep prevention assertion. No-op if already held.
    public func acquire() {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BatteryCare: actively charging battery" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            logger.debug("Sleep assertion acquired (id=\(id))")
        } else {
            logger.warning("Failed to acquire sleep assertion: \(result, privacy: .public)")
        }
    }

    /// Releases the held assertion. No-op if none is held.
    public func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
        logger.debug("Sleep assertion released")
    }

    deinit {
        release()
    }
}
```

> **Note:** The `Power/` directory does not exist yet. Create the file on disk, then in Xcode: right-click `battery-care-daemon` group → Add Files → select `Power/SleepAssertionManager.swift` → check **both** target memberships: `battery-care-daemon` AND `DaemonTests` (the test target needs `SleepAssertionProtocol` to compile `MockSleepAssertion`).

---

## Task 3: Integrate into `DaemonCore`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Core/DaemonCore.swift`

- [ ] **Step 1: Add `sleepAssertion` to the dependencies section (after `socketServer`)**

```swift
// MARK: - Dependencies

private let smc: SMCServiceProtocol
private let battery: BatteryMonitorProtocol
private let sleepWatcher: SleepWatcherProtocol
private let socketServer: SocketServerProtocol
private let sleepAssertion: SleepAssertionProtocol
```

- [ ] **Step 2: Add `sleepAssertion` parameter to `init()`**

Replace the existing `init` (lines 23–35):

```swift
public init(
    settings: DaemonSettings,
    smc: SMCServiceProtocol,
    battery: BatteryMonitorProtocol,
    sleepWatcher: SleepWatcherProtocol,
    socketServer: SocketServerProtocol,
    sleepAssertion: SleepAssertionProtocol
) {
    self.settings = settings
    self.smc = smc
    self.battery = battery
    self.sleepWatcher = sleepWatcher
    self.socketServer = socketServer
    self.sleepAssertion = sleepAssertion
}
```

- [ ] **Step 3: Add `defer { sleepAssertion.release() }` to `run()` (after `deriveInitialState()`)**

Replace `run()` (lines 40–54):

```swift
public func run() async throws {
    try smc.open()
    deriveInitialState()

    try socketServer.start { [weak self] command in
        guard let self else { return StatusUpdate.empty }
        return await self.handle(command)
    }

    defer { sleepAssertion.release() }

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.pollingLoop() }
        group.addTask { await self.sleepLoop() }
        for try await _ in group {}
    }
}
```

- [ ] **Step 4: Update `applyState()` to call the assertion before the SMC switch**

Replace `applyState()` (lines 156–173):

```swift
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
```

---

## Task 4: Wire up in `main.swift`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/main.swift`

- [ ] **Step 1: Add `SleepAssertionManager()` to the dependency wiring and `DaemonCore` init**

Replace the wiring block (lines 25–39):

```swift
let smc = SMCService()
let battery = BatteryMonitor()
let sleepWatcher = SleepWatcher()
let sleepAssertion = SleepAssertionManager()
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
    sleepAssertion: sleepAssertion
)
```

---

## Task 5: Run tests and verify

- [ ] **Step 1: Run DaemonTests**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "error:|Test Case|FAILED|passed|failed"
```

Expected output includes:
```
Test Case '-[DaemonTests.DaemonCoreTests testAssertionAcquiredDuringCharging]' passed
Test Case '-[DaemonTests.DaemonCoreTests testAssertionReleasedAtLimitReached]' passed
Test Case '-[DaemonTests.DaemonCoreTests testAssertionReleasedWhenIdle]' passed
Test Case '-[DaemonTests.DaemonCoreTests testAssertionReleasedWhenChargingDisabled]' passed
```

All 11 tests should pass.

- [ ] **Step 2: Build the daemon target to catch any wiring errors**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

---

## Task 6: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add BatteryCare/battery-care-daemon/Power/SleepAssertionManager.swift \
        BatteryCare/battery-care-daemon/Core/DaemonCore.swift \
        BatteryCare/battery-care-daemon/main.swift \
        BatteryCare/DaemonTests/DaemonCoreTests.swift \
        BatteryCare/BatteryCare.xcodeproj/project.pbxproj
git commit -m "Prevent idle sleep during active charging session"
```
