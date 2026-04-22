# Battery Detail Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an expandable inline battery detail panel to the menu bar popover showing raw BMS percentage, cycle count, health, capacity, temperature, and voltage — read from `AppleSmartBattery` IORegistry on every poll tick.

**Architecture:** `BatteryDetail` is a new `Codable/Sendable/Equatable` struct in Shared that flows as a side-car through the existing pipeline: `BatteryMonitor.ioregRead()` → `BatteryReading.detail` → `StatusUpdate.detail` → `BatteryViewModel.batteryDetail` → `MenuBarView` expandable section. The charging state machine is untouched.

**Tech Stack:** Swift 6, IOKit/IORegistry, SwiftUI, Combine, XCTest, xcodebuild

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Shared/Sources/BatteryCareShared/BatteryDetail.swift` | Create | `BatteryDetail` struct |
| `BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift` | Modify | Add `import BatteryCareShared`; add `detail` to `BatteryReading`; replace `ioregIsCharging()` with `ioregRead()` |
| `Shared/Sources/BatteryCareShared/StatusUpdate.swift` | Modify | Add `detail: BatteryDetail?` field |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Modify | Forward `r.detail` in `makeStatusUpdate` |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Modify | Add `@Published batteryDetail: BatteryDetail?` with Equatable diffing |
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Modify | Add expandable battery detail section |
| `BatteryCare/AppTests/CommandCodableTests.swift` | Modify | Add `BatteryDetail` Codable tests and `StatusUpdate.detail` roundtrip tests |
| `BatteryCare/DaemonTests/DaemonCoreTests.swift` | Modify | Add test that `makeStatusUpdate` forwards `detail` |
| `BatteryCare/AppTests/BatteryViewModelTests.swift` | Modify | Add test for `batteryDetail` published property |

---

## Task 1: `BatteryDetail` struct

**Files:**
- Create: `Shared/Sources/BatteryCareShared/BatteryDetail.swift`
- Test: `BatteryCare/AppTests/CommandCodableTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `BatteryCare/AppTests/CommandCodableTests.swift` inside the `CommandCodableTests` class, before the closing `}`:

```swift
// MARK: - BatteryDetail

func testBatteryDetailCodableRoundtrip() throws {
    let detail = BatteryDetail(
        rawPercentage: 85, cycleCount: 312, healthPercent: 91,
        maxCapacityMAh: 4821, designCapacityMAh: 5279,
        temperatureCelsius: 28.4, voltageMillivolts: 12455
    )
    let data = try encoder.encode(detail)
    let decoded = try decoder.decode(BatteryDetail.self, from: data)
    XCTAssertEqual(decoded, detail)
}

func testBatteryDetailEquatable() {
    let a = BatteryDetail(rawPercentage: 85, cycleCount: 312, healthPercent: 91,
                          maxCapacityMAh: 4821, designCapacityMAh: 5279,
                          temperatureCelsius: 28.4, voltageMillivolts: 12455)
    let b = BatteryDetail(rawPercentage: 85, cycleCount: 312, healthPercent: 91,
                          maxCapacityMAh: 4821, designCapacityMAh: 5279,
                          temperatureCelsius: 28.4, voltageMillivolts: 12455)
    let c = BatteryDetail(rawPercentage: 90, cycleCount: 312, healthPercent: 91,
                          maxCapacityMAh: 4821, designCapacityMAh: 5279,
                          temperatureCelsius: 28.4, voltageMillivolts: 12455)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "error:|FAILED|testBatteryDetail"
```

Expected: compile error — `BatteryDetail` not found.

- [ ] **Step 3: Create `BatteryDetail.swift`**

Create `Shared/Sources/BatteryCareShared/BatteryDetail.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED|testBatteryDetail"
```

Expected: `testBatteryDetailCodableRoundtrip` and `testBatteryDetailEquatable` both PASSED.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/BatteryCareShared/BatteryDetail.swift BatteryCare/AppTests/CommandCodableTests.swift
git commit -m "feat: add BatteryDetail struct to Shared"
```

---

## Task 2: Extend `BatteryReading` and refactor `BatteryMonitor`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift`
- Test: `BatteryCare/DaemonTests/DaemonCoreTests.swift`

`BatteryMonitor.ioregIsCharging()` currently opens `AppleSmartBattery`, reads one key, and closes. Replace it with `ioregRead()` that reads all keys in one pass. Since `BatteryReading` now references `BatteryDetail` (from Shared), `BatteryMonitor.swift` needs `import BatteryCareShared`.

