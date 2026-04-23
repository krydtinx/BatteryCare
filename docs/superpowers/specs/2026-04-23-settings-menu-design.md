# Design Spec: Settings Menu

**Date:** 2026-04-23
**Status:** Approved

---

## Problem

The main popover is accumulating controls (poll interval picker, future settings) that clutter the primary view. Three settings belong in a dedicated panel:
- Update interval (polling) — already in main view but should move
- Sleep check interval — configured in daemon but not yet exposed to the user
- Accent color — not yet implemented

---

## Solution

A settings sheet accessed via a gear icon in the main popover's footer. Clicking the gear pushes a `SettingsView` onto a `NavigationStack` wrapping the popover content — same 280px window, back button returns to main.

---

## UI Structure

### Main popover change
- Wrap the existing `VStack` body in a `NavigationStack`
- Remove the poll interval `Picker` block (moves to settings)
- Add a gear `NavigationLink` button in the footer row, left of the Quit button

### SettingsView
Three rows, each with a label and segmented control or swatches:

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

---

## Settings Details

### Update interval
Segmented picker: `1 / 3 / 5 / 10` seconds. Default: 5s.
Already fully wired through daemon. Moves from `MenuBarView` to `SettingsView` — UI only, no logic change.

### Sleep check interval
Segmented picker: `1 / 3 / 5 / 10` minutes. Default: 3 min.
How often the daemon wakes the Mac during sleep to check charging state.

Daemon side is already fully wired (`Command.setSleepWakeInterval`, `StatusUpdate.sleepWakeInterval`, `DaemonSettings.sleepWakeInterval`). Only two changes needed there:
- Clamp updated from `5–30` → `1–30` in `DaemonCore.swift`
- Default updated from `5` → `3` in `DaemonSettings.swift` and `StatusUpdate.swift`

App side (`BatteryViewModel`) does not yet expose `sleepWakeInterval` — needs `@Published` property, `apply()` update, and `setSleepWakeInterval()` action.

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

Stored in `UserDefaults` under key `"com.batterycare.accentColor"` (raw string value).
Loaded in `BatteryViewModel.init`, published as `@Published var accentColor: AccentColor`.
`MenuBarView` passes it into `RangeSliderView` via `RangeSliderConfig(fillColor: vm.accentColor.color, lowerHandleColor: vm.accentColor.color)`.

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
  → vm.accentColor updates (immediate)
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
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Wrap in `NavigationStack`; remove poll interval picker; add gear `NavigationLink` in footer; pass `RangeSliderConfig` with `vm.accentColor` |
| `BatteryCare/BatteryCare/Views/SettingsView.swift` | **New** — 3 settings rows (poll interval, sleep check interval, accent swatches) |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Add `sleepWakeInterval` published property + `setSleepWakeInterval()`; add `accentColor` + `setAccentColor()` with UserDefaults persistence |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Change sleep wake interval clamp from `max(5, min(30, m))` to `max(1, min(30, m))` |
| `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift` | Change `sleepWakeInterval` default init value from `5` to `3`; change migration fallback from `?? 5` to `?? 3` |
| `Shared/Sources/BatteryCareShared/StatusUpdate.swift` | Change `sleepWakeInterval` default in `init` and `init(from:)` from `5` to `3` |

No changes to: `Command.swift`, `DaemonClient.swift`, `AppDelegate.swift`, `RangeSliderView.swift` (config passed in from `MenuBarView`).

---

## What Is NOT in Scope

- Light/dark appearance mode override
- Custom color picker (free color selection)
- Any other settings rows beyond the three listed
- Persisting accent color to daemon or settings.json
