# Range Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two separate "Charge limit" and "Sailing lower" sliders in `MenuBarView` with a single `RangeSliderView` that has split-direction pill handles, eliminating the visual jump bug and overlapping-handle problem.

**Architecture:** A pure SwiftUI `RangeSliderView` uses `GeometryReader` + `DragGesture` with two handle views physically positioned above/below the track centerline — upper handle extends upward (white), lower handle extends downward (blue). Hit zones never overlap even when both values are equal. Track always spans the full `20...100` range; no dynamic resizing.

**Tech Stack:** SwiftUI, XCTest (`@testable import BatteryCare`)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `BatteryCare/BatteryCare/Views/RangeSliderView.swift` | **Create** | `RangeSliderConfig`, coordinate helpers, `RangeSliderView` |
| `BatteryCare/AppTests/RangeSliderViewTests.swift` | **Create** | Unit tests for pure coordinate functions |
| `BatteryCare/BatteryCare/Views/MenuBarView.swift` | **Modify** | Swap two sliders for `RangeSliderView`, remove `isEditingSailingLower` |

---

## Task 1: Config struct + pure coordinate helpers

**Files:**
- Create: `BatteryCare/BatteryCare/Views/RangeSliderView.swift`
- Create: `BatteryCare/AppTests/RangeSliderViewTests.swift`

- [ ] **Step 1.1 — Write failing tests for `rangeSliderValue(for:trackWidth:range:)`**

Create `BatteryCare/AppTests/RangeSliderViewTests.swift`:

```swift
import XCTest
@testable import BatteryCare

final class RangeSliderViewTests: XCTestCase {

    // MARK: rangeSliderValue

    func test_value_atLeftEdge_returnsRangeLowerBound() {
        XCTAssertEqual(rangeSliderValue(for: 0, trackWidth: 200, range: 20...100), 20)
    }

    func test_value_atRightEdge_returnsRangeUpperBound() {
        XCTAssertEqual(rangeSliderValue(for: 200, trackWidth: 200, range: 20...100), 100)
    }

    func test_value_atMidpoint_returnsMiddleValue() {
        // 20...100 has 81 values; midpoint fraction 0.5 → round(0.5 * 80) = 40 → 20+40=60
        XCTAssertEqual(rangeSliderValue(for: 100, trackWidth: 200, range: 20...100), 60)
    }

    func test_value_roundsToNearestInteger() {
        // step size = 200/80 = 2.5pt per step. 79% fraction should round to nearest step.
        // fraction for value=80 is (80-20)/80 = 0.75 → x = 150. At x=149 (fraction=0.745):
        // round(0.745 * 80) = round(59.6) = 60 → 80. At x=151: round(60.4)=60 → 80.
        XCTAssertEqual(rangeSliderValue(for: 149, trackWidth: 200, range: 20...100), 80)
        XCTAssertEqual(rangeSliderValue(for: 151, trackWidth: 200, range: 20...100), 80)
    }

    func test_value_clampsBelowZero() {
        XCTAssertEqual(rangeSliderValue(for: -50, trackWidth: 200, range: 20...100), 20)
    }

    func test_value_clampsAboveTrackWidth() {
        XCTAssertEqual(rangeSliderValue(for: 300, trackWidth: 200, range: 20...100), 100)
    }

    func test_value_degenerateTrackWidth_returnsLowerBound() {
        XCTAssertEqual(rangeSliderValue(for: 100, trackWidth: 0, range: 20...100), 20)
    }

    // MARK: rangeSliderX

    func test_x_forLowerBound_returnsZero() {
        XCTAssertEqual(rangeSliderX(for: 20, trackWidth: 200, range: 20...100), 0, accuracy: 0.001)
    }

    func test_x_forUpperBound_returnsTrackWidth() {
        XCTAssertEqual(rangeSliderX(for: 100, trackWidth: 200, range: 20...100), 200, accuracy: 0.001)
    }

    func test_x_forMidValue_returnsMidpoint() {
        // value=60, fraction=(60-20)/80=0.5, x=100
        XCTAssertEqual(rangeSliderX(for: 60, trackWidth: 200, range: 20...100), 100, accuracy: 0.001)
    }

    // MARK: Round-trip

    func test_roundTrip_valueToXToValue() {
        let trackWidth: CGFloat = 232 // realistic popover width minus padding
        let range = 20...100
        for v in stride(from: 20, through: 100, by: 5) {
            let x = rangeSliderX(for: v, trackWidth: trackWidth, range: range)
            let recovered = rangeSliderValue(for: x, trackWidth: trackWidth, range: range)
            XCTAssertEqual(recovered, v, "Round-trip failed for value \(v)")
        }
    }
}
```