- [ ] **Step 1: Write the failing test**

Add to `BatteryCare/DaemonTests/DaemonCoreTests.swift` inside `DaemonCoreTests`, before the closing `}`:

```swift
// MARK: - BatteryReading detail field

func testBatteryReadingDefaultDetailIsNil() {
    let reading = BatteryReading(percentage: 50, isCharging: true, isPluggedIn: true)
    XCTAssertNil(reading.detail)
}

func testBatteryReadingStoresDetail() {
    let detail = BatteryDetail(
        rawPercentage: 85, cycleCount: 312, healthPercent: 91,
        maxCapacityMAh: 4821, designCapacityMAh: 5279,
        temperatureCelsius: 28.4, voltageMillivolts: 12455
    )
    let reading = BatteryReading(percentage: 85, isCharging: true, isPluggedIn: true, detail: detail)
    XCTAssertEqual(reading.detail, detail)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "error:|FAILED|testBatteryReading"
```

Expected: compile error — `BatteryReading` has no `detail` parameter.

- [ ] **Step 3: Update `BatteryMonitor.swift`**

Replace the full contents of `BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift`:

```swift
import Foundation
import IOKit
import IOKit.ps
import BatteryCareShared

// MARK: - Protocol

public protocol BatteryMonitorProtocol: Sendable {
    func read() throws -> BatteryReading
}

// MARK: - Reading

public struct BatteryReading: Sendable {
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let detail: BatteryDetail?

    public init(percentage: Int, isCharging: Bool, isPluggedIn: Bool, detail: BatteryDetail? = nil) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.detail = detail
    }
}

// MARK: - Errors

public enum BatteryMonitorError: Error {
    case serviceNotFound
    case readFailed(String)
}

// MARK: - Implementation

/// Reads battery state via IOPSCopyPowerSourcesInfo — the standard public API for all Mac types.
public final class BatteryMonitor: BatteryMonitorProtocol, @unchecked Sendable {

    public init() {}

    public func read() throws -> BatteryReading {
        guard let rawInfo = IOPSCopyPowerSourcesInfo() else {
            throw BatteryMonitorError.serviceNotFound
        }
        let info = rawInfo.takeRetainedValue()

        guard let rawList = IOPSCopyPowerSourcesList(info) else {
            throw BatteryMonitorError.serviceNotFound
        }
        let list = rawList.takeRetainedValue() as NSArray

        guard list.count > 0 else {
            throw BatteryMonitorError.readFailed("No power sources found")
        }

        // swiftlint:disable force_cast
        let source = list[0] as! CFTypeRef
        // swiftlint:enable force_cast

        // IOPSGetPowerSourceDescription is NOT a Copy — must use takeUnretainedValue
        guard let rawDesc = IOPSGetPowerSourceDescription(info, source) else {
            throw BatteryMonitorError.readFailed("No power source description")
        }
        // CFDictionary must be bridged via NSDictionary (direct [String:Any] cast fails)
        guard let desc = rawDesc.takeUnretainedValue() as? NSDictionary else {
            throw BatteryMonitorError.readFailed("Cannot read power source description")
        }

        let percentage  = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue ?? 0
        let sourceState = desc[kIOPSPowerSourceStateKey] as? String ?? kIOPSBatteryPowerValue
        let isPluggedIn = sourceState != kIOPSBatteryPowerValue

        // IOPS IsCharging lags after SMC writes; read directly from IORegistry for accuracy
        let (isCharging, detail) = ioregRead()

        return BatteryReading(
            percentage: min(max(percentage, 0), 100),
            isCharging: isPluggedIn && isCharging,
            isPluggedIn: isPluggedIn,
            detail: detail
        )
    }

    /// Opens AppleSmartBattery once and reads IsCharging + all detail keys in one pass.
    /// Returns (isCharging: Bool, detail: BatteryDetail?) — detail is nil if any key is missing
    /// or if MaxCapacity/DesignCapacity are zero (guards against divide-by-zero).
    ///
    /// Temperature note: Apple Smart Battery Spec unit is 0.1 Kelvin.
    /// Formula: (raw / 10.0) - 273.15 = °C
    ///
    /// Capacity note: On Apple Silicon, IOPSCurrentCapacityKey is already a percentage.
    /// AppleRawCurrentCapacity / AppleRawMaxCapacity are the true mAh values.
    private func ioregRead() -> (isCharging: Bool, detail: BatteryDetail?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                          IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (false, nil) }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString,
                                            kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let isCharging = (prop("IsCharging") as? NSNumber)?.boolValue ?? false

        let rawCurrent = (prop("AppleRawCurrentCapacity") as? NSNumber)?.intValue
        let rawMax     = (prop("AppleRawMaxCapacity")     as? NSNumber)?.intValue
        let design     = (prop("DesignCapacity")          as? NSNumber)?.intValue
        let cycles     = (prop("CycleCount")              as? NSNumber)?.intValue
        let tempRaw    = (prop("Temperature")             as? NSNumber)?.intValue
        let voltage    = (prop("Voltage")                 as? NSNumber)?.intValue

        guard let c = rawCurrent, let m = rawMax, let d = design,
              let cy = cycles, let t = tempRaw, let v = voltage,
              m > 0, d > 0 else {
            return (isCharging, nil)
        }

        let detail = BatteryDetail(
            rawPercentage:      c * 100 / m,
            cycleCount:         cy,
            healthPercent:      m * 100 / d,
            maxCapacityMAh:     m,
            designCapacityMAh:  d,
            temperatureCelsius: (Double(t) / 10.0) - 273.15,
            voltageMillivolts:  v
        )
        return (isCharging, detail)
    }
}
```

