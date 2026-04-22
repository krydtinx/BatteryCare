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
/// Clamps `value` to `range` before computing the offset, so out-of-range inputs
/// are silently constrained rather than producing coordinates outside the slider bounds.
/// Returns 0 for degenerate `range.count < 2`.
func rangeSliderX(for value: Int, trackWidth: CGFloat, range: ClosedRange<Int>) -> CGFloat {
    guard range.count >= 2 else { return 0 }
    let clamped = max(range.lowerBound, min(range.upperBound, value))
    let fraction = Double(clamped - range.lowerBound) / Double(range.count - 1)
    return trackWidth * CGFloat(fraction)
}