- [ ] **Step 1.2 — Run tests to verify they fail**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "error:|FAILED|RangeSlider" | head -20
```

Expected: compilation error — `rangeSliderValue` and `rangeSliderX` not found.

- [ ] **Step 1.3 — Create `RangeSliderView.swift` with config + helpers**

Create `BatteryCare/BatteryCare/Views/RangeSliderView.swift`:

```swift
import SwiftUI

// MARK: - Config

struct RangeSliderConfig {
    var trackColor: Color
    var fillColor: Color
    var upperHandleColor: Color
    var lowerHandleColor: Color
    var handleWidth: CGFloat
    var handleHeight: CGFloat
    var handleCornerRadius: CGFloat
    var trackHeight: CGFloat

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

// MARK: - Coordinate helpers (pure, tested)

/// Convert a track-space x position to the nearest integer value within range.
/// Uses round() for correct nearest-integer snapping (not truncation).
/// Returns range.lowerBound for degenerate trackWidth (0 or negative).
func rangeSliderValue(for x: CGFloat, trackWidth: CGFloat, range: ClosedRange<Int>) -> Int {
    guard range.count >= 2, trackWidth > 0 else { return range.lowerBound }
    let fraction = max(0, min(1, x / trackWidth))
    return range.lowerBound + Int(round(fraction * Double(range.count - 1)))
}

/// Convert an integer value to a track-space x offset.
func rangeSliderX(for value: Int, trackWidth: CGFloat, range: ClosedRange<Int>) -> CGFloat {
    guard range.count >= 2 else { return 0 }
    let fraction = Double(value - range.lowerBound) / Double(range.count - 1)
    return trackWidth * CGFloat(fraction)
}
```

- [ ] **Step 1.4 — Run tests to verify they pass**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED|RangeSlider" | head -20
```

Expected: `RangeSliderViewTests` — all tests PASSED.

- [ ] **Step 1.5 — Commit**

```bash
git add BatteryCare/BatteryCare/Views/RangeSliderView.swift BatteryCare/AppTests/RangeSliderViewTests.swift
git commit -m "feat: add RangeSliderConfig and coordinate helpers with tests"
```

---

## Task 2: Track and fill rendering

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/RangeSliderView.swift` — add `RangeSliderView` struct with track + fill, no handles yet

- [ ] **Step 2.1 — Append `RangeSliderView` shell to `RangeSliderView.swift`**

Add below the coordinate helpers:

```swift
// MARK: - View

struct RangeSliderView: View {
    @Binding var lower: Int
    @Binding var upper: Int
    var range: ClosedRange<Int>
    var lowerLabel: String
    var upperLabel: String
    var onEditingChanged: ((Bool) -> Void)?
    var config: RangeSliderConfig

    @State private var isEditing = false

    init(
        lower: Binding<Int>,
        upper: Binding<Int>,
        range: ClosedRange<Int> = 20...100,
        lowerLabel: String = "Lower",
        upperLabel: String = "Limit",
        onEditingChanged: ((Bool) -> Void)? = nil,
        config: RangeSliderConfig = .default
    ) {
        assert(range.count >= 2, "RangeSliderView: range must have count >= 2")
        _lower = lower
        _upper = upper
        self.range = range
        self.lowerLabel = lowerLabel
        self.upperLabel = upperLabel
        self.onEditingChanged = onEditingChanged
        self.config = config
    }

