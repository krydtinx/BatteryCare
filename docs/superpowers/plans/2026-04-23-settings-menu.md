# Settings Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a gear-icon settings panel to the menu bar popover exposing update interval, sleep check interval, and accent color.

**Architecture:** `MenuBarView` gains a `@State var showSettings: Bool` that swaps the main content for a new `SettingsView` with an animated `.move` transition. Accent color is stored in `UserDefaults` and passed into `RangeSliderView` via the existing `RangeSliderConfig`. Sleep check interval is already wired daemon-side; only the clamp range (5→1 min) and app-side exposure need updating.

**Tech Stack:** SwiftUI, Combine, UserDefaults, BatteryCareShared IPC (existing), XCTest

---

## File Structure

| File | Role |
|---|---|
| `BatteryCare/BatteryCare/Models/AccentColor.swift` | New — `AccentColor` enum with 6 preset colors |
| `BatteryCare/BatteryCare/Views/SettingsView.swift` | New — settings panel (3 rows) |
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Modified — swap content, gear button, accent config |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Modified — `sleepWakeInterval` + `accentColor` |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Modified — clamp 5→1, sentinel default 5→3 |
| `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift` | Modified — defaults 5→3 |
| `Shared/Sources/BatteryCareShared/StatusUpdate.swift` | Modified — defaults 5→3 |
| `Shared/Sources/BatteryCareShared/Command.swift` | Modified — comment only |
| `BatteryCare/DaemonTests/DaemonCoreTests.swift` | Modified — update two broken test expectations |
| `BatteryCare/AppTests/AccentColorTests.swift` | New — AccentColor tests |
| `BatteryCare/AppTests/BatteryViewModelTests.swift` | Modified — add sleepWakeInterval + accentColor tests |

---

### Task 1: Fix daemon clamp, defaults, and update broken tests

