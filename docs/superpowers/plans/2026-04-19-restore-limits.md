# Restore Limits on App Reopen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save the user's charge limit and sailing lower bound to UserDefaults on app quit, then restore them automatically on the next launch.

**Architecture:** On quit, `AppDelegate.applicationWillTerminate` writes `viewModel.limit` and `viewModel.sailingLower` to `UserDefaults` before sending `setLimit(100)`. On reconnect, `BatteryViewModel` reads those keys, sends the restore commands to the daemon, and clears the keys.

**Tech Stack:** Swift, SwiftUI, Combine, XCTest, `UserDefaults.standard`

---

## File Map

| File | Change |
|---|---|
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Add `restoreLimitsIfNeeded()`, call it from `connectedPublisher` subscriber |
| `BatteryCare/BatteryCare/AppDelegate.swift` | Save limits to UserDefaults before `sendNow(.setLimit(100))` |
| `BatteryCare/AppTests/BatteryViewModelTests.swift` | Fix `makeUpdate` helper (add missing `sailingLower`), add restore tests |

---

### Task 1: Fix `makeUpdate` helper in tests and add `sailingLower` to ViewModel tests

The existing `makeUpdate` helper in `BatteryViewModelTests` omits `sailingLower`, which is a required parameter of `StatusUpdate.init`. This causes a compile error after sailing mode was added. Fix it first so the test suite compiles.

**Files:**
- Modify: `BatteryCare/AppTests/BatteryViewModelTests.swift`

- [ ] **Step 1: Update `makeUpdate` to include `sailingLower`**

In `BatteryViewModelTests.swift`, replace the `makeUpdate` function:

```swift
private func makeUpdate(
    percentage: Int = 50, isCharging: Bool = true, isPluggedIn: Bool = true,
    chargingState: ChargingState = .charging, limit: Int = 80, sailingLower: Int = 80,
    pollingInterval: Int = 5, error: DaemonError? = nil, errorDetail: String? = nil
) -> StatusUpdate {
    StatusUpdate(
        currentPercentage: percentage, isCharging: isCharging, isPluggedIn: isPluggedIn,
        chargingState: chargingState, mode: .normal, limit: limit, sailingLower: sailingLower,
        pollingInterval: pollingInterval, error: error, errorDetail: errorDetail
    )
}
```

- [ ] **Step 2: Run tests to confirm they compile and pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: all existing tests pass, no compile errors.

- [ ] **Step 3: Commit**

```bash
git add BatteryCare/AppTests/BatteryViewModelTests.swift
git commit -m "fix: add missing sailingLower to test makeUpdate helper"
```

---

### Task 2: Add `restoreLimitsIfNeeded()` to `BatteryViewModel`

**Files:**
- Modify: `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift`
- Modify: `BatteryCare/AppTests/BatteryViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these three test methods to `BatteryViewModelTests`:

```swift
// MARK: - 6. Restore limits: sends setLimit + setSailingLower on connect when UserDefaults has saved values

@MainActor func testRestoresLimitsOnConnectWhenSaved() async {
    UserDefaults.standard.set(75, forKey: "com.batterycare.savedLimit")
    UserDefaults.standard.set(60, forKey: "com.batterycare.savedSailingLower")

    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    mock.setConnected(true)
    await Task.yield()

    let hasSetLimit = mock.sentCommands.contains {
        if case .setLimit(let p) = $0 { return p == 75 }
        return false
    }
    let hasSetSailingLower = mock.sentCommands.contains {
        if case .setSailingLower(let p) = $0 { return p == 60 }
        return false
    }
    XCTAssertTrue(hasSetLimit, "Expected setLimit(75) to be sent")
    XCTAssertTrue(hasSetSailingLower, "Expected setSailingLower(60) to be sent")

    // Clean up
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedLimit")
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedSailingLower")
}

// MARK: - 7. Restore limits: does nothing on connect when UserDefaults is empty

@MainActor func testNoRestoreOnConnectWhenNothingSaved() async {
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedLimit")
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedSailingLower")

    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    let commandCountBefore = mock.sentCommands.count
    mock.setConnected(true)
    await Task.yield()

    XCTAssertEqual(mock.sentCommands.count, commandCountBefore,
                   "Expected no commands sent when UserDefaults is empty")
}

// MARK: - 8. Restore limits: clears UserDefaults after restoring so reconnects don't re-restore

@MainActor func testClearsUserDefaultsAfterRestoring() async {
    UserDefaults.standard.set(70, forKey: "com.batterycare.savedLimit")
    UserDefaults.standard.set(55, forKey: "com.batterycare.savedSailingLower")

    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    mock.setConnected(true)
    await Task.yield()

    XCTAssertNil(UserDefaults.standard.object(forKey: "com.batterycare.savedLimit"),
                 "savedLimit should be cleared after restore")
    XCTAssertNil(UserDefaults.standard.object(forKey: "com.batterycare.savedSailingLower"),
                 "savedSailingLower should be cleared after restore")
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "testRestores|testNoRestore|testClears|FAIL|error:"
```

Expected: the three new tests fail (method `restoreLimitsIfNeeded` doesn't exist yet).

- [ ] **Step 3: Implement `restoreLimitsIfNeeded` in `BatteryViewModel`**

In `BatteryViewModel.swift`, update `bindClient()` to call the new method on connect:

```swift
private func bindClient() {
    client.statusPublisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] update in
            self?.apply(update)
        }
        .store(in: &cancellables)

    client.connectedPublisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] connected in
            self?.isConnected = connected
            if connected {
                self?.restoreLimitsIfNeeded()
            }
        }
        .store(in: &cancellables)
}
```

Then add the private method at the bottom of the `// MARK: - Private` section:

```swift
private func restoreLimitsIfNeeded() {
    let defaults = UserDefaults.standard
    guard let savedLimit = defaults.object(forKey: "com.batterycare.savedLimit") as? Int,
          let savedSailingLower = defaults.object(forKey: "com.batterycare.savedSailingLower") as? Int
    else { return }
    defaults.removeObject(forKey: "com.batterycare.savedLimit")
    defaults.removeObject(forKey: "com.batterycare.savedSailingLower")
    Task { await client.send(.setLimit(percentage: savedLimit)) }
    Task { await client.send(.setSailingLower(percentage: savedSailingLower)) }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift \
        BatteryCare/AppTests/BatteryViewModelTests.swift
git commit -m "feat: restore charge limits on app reopen via UserDefaults"
```

---

### Task 3: Save limits to UserDefaults on app quit

**Files:**
- Modify: `BatteryCare/BatteryCare/AppDelegate.swift`

- [ ] **Step 1: Update `applicationWillTerminate` to save limits before resetting**

Replace the `applicationWillTerminate` method in `AppDelegate.swift`:

```swift
func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
        UserDefaults.standard.set(viewModel.limit, forKey: "com.batterycare.savedLimit")
        UserDefaults.standard.set(viewModel.sailingLower, forKey: "com.batterycare.savedSailingLower")
        DaemonClient.shared.sendNow(.setLimit(percentage: 100))
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "BUILD|error:"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: all tests pass.

- [ ] **Step 4: Manual smoke test**

1. Build and install the app
2. Set limit to 70% and sailing lower to 55%
3. Quit the app
4. Reopen the app
5. Confirm the menu shows limit=70%, sailing lower=55%
6. Confirm `UserDefaults` keys are cleared after reopen:
   ```bash
   defaults read com.batterycare.app 2>/dev/null | grep saved
   ```
   Expected: no output (keys removed after restore).

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/BatteryCare/AppDelegate.swift
git commit -m "feat: save charge limits to UserDefaults on app quit"
```