    // Total height: upper handle above track + track + lower handle below track + labels
    private var totalTrackHeight: CGFloat {
        config.handleHeight * 2 + config.trackHeight
    }

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            VStack(spacing: 4) {
                trackLayer(trackWidth: trackWidth)
                labelsRow
            }
        }
        .frame(height: totalTrackHeight + 4 + 16) // track + spacing + labels
    }

    // MARK: Track layer

    private func trackLayer(trackWidth: CGFloat) -> some View {
        let lowerX = rangeSliderX(for: lower, trackWidth: trackWidth, range: range)
        let upperX = rangeSliderX(for: upper, trackWidth: trackWidth, range: range)
        let fillWidth = max(0, upperX - lowerX)

        return ZStack(alignment: .topLeading) {
            // Background track — sits at y = handleHeight (below upper handle space)
            RoundedRectangle(cornerRadius: config.trackHeight / 2)
                .fill(config.trackColor)
                .frame(width: trackWidth, height: config.trackHeight)
                .offset(y: config.handleHeight)

            // Fill between lower and upper
            RoundedRectangle(cornerRadius: config.trackHeight / 2)
                .fill(config.fillColor)
                .frame(width: fillWidth, height: config.trackHeight)
                .offset(x: lowerX, y: config.handleHeight)
        }
        .frame(width: trackWidth, height: totalTrackHeight)
    }

    // MARK: Labels

    private var labelsRow: some View {
        HStack {
            Text("\(lowerLabel) \(lower)%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(upperLabel) \(upper)%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2.2 — Build to verify no compilation errors**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 2.3 — Commit**

```bash
git add BatteryCare/BatteryCare/Views/RangeSliderView.swift
git commit -m "feat: add RangeSliderView with track and fill rendering"
```

---

## Task 3: Upper handle — view + drag gesture

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/RangeSliderView.swift` — add upper handle view + drag, accessibility

The upper handle is a rounded-top pill extending **above** the track. Its frame occupies `y: 0` to `y: handleHeight` in the ZStack — entirely above the track center. `.contentShape(Rectangle())` ensures hit-test covers the full frame.

- [ ] **Step 3.1 — Add `upperHandleView` and wire into `trackLayer`**

In `RangeSliderView`, add the helper and update `trackLayer`:

```swift
// Add inside RangeSliderView struct:

private func upperHandleView(trackWidth: CGFloat, upperX: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: config.handleCornerRadius)
        .fill(config.upperHandleColor)
        .frame(width: config.handleWidth, height: config.handleHeight)
        // Position: centered on upperX, sits above track (y: 0)
        .offset(x: upperX - config.handleWidth / 2, y: 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Convert drag location to track-space x, then to value.
                    // value.location.x is relative to this view's origin (upper-left of handle).
                    let handleOriginX = upperX - config.handleWidth / 2
                    let trackX = handleOriginX + value.location.x
                    let newValue = rangeSliderValue(for: trackX, trackWidth: trackWidth, range: range)
                    // upper clamped to full range; lower auto-clamps if it would exceed new upper
                    let clampedUpper = max(range.lowerBound, min(range.upperBound, newValue))
                    if !isEditing { isEditing = true; onEditingChanged?(true) }
                    if clampedUpper != upper { upper = clampedUpper }
                    if lower > upper { lower = upper }
                }
                .onEnded { _ in
                    isEditing = false
                    onEditingChanged?(false)
                }
        )
        .accessibilityLabel(upperLabel)
        .accessibilityValue("\(upper)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: upper = min(range.upperBound, upper + 1)
            case .decrement:
                let newUpper = max(range.lowerBound, upper - 1)
                upper = newUpper
                if lower > upper { lower = upper }
            @unknown default: break
            }
        }
}
```

Update `trackLayer` — add the upper handle inside the ZStack after the fill:

```swift
// Inside trackLayer ZStack, after the fill RoundedRectangle:
upperHandleView(trackWidth: trackWidth, upperX: upperX)
```

- [ ] **Step 3.2 — Build to verify**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3.3 — Commit**

```bash
git add BatteryCare/BatteryCare/Views/RangeSliderView.swift
git commit -m "feat: add upper handle with drag gesture and accessibility"
```

---

## Task 4: Lower handle — view + drag gesture + clamping

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/RangeSliderView.swift` — add lower handle view + drag

The lower handle extends **below** the track. Its frame occupies `y: handleHeight + trackHeight` to `y: handleHeight * 2 + trackHeight` — entirely below the track center. No frame overlap with the upper handle at any value.

- [ ] **Step 4.1 — Add `lowerHandleView` and wire into `trackLayer`**

Add inside `RangeSliderView`:

```swift
private func lowerHandleView(trackWidth: CGFloat, lowerX: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: config.handleCornerRadius)
        .fill(config.lowerHandleColor)
        .frame(width: config.handleWidth, height: config.handleHeight)
        // Position: centered on lowerX, sits below track
        .offset(x: lowerX - config.handleWidth / 2, y: config.handleHeight + config.trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let handleOriginX = lowerX - config.handleWidth / 2
                    let trackX = handleOriginX + value.location.x
                    let newValue = rangeSliderValue(for: trackX, trackWidth: trackWidth, range: range)
                    // lower clamped between range.lowerBound and current upper
                    let clampedLower = max(range.lowerBound, min(upper, newValue))
                    if !isEditing { isEditing = true; onEditingChanged?(true) }
                    if clampedLower != lower { lower = clampedLower }
                }
                .onEnded { _ in
                    isEditing = false
                    onEditingChanged?(false)
                }
        )
        .accessibilityLabel(lowerLabel)
        .accessibilityValue("\(lower)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: lower = min(upper, lower + 1)
            case .decrement: lower = max(range.lowerBound, lower - 1)
            @unknown default: break
            }
        }
}
```