- [ ] **Step 4: Run both test suites to confirm they pass**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
```

Expected: both suites PASSED (existing tests still compile because `detail` defaults to `nil`).

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift BatteryCare/DaemonTests/DaemonCoreTests.swift
git commit -m "feat: add BatteryDetail to BatteryReading; refactor ioregRead()"
```

---

## Task 3: Add `detail` to `StatusUpdate`

**Files:**
- Modify: `Shared/Sources/BatteryCareShared/StatusUpdate.swift`
- Test: `BatteryCare/AppTests/CommandCodableTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `BatteryCare/AppTests/CommandCodableTests.swift` inside the `CommandCodableTests` class:

```swift
// MARK: - StatusUpdate detail field

func testStatusUpdateWithDetailRoundtrip() throws {
    let detail = BatteryDetail(
        rawPercentage: 85, cycleCount: 312, healthPercent: 91,
        maxCapacityMAh: 4821, designCapacityMAh: 5279,
        temperatureCelsius: 28.4, voltageMillivolts: 12455
    )
    let update = StatusUpdate(
        currentPercentage: 57, isCharging: true, isPluggedIn: true,
        chargingState: .charging, mode: .normal,
        limit: 80, sailingLower: 70, pollingInterval: 5,
        detail: detail
    )
    let data = try encoder.encode(update)
    let decoded = try decoder.decode(StatusUpdate.self, from: data)
    XCTAssertEqual(decoded.detail, detail)
}

func testStatusUpdateDetailDecodesNilWhenKeyMissing() throws {
    // JSON from an older daemon that doesn't send "detail"
    let json = Data("""
    {"currentPercentage":57,"isCharging":true,"isPluggedIn":true,"chargingState":"charging",
     "mode":"normal","limit":80,"sailingLower":70,"pollingInterval":5,"sleepWakeInterval":5}
    """.utf8)
    let decoded = try decoder.decode(StatusUpdate.self, from: json)
    XCTAssertNil(decoded.detail)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "error:|FAILED|testStatusUpdateWith"
```

Expected: compile error — `StatusUpdate.init` has no `detail` parameter.

- [ ] **Step 3: Update `StatusUpdate.swift`**

Replace the full contents of `Shared/Sources/BatteryCareShared/StatusUpdate.swift`:

```swift
public enum DaemonError: String, Codable, Sendable {
    case smcConnectionFailed
    case smcKeyNotFound
    case smcWriteFailed
    case batteryReadFailed
}

public struct StatusUpdate: Sendable {
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
    public let detail: BatteryDetail?

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
        errorDetail: String? = nil,
        detail: BatteryDetail? = nil
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
        self.detail = detail
    }
}