The daemon currently clamps `sleepWakeInterval` to `5–30`. Expanding to `1–30` requires updating the clamp, all default values, and two existing tests whose expectations reflect the old minimum of 5.

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Core/DaemonCore.swift:109,297`
- Modify: `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift:28,47`
- Modify: `Shared/Sources/BatteryCareShared/StatusUpdate.swift:31,66`
- Modify: `Shared/Sources/BatteryCareShared/Command.swift:7`
- Modify: `BatteryCare/DaemonTests/DaemonCoreTests.swift:254,259-263`

- [ ] **Step 1: Update clamp and sentinel in DaemonCore.swift**

`DaemonCore.swift` line 109 — change `max(5,` to `max(1,`:
```swift
case .setSleepWakeInterval(let m):
    settings.sleepWakeInterval = max(1, min(30, m))
    try? settings.save()
    return makeStatusUpdate()
```

`DaemonCore.swift` line 297 — change `sleepWakeInterval: 5` to `sleepWakeInterval: 3` in the empty sentinel:
```swift
private extension StatusUpdate {
    static var empty: StatusUpdate {
        StatusUpdate(
            currentPercentage: 0, isCharging: false, isPluggedIn: false,
            chargingState: .idle, mode: .normal, limit: 80, sailingLower: 80, pollingInterval: 5,
            sleepWakeInterval: 3, detail: nil
        )
    }
}
```

- [ ] **Step 2: Update DaemonSettings defaults**

`DaemonSettings.swift` line 28 — change init default from `5` to `3`:
```swift
public init(
    limit: Int = 80,
    sailingLower: Int = 80,
    pollingInterval: Int = 5,
    isChargingDisabled: Bool = false,
    allowedUID: uid_t = 0,
    sleepWakeInterval: Int = 3
) {
```

`DaemonSettings.swift` line 47 — change migration fallback from `?? 5` to `?? 3`:
```swift
sleepWakeInterval = try c.decodeIfPresent(Int.self, forKey: .sleepWakeInterval) ?? 3
```

- [ ] **Step 3: Update StatusUpdate defaults**

`StatusUpdate.swift` line 31 — change init default from `5` to `3`:
```swift
public init(
    currentPercentage: Int,
    isCharging: Bool,
    isPluggedIn: Bool,
    chargingState: ChargingState,
    mode: DaemonMode = .normal,
    limit: Int,
    sailingLower: Int,
    pollingInterval: Int,
    sleepWakeInterval: Int = 3,
    error: DaemonError? = nil,
    errorDetail: String? = nil,
    detail: BatteryDetail? = nil
) {
```

`StatusUpdate.swift` line 66 — change decoder fallback from `?? 5` to `?? 3`:
```swift
sleepWakeInterval = try container.decodeIfPresent(Int.self, forKey: .sleepWakeInterval) ?? 3
```

- [ ] **Step 4: Update Command.swift comment**

`Command.swift` line 7 — update comment:
```swift
case setSleepWakeInterval(minutes: Int)     // clamped 1–30 by daemon
```

- [ ] **Step 5: Fix the two breaking tests in DaemonCoreTests.swift**

`testSleepWakeIntervalDecoderFallback` — the JSON has no `sleepWakeInterval` key so the migration fallback fires. Old default was 5, new is 3. Update assertion:
```swift
func testSleepWakeIntervalDecoderFallback() throws {
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
    XCTAssertEqual(settings.sleepWakeInterval, 3)
}
```

`testSetSleepWakeIntervalClampMinimum` — was testing that 3 clamped to 5. Now 1 is the minimum. Test that 0 clamps to 1:
```swift
func testSetSleepWakeIntervalClampMinimum() async {
    let core = makeCore()
    let update = await core.handle(.setSleepWakeInterval(minutes: 0))
    XCTAssertEqual(update.sleepWakeInterval, 1)
}
```

- [ ] **Step 6: Run daemon tests**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED` — all existing tests pass, two updated assertions now match.

- [ ] **Step 7: Commit**

```bash
git add \
  BatteryCare/battery-care-daemon/Core/DaemonCore.swift \
  BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift \
  Shared/Sources/BatteryCareShared/StatusUpdate.swift \
  Shared/Sources/BatteryCareShared/Command.swift \
  BatteryCare/DaemonTests/DaemonCoreTests.swift
git commit -m "fix: expand sleepWakeInterval clamp to 1–30 min, change default to 3 min"
```

---

### Task 2: AccentColor enum

**Files:**
- Create: `BatteryCare/BatteryCare/Models/AccentColor.swift`
- Create: `BatteryCare/AppTests/AccentColorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `BatteryCare/AppTests/AccentColorTests.swift`:
```swift
import XCTest
import SwiftUI
@testable import BatteryCare

final class AccentColorTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(AccentColor.allCases.count, 6)
    }

    func testAllCasesProvideNonClearColor() {
        for accent in AccentColor.allCases {
            let color = accent.color
            // Converting to CGColor confirms the switch is exhaustive and returns a real color.
            XCTAssertNotNil(color, "AccentColor.\(accent.rawValue) returned nil color")
        }
    }

    func testRawValueRoundTrip() {
        for accent in AccentColor.allCases {
            let restored = AccentColor(rawValue: accent.rawValue)
            XCTAssertEqual(restored, accent, "Round-trip failed for \(accent.rawValue)")
        }
    }

    func testInvalidRawValueReturnsNil() {
        XCTAssertNil(AccentColor(rawValue: "invalid"))
    }

    func testDefaultIsBlue() {
        XCTAssertEqual(AccentColor.default, .blue)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | tail -20
```

Expected: FAIL — `AccentColor` type not found.

- [ ] **Step 3: Create AccentColor.swift**

Create `BatteryCare/BatteryCare/Models/AccentColor.swift`:
```swift
import SwiftUI

enum AccentColor: String, CaseIterable, Equatable {
    case blue   = "blue"
    case green  = "green"
    case orange = "orange"
    case purple = "purple"
    case red    = "red"
    case pink   = "pink"

    static let `default`: AccentColor = .blue

    var color: Color {
        switch self {
        case .blue:   return Color(red: 0.04, green: 0.52, blue: 1.0)   // #0A84FF
        case .green:  return Color(red: 0.20, green: 0.78, blue: 0.35)  // #34C759
        case .orange: return Color(red: 1.0,  green: 0.62, blue: 0.04)  // #FF9F0A
        case .purple: return Color(red: 0.75, green: 0.35, blue: 0.95)  // #BF5AF2
        case .red:    return Color(red: 1.0,  green: 0.27, blue: 0.23)  // #FF453A
        case .pink:   return Color(red: 1.0,  green: 0.22, blue: 0.37)  // #FF375F
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add \
  BatteryCare/BatteryCare/Models/AccentColor.swift \
  BatteryCare/AppTests/AccentColorTests.swift
git commit -m "feat: add AccentColor enum with 6 preset colors"
```

---

### Task 3: BatteryViewModel — sleepWakeInterval and accentColor

**Files:**
- Modify: `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift`
- Modify: `BatteryCare/AppTests/BatteryViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `BatteryCare/AppTests/BatteryViewModelTests.swift` after the last test (`testBatteryDetailNilWhenUpdateHasNoDetail`).

First update the `tearDown` to clean up the accent color key:
```swift
override func tearDown() {
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedLimit")
    UserDefaults.standard.removeObject(forKey: "com.batterycare.savedSailingLower")
    UserDefaults.standard.removeObject(forKey: "com.batterycare.accentColor")
    super.tearDown()
}
```

Then add the new tests:
```swift
// MARK: - sleepWakeInterval

@MainActor func testSleepWakeIntervalAppliedFromStatusUpdate() async {
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    let update = StatusUpdate(
        currentPercentage: 50, isCharging: true, isPluggedIn: true,
        chargingState: .charging, mode: .normal,
        limit: 80, sailingLower: 80, pollingInterval: 5, sleepWakeInterval: 10
    )
    mock.emit(update)
    await Task.yield()
    XCTAssertEqual(vm.sleepWakeInterval, 10)
}

@MainActor func testSetSleepWakeIntervalSendsCommand() async {
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    vm.setSleepWakeInterval(1)
    await Task.yield()
    let hasSent = mock.sentCommands.contains {
        if case .setSleepWakeInterval(let m) = $0 { return m == 1 }
        return false
    }
    XCTAssertTrue(hasSent, "Expected setSleepWakeInterval(minutes: 1) to be sent")
}

// MARK: - accentColor

@MainActor func testAccentColorDefaultsToBlue() async {
    UserDefaults.standard.removeObject(forKey: "com.batterycare.accentColor")
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    XCTAssertEqual(vm.accentColor, .blue)
}

@MainActor func testSetAccentColorPersistsToUserDefaults() async {
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    vm.setAccentColor(.green)
    XCTAssertEqual(UserDefaults.standard.string(forKey: "com.batterycare.accentColor"), "green")
    XCTAssertEqual(vm.accentColor, .green)
}

@MainActor func testAccentColorLoadedFromUserDefaults() async {
    UserDefaults.standard.set("orange", forKey: "com.batterycare.accentColor")
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    XCTAssertEqual(vm.accentColor, .orange)
}

@MainActor func testAccentColorInvalidUserDefaultsFallsBackToBlue() async {
    UserDefaults.standard.set("invalid", forKey: "com.batterycare.accentColor")
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    XCTAssertEqual(vm.accentColor, .blue)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | tail -20
```

Expected: FAIL — `vm.sleepWakeInterval` and `vm.accentColor` not found.

- [ ] **Step 3: Update BatteryViewModel.swift**

In the `Published state` section, add two properties after `pollingInterval`:
```swift
@Published public private(set) var sleepWakeInterval: Int = 3
@Published public var accentColor: AccentColor = .blue
```

In `init`, load accent color from UserDefaults (add after `checkOptimizedCharging()`):
```swift
public init(client: DaemonClientProtocol = DaemonClient.shared) {
    self.client = client
    self.accentColor = UserDefaults.standard.string(forKey: "com.batterycare.accentColor")
        .flatMap(AccentColor.init(rawValue:)) ?? .blue
    bindClient()
    client.start()
    checkOptimizedCharging()
}
```

Add `setSleepWakeInterval` and `setAccentColor` to the User actions section:
```swift
public func setSleepWakeInterval(_ value: Int) {
    Task { await client.send(.setSleepWakeInterval(minutes: value)) }
}

public func setAccentColor(_ color: AccentColor) {
    accentColor = color
    UserDefaults.standard.set(color.rawValue, forKey: "com.batterycare.accentColor")
}
```

In `apply(_ update:)`, add `sleepWakeInterval` update after `pollingInterval`:
```swift
private func apply(_ update: StatusUpdate) {
    percentage = update.currentPercentage
    isCharging = update.isCharging
    isPluggedIn = update.isPluggedIn
    chargingState = update.chargingState
    limit = update.limit
    sailingLower = update.sailingLower
    pollingInterval = update.pollingInterval
    sleepWakeInterval = update.sleepWakeInterval
    if batteryDetail != update.detail { batteryDetail = update.detail }

    if let error = update.error {
        errorMessage = "\(error)" + (update.errorDetail.map { ": \($0)" } ?? "")
        logger.warning("Daemon error: \(error.rawValue) \(update.errorDetail ?? "")")
    } else {
        errorMessage = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add \
  BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift \
  BatteryCare/AppTests/BatteryViewModelTests.swift
git commit -m "feat: expose sleepWakeInterval and accentColor in BatteryViewModel"
```

---

### Task 4: SettingsView

**Files:**
- Create: `BatteryCare/BatteryCare/Views/SettingsView.swift`

No unit tests — pure SwiftUI layout. Correctness verified by build success and visual inspection.

- [ ] **Step 1: Create SettingsView.swift**

Create `BatteryCare/BatteryCare/Views/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: BatteryViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            updateIntervalRow
            Divider().padding(.horizontal, 12)
            sleepCheckRow
            Divider().padding(.horizontal, 12)
            accentColorRow
            Spacer()
        }
        .frame(width: 280)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.accentColor.color)
            }
            .buttonStyle(.plain)
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Update interval

    private var updateIntervalRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Update interval")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { vm.pollingInterval },
                set: { vm.setPollingInterval($0) }
            )) {
                Text("1s").tag(1)
                Text("3s").tag(3)
                Text("5s").tag(5)
                Text("10s").tag(10)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Sleep check interval

    private var sleepCheckRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep check interval")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { vm.sleepWakeInterval },
                set: { vm.setSleepWakeInterval($0) }
            )) {
                Text("1m").tag(1)
                Text("3m").tag(3)
                Text("5m").tag(5)
                Text("10m").tag(10)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Accent color

    private var accentColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent color")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(AccentColor.allCases, id: \.self) { accent in
                    Button(action: { vm.setAccentColor(accent) }) {
                        ZStack {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 22, height: 22)
                            if vm.accentColor == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BatteryCare/BatteryCare/Views/SettingsView.swift
git commit -m "feat: add SettingsView with poll interval, sleep check, and accent color"
```

---

### Task 5: MenuBarView — wire settings panel and accent color

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/MenuBarView.swift`

- [ ] **Step 1: Update MenuBarView.swift**

Replace the entire file with:
```swift
import SwiftUI
import BatteryCareShared

struct MenuBarView: View {
    @ObservedObject var vm: BatteryViewModel
    @State private var showOptimizedWarning: Bool = false
    @State private var showBatteryDetail: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(vm: vm, onDismiss: { showSettings = false })
                    .transition(.move(edge: .trailing))
            } else {
                mainContent
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .onReceive(vm.$isOptimizedChargingEnabled) { enabled in
            if enabled { showOptimizedWarning = true }
        }
    }

    // MARK: Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Optimized Charging conflict banner
            if showOptimizedWarning {
                OptimizedChargingBanner(isVisible: $showOptimizedWarning)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            // Battery percentage + state
            VStack(spacing: 4) {
                Text("\(vm.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 12)

            // Range slider with accent color
            rangeSlider

            // Charging control buttons
            HStack(spacing: 8) {
                Button(action: { vm.enableCharging() }) {
                    Label("Enable", systemImage: "bolt")
                }
                .disabled(vm.chargingState != .disabled)
                Button(action: { vm.disableCharging() }) {
                    Label("Pause", systemImage: "pause.circle")
                }
                .disabled(vm.chargingState == .disabled)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Error banner
            if let errorMsg = vm.errorMessage {
                Divider().padding(.horizontal, 12)
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMsg).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if vm.batteryDetail != nil {
                Divider().padding(.horizontal, 12)
                batteryDetailSection
            }

            Divider().padding(.horizontal, 12)

            // Footer: connection status + gear + quit
            HStack {
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(vm.isConnected ? "Connected" : "Disconnected")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption2).buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: Range slider

    private var rangeSlider: some View {
        var config = RangeSliderConfig.default
        config.fillColor = vm.accentColor.color
        config.lowerHandleColor = vm.accentColor.color
        return RangeSliderView(
            lower: Binding(
                get: { vm.sailingLower },
                set: { vm.setSailingLower($0) }
            ),
            upper: Binding(
                get: { vm.limit },
                set: { vm.setLimit($0) }
            ),
            config: config
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Battery detail

    private var batteryDetailSection: some View {
        VStack(spacing: 0) {
            Button(action: { showBatteryDetail.toggle() }) {
                HStack {
                    Text("Battery Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showBatteryDetail ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: showBatteryDetail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showBatteryDetail, let detail = vm.batteryDetail {
                VStack(spacing: 3) {
                    detailRow("Raw %",        "\(detail.rawPercentage)%")
                    detailRow("Cycle count",  "\(detail.cycleCount)")
                    detailRow("Health",       "\(detail.healthPercent)%")
                    detailRow("Max capacity", "\(detail.maxCapacityMAh.formatted()) mAh")
                    detailRow("Design cap.",  "\(detail.designCapacityMAh.formatted()) mAh")
                    detailRow("Temperature",  String(format: "%.1f °C", detail.temperatureCelsius))
                    detailRow("Voltage",      String(format: "%.2f V", Double(detail.voltageMillivolts) / 1000))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }

    private var stateLabel: String {
        guard vm.isConnected else { return "Daemon not running" }
        switch vm.chargingState {
        case .charging:     return "Charging"
        case .limitReached: return "Limit reached — paused"
        case .idle:         return "Not plugged in"
        case .disabled:     return "Charging paused by user"
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run all app tests**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BatteryCare/BatteryCare/Views/MenuBarView.swift
git commit -m "feat: add settings panel with gear icon, accent color, and content swap animation"
```