Update `trackLayer` — add lower handle inside the ZStack after the upper handle:

```swift
// Inside trackLayer ZStack, after upperHandleView:
lowerHandleView(trackWidth: trackWidth, lowerX: lowerX)
```

- [ ] **Step 4.2 — Build to verify**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4.3 — Run all tests**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED" | head -10
```

Expected: All tests PASSED.

- [ ] **Step 4.4 — Commit**

```bash
git add BatteryCare/BatteryCare/Views/RangeSliderView.swift
git commit -m "feat: add lower handle with drag gesture, clamping, and accessibility"
```

---

## Task 5: Wire into MenuBarView

**Files:**
- Modify: `BatteryCare/BatteryCare/Views/MenuBarView.swift`
  - Remove `@State private var isEditingSailingLower: Bool = false` (line 7)
  - Replace charge limit VStack (lines 34–44) + sailing lower VStack (lines 49–64) with `RangeSliderView`

- [ ] **Step 5.1 — Remove `isEditingSailingLower` state**

In `MenuBarView.swift`, delete this line:

```swift
@State private var isEditingSailingLower: Bool = false
```

- [ ] **Step 5.2 — Replace the two slider blocks with `RangeSliderView`**

Remove this entire block (both slider VStacks with their padding):

```swift
// Charge limit slider
VStack(spacing: 4) {
    HStack {
        Text("Charge limit").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(vm.limit)%").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
    }
    Slider(value: Binding(
        get: { Double(vm.limit) },
        set: { vm.setLimit(Int($0)) }
    ), in: 20...100, step: 1)
}
.padding(.horizontal, 12)
.padding(.top, 8)

// Sailing lower slider
VStack(spacing: 4) {
    HStack {
        Text("Sailing lower").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(vm.sailingLower)%").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
    }
    let maxRange = Double(max(21, vm.limit))  // Ensure range width >= 1 to avoid SwiftUI crash
    Slider(value: Binding(
        get: { Double(min(vm.sailingLower, max(20, vm.limit))) },
        set: { vm.setSailingLower(min(Int($0), vm.limit)) }
    ), in: 20...maxRange, step: 1, onEditingChanged: { isEditing in
        isEditingSailingLower = isEditing
    })
}
.padding(.horizontal, 12)
.padding(.bottom, 8)
```

Replace with:

```swift
RangeSliderView(
    lower: Binding(
        get: { vm.sailingLower },
        set: { vm.setSailingLower($0) }
    ),
    upper: Binding(
        get: { vm.limit },
        set: { vm.setLimit($0) }
    )
)
.padding(.horizontal, 12)
.padding(.vertical, 8)
```

- [ ] **Step 5.3 — Build both targets**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5.4 — Run all tests**

```bash
cd /Users/kridtin/workspace/battery-care
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test 2>&1 | grep -E "Test Suite|PASSED|FAILED" | head -10
```

Expected: All tests PASSED.

- [ ] **Step 5.5 — Commit**

```bash
git add BatteryCare/BatteryCare/Views/MenuBarView.swift
git commit -m "feat: replace dual sliders with RangeSliderView in MenuBarView"
```

---

## Self-Review Checklist

- [x] **Fixed-range track (20...100)** — `trackLayer` uses fixed `trackWidth` from GeometryReader; range never resizes → jump bug fixed
- [x] **Overlap handling** — upper frame `y: 0...handleHeight`, lower frame `y: handleHeight+trackHeight...handleHeight*2+trackHeight` → zero overlap at any value
- [x] **`Int(round(...))` snapping** — `rangeSliderValue` uses `round()`, tested
- [x] **`.contentShape(Rectangle())`** — applied to both handles
- [x] **Clamping is component's responsibility** — upper clamps `lower` if it exceeds new upper; lower clamps to `upper`
- [x] **`onEditingChanged`** — fires `true` on first `onChanged`, `false` on `onEnded`; `isEditingSailingLower` removal noted
- [x] **Accessibility** — `accessibilityLabel`, `accessibilityValue`, `accessibilityAdjustableAction` on both handles
- [x] **`RangeSliderConfig`** — includes `handleCornerRadius`, `lowerLabel`/`upperLabel` in API
- [x] **Redundant send suppression** — bindings only written when value changes (`if clampedUpper != upper`)
- [x] **Range precondition** — `assert(range.count >= 2)` + guard in helpers
- [x] **No `.highPriorityGesture`** — not needed; frame separation handles routing
