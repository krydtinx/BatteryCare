# Battery Detail Panel Design

**Date:** 2026-04-22
**Status:** Approved

## Goal

Surface hardware-accurate battery statistics (raw BMS percentage, cycle count, health, capacity, temperature, voltage) in the menu bar popover via an expandable inline panel.

## Architecture

Battery detail data flows through the existing data pipeline as a side-car: `BatteryMonitor.read()` → `BatteryReading.detail` → `StatusUpdate.detail` → `BatteryViewModel.batteryDetail` → `MenuBarView` expandable section. The charging state machine ignores the detail entirely — it only reads `percentage`, `isCharging`, and `isPluggedIn` from `BatteryReading`.

## Data Model

### `BatteryDetail` (new — `Shared/Sources/BatteryCareShared/BatteryDetail.swift`)

```swift
public struct BatteryDetail: Codable, Sendable {
    public let rawPercentage: Int        // CurrentCapacity/MaxCapacity*100 from AppleSmartBattery
    public let cycleCount: Int           // CycleCount
    public let healthPercent: Int        // MaxCapacity/DesignCapacity*100
    public let maxCapacityMAh: Int       // MaxCapacity (mAh)
    public let designCapacityMAh: Int    // DesignCapacity (mAh)
    public let temperatureCelsius: Double // (Temperature_raw / 100.0) - 273.15
    public let voltageMillivolts: Int    // Voltage (mV)
}
```

All fields are non-optional. If any IORegistry key is missing or `MaxCapacity`/`DesignCapacity` are zero, `ioregRead()` returns `nil` for the whole detail struct.

### `BatteryReading` (modified — `BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift`)

Add field:
```swift
public let detail: BatteryDetail?
```

### `StatusUpdate` (modified — `Shared/Sources/BatteryCareShared/StatusUpdate.swift`)

Add field:
```swift
public let detail: BatteryDetail?
```

- Add `detail` to `CodingKeys`
- Decode with `decodeIfPresent` (missing key → nil) for backward-compatibility with older daemon
- Encode with `encodeIfPresent`
- Add `detail: BatteryDetail? = nil` to `init`

## Daemon — `BatteryMonitor`

### `ioregRead()` (replaces `ioregIsCharging()`)

Opens `AppleSmartBattery` once per call, reads all keys in a single pass, returns `(isCharging: Bool, detail: BatteryDetail?)`.

```swift
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

    let current = (prop("CurrentCapacity") as? NSNumber)?.intValue
    let maxCap  = (prop("MaxCapacity")     as? NSNumber)?.intValue
    let design  = (prop("DesignCapacity")  as? NSNumber)?.intValue
    let cycles  = (prop("CycleCount")      as? NSNumber)?.intValue
    let tempRaw = (prop("Temperature")     as? NSNumber)?.intValue   // 0.01 Kelvin
    let voltage = (prop("Voltage")         as? NSNumber)?.intValue

    guard let c = current, let m = maxCap, let d = design,
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
        temperatureCelsius: (Double(t) / 100.0) - 273.15,
        voltageMillivolts:  v
    )
    return (isCharging, detail)
}
```

### `read()` update

Replace `ioregIsCharging()` call with `ioregRead()`, pass `detail` through to `BatteryReading`:

```swift
let (isCharging, detail) = ioregRead()
return BatteryReading(
    percentage: min(max(percentage, 0), 100),
    isCharging: isPluggedIn && isCharging,
    isPluggedIn: isPluggedIn,
    detail: detail
)
```

## App — `BatteryViewModel`

Add published property:
```swift
@Published public private(set) var batteryDetail: BatteryDetail? = nil
```

In `apply(_ update: StatusUpdate)`:
```swift
batteryDetail = update.detail
```

## App — `MenuBarView`

Add state:
```swift
@State private var showBatteryDetail: Bool = false
```

Add an expandable section between the battery % header and the charge limit slider. The section is hidden when `vm.batteryDetail == nil`.

### Layout

```
┌──────────────────────────────────────┐
│           57%                        │
│        Charging                      │
│ ─────────────────────────────────── │
│  Battery Details  ›                  │  ← tappable, chevron rotates on expand
│  ─────────────────────────────────  │  ← revealed on expand
│  Raw %          56%                  │
│  Cycle count    312                  │
│  Health         91%                  │
│  Max capacity   4,821 mAh            │
│  Design cap.    5,279 mAh            │
│  Temperature    28.4 °C              │
│  Voltage        12,455 mV            │
│ ─────────────────────────────────── │
│  Charge limit   80%                  │
│  ...                                 │
└──────────────────────────────────────┘
```

### SwiftUI structure

```swift
if vm.batteryDetail != nil {
    Divider().padding(.horizontal, 12)
    batteryDetailSection
    Divider().padding(.horizontal, 12)
}
```

`batteryDetailSection` is a private computed view containing:
- A tappable header row `HStack` with label "Battery Details" + `Image(systemName: "chevron.right")` that rotates 90° with `.rotationEffect(.degrees(showBatteryDetail ? 90 : 0)).animation(.easeInOut(duration: 0.2), value: showBatteryDetail)`
- A conditional `VStack` block (when `showBatteryDetail && detail != nil`) with one `HStack` row per field
- Tap via `.onTapGesture { showBatteryDetail.toggle() }` on the header row

Each stat row:
```swift
HStack {
    Text(label).font(.caption).foregroundStyle(.secondary)
    Spacer()
    Text(value).font(.caption).monospacedDigit()
}
```

Temperature formatted to one decimal place (e.g., `"28.4 °C"`). All other values formatted as integers with thousands separator where appropriate.

## IORegistry Keys Reference

| Key | Unit | Notes |
|-----|------|-------|
| `IsCharging` | Bool | Live charging state |
| `CurrentCapacity` | mAh | Present charge level |
| `MaxCapacity` | mAh | Current max (degrades with age) |
| `DesignCapacity` | mAh | Factory original max |
| `CycleCount` | count | Lifetime full charge cycles |
| `Temperature` | 0.01 K | `(value / 100.0) - 273.15` = °C |
| `Voltage` | mV | Present battery voltage |

## Error Handling

| Failure | Behavior |
|---------|---------|
| `IOServiceGetMatchingService` returns `IO_OBJECT_NULL` | `ioregRead()` returns `(false, nil)`. No detail shown in UI. |
| Any IORegistry key missing | `ioregRead()` returns `(isCharging, nil)`. No detail shown in UI. |
| `MaxCapacity` or `DesignCapacity` is zero | Guard prevents divide-by-zero; returns `(isCharging, nil)`. |
| `StatusUpdate` decoded without `detail` key | `decodeIfPresent` → `nil`. Backward-compatible. |

## Files Changed

| File | Change |
|------|--------|
| `Shared/Sources/BatteryCareShared/BatteryDetail.swift` | New file: `BatteryDetail` struct |
| `BatteryCare/battery-care-daemon/Core/BatteryMonitor.swift` | Replace `ioregIsCharging()` with `ioregRead()`; add `detail` to `BatteryReading` |
| `Shared/Sources/BatteryCareShared/StatusUpdate.swift` | Add `detail: BatteryDetail?` field |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Add `batteryDetail` published property |
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Add expandable battery detail section |

## Out of Scope

- Per-cell capacity readings
- Historical trend graphs
- Export / copy to clipboard
- Notifications based on health thresholds