extension StatusUpdate: Codable {
    private enum CodingKeys: String, CodingKey {
        case currentPercentage, isCharging, isPluggedIn, chargingState, mode, limit,
             sailingLower, pollingInterval, sleepWakeInterval, error, errorDetail, detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPercentage = try container.decode(Int.self, forKey: .currentPercentage)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        isPluggedIn = try container.decode(Bool.self, forKey: .isPluggedIn)
        chargingState = try container.decode(ChargingState.self, forKey: .chargingState)
        mode = try container.decode(DaemonMode.self, forKey: .mode)
        limit = try container.decode(Int.self, forKey: .limit)
        sailingLower = try container.decode(Int.self, forKey: .sailingLower)
        pollingInterval = try container.decode(Int.self, forKey: .pollingInterval)
        sleepWakeInterval = try container.decodeIfPresent(Int.self, forKey: .sleepWakeInterval) ?? 5
        error = try container.decodeIfPresent(DaemonError.self, forKey: .error)
        errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
        detail = try container.decodeIfPresent(BatteryDetail.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPercentage, forKey: .currentPercentage)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(isPluggedIn, forKey: .isPluggedIn)
        try container.encode(chargingState, forKey: .chargingState)
        try container.encode(mode, forKey: .mode)
        try container.encode(limit, forKey: .limit)
        try container.encode(sailingLower, forKey: .sailingLower)
        try container.encode(pollingInterval, forKey: .pollingInterval)
        try container.encode(sleepWakeInterval, forKey: .sleepWakeInterval)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(errorDetail, forKey: .errorDetail)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}
```

- [ ] **Step 4: Run both test suites**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
```

Expected: both suites PASSED. All existing tests still compile because `detail: BatteryDetail? = nil` is the default.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/BatteryCareShared/StatusUpdate.swift BatteryCare/AppTests/CommandCodableTests.swift
git commit -m "feat: add detail field to StatusUpdate"
```

---

## Task 4: `DaemonCore` forwards `detail` through `makeStatusUpdate`

**Files:**
- Modify: `BatteryCare/battery-care-daemon/Core/DaemonCore.swift`
- Test: `BatteryCare/DaemonTests/DaemonCoreTests.swift`

The private `makeStatusUpdate(from:error:errorDetail:)` builds a `StatusUpdate` from a `BatteryReading`. Currently it doesn't pass `detail`. Update it to forward `r.detail`. Also update `StatusUpdate.empty` to pass `detail: nil` explicitly.

- [ ] **Step 1: Write the failing test**

Add to `BatteryCare/DaemonTests/DaemonCoreTests.swift` inside `DaemonCoreTests`:

```swift
// MARK: - detail forwarded through makeStatusUpdate

func testGetStatusForwardsDetail() async {
    let detail = BatteryDetail(
        rawPercentage: 85, cycleCount: 312, healthPercent: 91,
        maxCapacityMAh: 4821, designCapacityMAh: 5279,
        temperatureCelsius: 28.4, voltageMillivolts: 12455
    )
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 72, isCharging: true, isPluggedIn: true, detail: detail)
    let core = makeCore(limit: 80, battery: battery)
    let update = await core.handle(.getStatus)
    XCTAssertEqual(update.detail, detail)
}

