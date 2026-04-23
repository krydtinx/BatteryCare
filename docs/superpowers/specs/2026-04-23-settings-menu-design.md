# Design Spec: Settings Menu

**Date:** 2026-04-23
**Status:** Approved (reviewed by Opus, patched)

---

## Problem

The main popover is accumulating controls (poll interval picker, future settings) that clutter the primary view. Three settings belong in a dedicated panel:
- Update interval (polling) — already in main view but should move
- Sleep check interval — configured in daemon but not yet exposed to the user
- Accent color — not yet implemented

---

## Solution

A settings panel accessed via a gear icon in the main popover's footer. Clicking the gear swaps the popover content to `SettingsView` using a `@State var showSettings: Bool` flag in `MenuBarView`. A back button in `SettingsView` returns to the main view.

**Why not `NavigationStack`:** `NavigationStack` inside `NSPopover` on macOS has known height-management issues — the popover may not resize when pushing a new view, causing clipping or whitespace. A simple boolean state swap with a `.transition(.move(edge: .trailing))` animation gives the same visual feel without the layout complexity.

---

## UI Structure

### Main popover change
- Add `@State private var showSettings: Bool = false` to `MenuBarView`
- Wrap body in `Group { if showSettings { SettingsView(...) } else { /* existing content */ } }` with `.animation(.easeInOut, value: showSettings)`
- Remove the poll interval `Picker` block from the main view (moves to settings)
- Add a gear button in the footer row that sets `showSettings = true`

### SettingsView
Three rows, each with a label and segmented control or swatches, plus a header with back button:

```
‹  Settings
─────────────────────
Update interval
[1s] [3s] [5s] [10s]
─────────────────────
Sleep check interval
[1m] [3m] [5m] [10m]
─────────────────────
Accent color
⬤ ⬤ ⬤ ⬤ ⬤ ⬤
```

`SettingsView` receives `vm: BatteryViewModel` as `@ObservedObject` and a `onDismiss: () -> Void` closure that sets `showSettings = false` in `MenuBarView`.

---

## Settings Details

### Update interval
Segmented picker: `1 / 3 / 5 / 10` seconds. Default: 5s.
Already fully wired through daemon. Moves from `MenuBarView` to `SettingsView` — UI only, no logic change.

### Sleep check interval
Segmented picker: `1 / 3 / 5 / 10` minutes. Default: 3 min.
How often the daemon wakes the Mac during sleep to check charging state.

Daemon side is already fully wired (`Command.setSleepWakeInterval`, `StatusUpdate.sleepWakeInterval`, `DaemonSettings.sleepWakeInterval`). Changes needed:
- Clamp updated from `5–30` → `1–30` in `DaemonCore.swift` (one line)
- Default updated from `5` → `3` in `DaemonSettings.swift` (init default + migration fallback `?? 5` → `?? 3`)
- Default updated from `5` → `3` in `StatusUpdate.swift` (init default + decoder fallback `?? 5` → `?? 3`)
- The empty sentinel in `DaemonCore.swift` (`sleepWakeInterval: 5` on the `.disconnected`-state StatusUpdate) updated to `3`
- `Command.swift` comment updated from "clamped 5–30" to "clamped 1–30"

**Migration note:** The `?? 3` fallback in `DaemonSettings.init(from:)` fires only for settings.json files that predate the `sleepWakeInterval` key entirely (old installs). Changing from `?? 5` to `?? 3` means those legacy users get a 3-min interval on first upgrade rather than 5-min. This is intentional — 3 min is the new desired default.

App side (`BatteryViewModel`) does not yet expose `sleepWakeInterval`:
- Add `@Published public private(set) var sleepWakeInterval: Int = 3`
- Add `self.sleepWakeInterval = update.sleepWakeInterval` inside `apply(_ update:)`
- Add `public func setSleepWakeInterval(_ value: Int) { Task { await client.send(.setSleepWakeInterval(minutes: value)) } }`

**Out-of-range picker value:** If the daemon returns a `sleepWakeInterval` not in `[1, 3, 5, 10]` (e.g., from a manual settings.json edit), no segment will be highlighted. This is acceptable — the picker shows the last known valid selection until the user picks a new one. No special handling required.

