# Design Spec: Dual-Handle Range Slider (RangeSliderView)

**Date:** 2026-04-22  
**Status:** Approved (reviewed by Opus, patched)  
**Replaces:** Separate "Charge limit" + "Sailing lower" sliders in `MenuBarView`

---

## Problem

The existing two-slider layout has a visual jump bug: when the upper (charge limit) slider decreases, its track range shrinks dynamically (`20...limit`), causing the lower (sailing lower) thumb to snap position in an unexpected way. Additionally, two separate sliders do not communicate to the user that the two values are related.

---

## Solution

Replace both sliders with a single `RangeSliderView` — a custom SwiftUI component with two handles on one track.

- **Upper handle** (white pill, extends above track): charge limit
- **Lower handle** (blue pill, extends below track): sailing lower
- Track always spans the full `20...100` range — no dynamic resizing
- Hit zones are split by view placement: upper handle view lives entirely above the track centerline, lower handle view entirely below — SwiftUI hit-testing routes events to the correct handle without any manual y-coordinate detection

---

## Component API

```swift
RangeSliderView(
    lower: Binding<Int>,                      // sailing lower (range.lowerBound...upper)
    upper: Binding<Int>,                      // charge limit (lower...range.upperBound)
    range: ClosedRange<Int> = 20...100,       // precondition: range.count >= 2
    lowerLabel: String = "Lower",             // label text shown below lower handle
    upperLabel: String = "Limit",             // label text shown below upper handle
    onEditingChanged: ((Bool) -> Void)? = nil, // called with true on drag start, false on drag end
    config: RangeSliderConfig = .default
)
```

**`range` precondition:** `range.count >= 2`. A degenerate range (e.g. `50...50`) causes division by zero in coordinate conversion. The component asserts this in debug builds and clamps gracefully in release.

### RangeSliderConfig

Struct that holds all visual customisation. Callers can use `.default` or override individual fields.

```swift
struct RangeSliderConfig {
    var trackColor: Color           // inactive track background
    var fillColor: Color            // active zone (lower → upper)
    var upperHandleColor: Color     // upper/limit handle fill
    var lowerHandleColor: Color     // lower handle fill
    var handleWidth: CGFloat        // pill width (default 13)
    var handleHeight: CGFloat       // pill height (default 20)
    var handleCornerRadius: CGFloat // pill corner radius (default 6); top corners for upper, bottom for lower
    var trackHeight: CGFloat        // track thickness (default 4)

    static let `default` = RangeSliderConfig(
        trackColor: Color.white.opacity(0.10),
        fillColor: Color(red: 0.04, green: 0.52, blue: 1.0),        // #0A84FF
        upperHandleColor: .white,
        lowerHandleColor: Color(red: 0.04, green: 0.52, blue: 1.0),
        handleWidth: 13,
        handleHeight: 20,
        handleCornerRadius: 6,
        trackHeight: 4
    )
}
```

---

## Visual Layout

```
           upper handle (white pill, above track)
                    │
  ──────────────────┼──────────────
  ░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░
  ──────────────────┼──────────────
       lower handle │ (blue pill, below track)
  
  20%            lower          upper         100%
```

- Track is always `range` wide (20...100); never resizes
- Fill covers `lower...upper`
- Value labels row below the component: `{lowerLabel} XX%` pinned to lower handle x-position, `{upperLabel} XX%` pinned to upper handle x-position

---

## Hit Zone Split

View placement enforces the split:

- Upper handle view frame is entirely **above** the track centerline
- Lower handle view frame is entirely **below** the track centerline
- Each handle applies an explicit `.contentShape(Rectangle())` sized to its frame to guarantee SwiftUI hit-test coverage with no bleed across the centerline

When both handles share the same x-position (`lower == upper`), the two pills stack vertically — upper pill entirely above, lower pill entirely below — with zero frame overlap. Both remain independently draggable.

---

## Drag Behaviour

| User action | Effect | Constraint |
|---|---|---|
| Drag upper right | limit increases | limit ≤ range.upperBound |
| Drag upper left | limit decreases; lower auto-clamps | lower ≤ limit |
| Drag lower right | sailing lower increases | lower ≤ limit (stops at limit) |
| Drag lower left | sailing lower decreases | lower ≥ range.lowerBound |

**Clamping is the component's responsibility.** `RangeSliderView` clamps computed values before writing to the `Binding`. This makes the component self-contained and correct regardless of what the caller wires up. Binding setters in `MenuBarView` do not need to re-clamp.

**Redundant send suppression:** The component only writes to the `Binding` when the computed `Int` value changes. Since coordinate conversion produces integers, most sub-pixel pointer moves produce no write — no debounce needed.

---

## Data Flow

```
DragGesture.onChanged (upper or lower handle)
  → compute new Int value from drag offset + GeometryReader trackWidth
  → clamp to valid range (component responsibility)
  → write to Binding<Int> only if value changed
  → MenuBarView binding setter calls vm.setLimit / vm.setSailingLower
  → ViewModel sends Command over IPC
  → Daemon responds with StatusUpdate
  → vm.limit / vm.sailingLower update
  → RangeSliderView re-renders from Binding

DragGesture.onChanged (first event) → onEditingChanged?(true)
DragGesture.onEnded              → onEditingChanged?(false)
```

---

## Implementation Notes

- Pure SwiftUI — `GeometryReader` + `DragGesture`. No UIKit/AppKit.
- Two separate `DragGesture`s, one per handle view. Each uses `minimumDistance: 0` so a tap on the handle also registers.
- **Coordinate conversion** (use `round`, not truncation):
  ```swift
  let fraction = dragX / trackWidth  // 0.0...1.0, clamped
  let value = range.lowerBound + Int(round(fraction * Double(range.count - 1)))
  ```
  `Int(round(...))` gives correct nearest-integer snapping. `Int(...)` alone truncates and would require dragging past the midpoint between two steps.
- **Hit zone guarantee:** each handle view uses `.contentShape(Rectangle())` matching its exact frame. The upper handle frame top = track center − handleHeight, bottom = track center. The lower handle frame top = track center, bottom = track center + handleHeight. Zero frame overlap at any value.
- No `.highPriorityGesture` needed — handle views are spatially non-overlapping, so SwiftUI routes gestures correctly without priority hints.
- **Accessibility:** each handle exposes `.accessibilityLabel(lowerLabel / upperLabel)`, `.accessibilityValue("\(value)%")`, and `.accessibilityAdjustableAction` to increment/decrement by 1. This is not deferred.
- File: `BatteryCare/BatteryCare/Views/RangeSliderView.swift` (new file)
- `MenuBarView` removes the two `VStack`+`Slider` blocks and the `isEditingSailingLower` state variable (replaced by `onEditingChanged` callback), and inserts a single `RangeSliderView` call

---

## What Changes

| File | Change |
|---|---|
| `BatteryCare/BatteryCare/Views/RangeSliderView.swift` | **New file** — the component |
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | Replace two sliders + remove `isEditingSailingLower`; add `RangeSliderView` |

No changes to `BatteryViewModel`, `DaemonClient`, daemon, or `Shared/`.

---

## Out of Scope

- Haptic feedback
- Tick marks along the track
- Animation on auto-clamp (lower snapping when upper decreases)