func testGetStatusDetailIsNilWhenReadingHasNoDetail() async {
    let battery = MockBatteryMonitor()
    battery.reading = BatteryReading(percentage: 72, isCharging: true, isPluggedIn: true)
    let core = makeCore(limit: 80, battery: battery)
    let update = await core.handle(.getStatus)
    XCTAssertNil(update.detail)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "error:|FAILED|testGetStatusForwards"
```

Expected: `testGetStatusForwardsDetail` FAILED — `update.detail` is `nil` because `makeStatusUpdate` doesn't forward it yet.

- [ ] **Step 3: Update `makeStatusUpdate` in `DaemonCore.swift`**

Find `makeStatusUpdate(from:error:errorDetail:)` at the bottom of `DaemonCore.swift` (around line 267) and replace it:

```swift
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
        errorDetail: errorDetail,
        detail: r.detail
    )
}
```

Also update `StatusUpdate.empty` at the bottom of the file:

```swift
private extension StatusUpdate {
    static var empty: StatusUpdate {
        StatusUpdate(
            currentPercentage: 0, isCharging: false, isPluggedIn: false,
            chargingState: .idle, mode: .normal, limit: 80, sailingLower: 80, pollingInterval: 5,
            sleepWakeInterval: 5, detail: nil
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
```

Expected: all DaemonTests PASSED including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/battery-care-daemon/Core/DaemonCore.swift BatteryCare/DaemonTests/DaemonCoreTests.swift
git commit -m "feat: forward BatteryDetail through DaemonCore makeStatusUpdate"
```

---

## Task 5: `BatteryViewModel` — `batteryDetail` published property

**Files:**
- Modify: `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift`
- Test: `BatteryCare/AppTests/BatteryViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `BatteryCare/AppTests/BatteryViewModelTests.swift` inside `BatteryViewModelTests`. The existing `makeUpdate` helper doesn't pass `detail` — since `StatusUpdate.init` defaults `detail` to `nil`, all existing calls still compile.

```swift
// MARK: - batteryDetail published property

@MainActor func testBatteryDetailUpdatedFromStatusUpdate() async {
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    let detail = BatteryDetail(
        rawPercentage: 85, cycleCount: 312, healthPercent: 91,
        maxCapacityMAh: 4821, designCapacityMAh: 5279,
        temperatureCelsius: 28.4, voltageMillivolts: 12455
    )
    let update = StatusUpdate(
        currentPercentage: 57, isCharging: true, isPluggedIn: true,
        chargingState: .charging, mode: .normal,
        limit: 80, sailingLower: 70, pollingInterval: 5,
        detail: detail
    )
    mock.emit(update)
    await Task.yield()
    XCTAssertEqual(vm.batteryDetail, detail)
}

@MainActor func testBatteryDetailNilWhenUpdateHasNoDetail() async {
    let mock = MockDaemonClient()
    let vm = BatteryViewModel(client: mock)
    mock.emit(makeUpdate()) // makeUpdate has no detail → nil
    await Task.yield()
    XCTAssertNil(vm.batteryDetail)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "error:|FAILED|testBatteryDetail"
```

Expected: compile error — `BatteryViewModel` has no `batteryDetail` property.

- [ ] **Step 3: Update `BatteryViewModel.swift`**

Add `batteryDetail` published property after the existing `@Published` block:

```swift
@Published public private(set) var batteryDetail: BatteryDetail? = nil
```

Update `apply(_ update: StatusUpdate)` to include diffing (Equatable means we only publish when the value actually changes, avoiding re-renders on every poll tick):

```swift
private func apply(_ update: StatusUpdate) {
    percentage = update.currentPercentage
    isCharging = update.isCharging
    isPluggedIn = update.isPluggedIn
    chargingState = update.chargingState
    limit = update.limit
    sailingLower = update.sailingLower
    pollingInterval = update.pollingInterval
    if batteryDetail != update.detail { batteryDetail = update.detail }

    if let error = update.error {
        errorMessage = "\(error)" + (update.errorDetail.map { ": \($0)" } ?? "")
        logger.warning("Daemon error: \(error.rawValue) \(update.errorDetail ?? "")")
    } else {
        errorMessage = nil
    }
}
```

- [ ] **Step 4: Run both test suites**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
```

Expected: both suites PASSED.

- [ ] **Step 5: Commit**

```bash
git add BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift BatteryCare/AppTests/BatteryViewModelTests.swift
git commit -m "feat: add batteryDetail published property to BatteryViewModel"
```

---

## Task 6: `MenuBarView` — expandable battery detail section

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/MenuBarView.swift`

No unit test possible for SwiftUI views — verify visually by building and running the app.

- [ ] **Step 1: Add `showBatteryDetail` state to `MenuBarView`**

In `MenuBarView`, add a new `@State` property after the existing state declarations:

```swift
@State private var showBatteryDetail: Bool = false
```

The struct now has three `@State` properties:
```swift
@State private var showOptimizedWarning: Bool = false
@State private var isEditingSailingLower: Bool = false
@State private var showBatteryDetail: Bool = false
```

- [ ] **Step 2: Add expandable section to `body`**

In `MenuBarView.body`, the current layout is:

```
VStack(spacing: 0) {
    OptimizedChargingBanner (conditional)
    VStack { Text percentage + stateLabel }   ← main battery block
    Divider
    VStack { Charge limit slider }
    VStack { Sailing lower slider }
    ...
```

Insert the battery detail section between the main battery block and the charge limit slider. The existing `Divider` between the battery block and sliders becomes two dividers flanking the new section. Replace the single `Divider().padding(.horizontal, 12)` that currently follows the main battery `VStack` with:

```swift
Divider().padding(.horizontal, 12)

if vm.batteryDetail != nil {
    batteryDetailSection
    Divider().padding(.horizontal, 12)
}
```

- [ ] **Step 3: Add `batteryDetailSection` computed view**

Add a private computed property to `MenuBarView` (after the existing `stateLabel` property):

```swift
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
                detailRow("Voltage",      "\(detail.voltageMillivolts) mV")
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
```

- [ ] **Step 4: Build the app target to confirm it compiles**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Build daemon target**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Run all tests**

```bash
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED"
```

Expected: both suites PASSED.

- [ ] **Step 7: Commit**

```bash
git add BatteryCare/BatteryCare/Views/MenuBarView.swift
git commit -m "feat: add expandable battery detail panel to MenuBarView"
```