### Accent color
Six preset swatches. Default: Blue (#0A84FF).
Pure app-side — no daemon involvement.

```swift
enum AccentColor: String, CaseIterable {
    case blue   = "blue"
    case green  = "green"
    case orange = "orange"
    case purple = "purple"
    case red    = "red"
    case pink   = "pink"

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

`AccentColor` lives in its own file: `BatteryCare/BatteryCare/Models/AccentColor.swift`.

Stored in `UserDefaults` under key `"com.batterycare.accentColor"` (raw string value).
Loaded in `BatteryViewModel.init` with fallback to `.blue`:
```swift
self.accentColor = UserDefaults.standard.string(forKey: "com.batterycare.accentColor")
    .flatMap(AccentColor.init(rawValue:)) ?? .blue
```
Published as `@Published var accentColor: AccentColor = .blue`.

`MenuBarView` builds a `RangeSliderConfig` by mutating the default and passing it in:
```swift
var sliderConfig = RangeSliderConfig.default
sliderConfig.fillColor = vm.accentColor.color
sliderConfig.lowerHandleColor = vm.accentColor.color

RangeSliderView(lower: ..., upper: ..., config: sliderConfig)
```
All `RangeSliderConfig` fields are `var`, so mutation before passing is valid. No change to `RangeSliderView.swift`.

---

## Data Flow

### Sleep check interval
```
SettingsView segmented picker
  → vm.setSleepWakeInterval(_ minutes: Int)
  → client.send(.setSleepWakeInterval(minutes: minutes))
  → Daemon: clamps 1–30, saves to settings.json, reschedules next wake
  → StatusUpdate.sleepWakeInterval echoed back on next poll
  → vm.sleepWakeInterval updates → picker reflects current value
```

### Accent color
```
SettingsView swatch tap
  → vm.setAccentColor(_ color: AccentColor)
  → UserDefaults.standard.set(color.rawValue, forKey: "com.batterycare.accentColor")
  → vm.accentColor updates (immediate, @Published)
  → MenuBarView re-renders RangeSliderView with updated RangeSliderConfig
```

### Update interval (unchanged logic)
```
SettingsView segmented picker
  → vm.setPollingInterval(_ seconds: Int)
  → client.send(.setPollingInterval(seconds: seconds))
  → Daemon: clamps 1–30, saves, responds via StatusUpdate
  → vm.pollingInterval updates → picker reflects current value
```

---

## Files Changed

| File | Change |
|---|---|
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Add `showSettings` state; swap content via bool; remove poll interval picker; add gear button in footer; build `RangeSliderConfig` from `vm.accentColor` |
| `BatteryCare/BatteryCare/Views/SettingsView.swift` | **New** — header with back button, 3 settings rows (poll interval, sleep check interval, accent swatches) |
| `BatteryCare/BatteryCare/Models/AccentColor.swift` | **New** — `AccentColor` enum with 6 cases and `color: Color` computed property |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Add `sleepWakeInterval` published property + `setSleepWakeInterval()`; wire `apply()`; add `accentColor` + `setAccentColor()` with UserDefaults |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Change sleep wake interval clamp from `max(5, min(30, m))` to `max(1, min(30, m))`; update empty sentinel from `sleepWakeInterval: 5` to `sleepWakeInterval: 3` |
| `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift` | Change `sleepWakeInterval` default from `5` to `3`; change migration fallback from `?? 5` to `?? 3` |
| `Shared/Sources/BatteryCareShared/StatusUpdate.swift` | Change `sleepWakeInterval` default in `init` and decoder from `5` to `3` |
| `Shared/Sources/BatteryCareShared/Command.swift` | Update comment from "clamped 5–30" to "clamped 1–30" |

No changes to: `DaemonClient.swift`, `AppDelegate.swift`, `RangeSliderView.swift`.

---

## What Is NOT in Scope

- Light/dark appearance mode override
- Custom color picker (free color selection)
- Accent color applied to Enable/Pause buttons
- Any other settings rows beyond the three listed
- Persisting accent color to daemon or settings.json
