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

// MARK: - View

struct RangeSliderView: View {
    @Binding var lower: Int
    @Binding var upper: Int
    var range: ClosedRange<Int>
    var lowerLabel: String
    var upperLabel: String
    var onEditingChanged: ((Bool) -> Void)?
    var config: RangeSliderConfig

    @State private var isUpperEditing = false
    @State private var dragStartUpper: Int = 0

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

    // Total height: upper handle space + track + lower handle space
    private var totalTrackHeight: CGFloat {
        config.handleHeight * 2 + config.trackHeight
    }

    private let labelRowHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            VStack(spacing: 4) {
                trackLayer(trackWidth: trackWidth)
                labelsRow
            }
        }
        .frame(height: totalTrackHeight + 4 + labelRowHeight)
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

            upperHandleView(trackWidth: trackWidth, upperX: upperX)
        }
        .frame(width: trackWidth, height: totalTrackHeight)
    }

    // MARK: Upper handle

    private func upperHandleView(trackWidth: CGFloat, upperX: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: config.handleCornerRadius)
            .fill(config.upperHandleColor)
            .frame(width: config.handleWidth, height: config.handleHeight)
            .contentShape(Rectangle())
            .position(x: upperX, y: config.handleHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isUpperEditing {
                            dragStartUpper = upper
                            isUpperEditing = true
                            onEditingChanged?(true)
                        }
                        let startX = rangeSliderX(for: dragStartUpper, trackWidth: trackWidth, range: range)
                        let trackX = startX + value.translation.width
                        let newValue = rangeSliderValue(for: trackX, trackWidth: trackWidth, range: range)
                        let clamped = max(range.lowerBound, min(range.upperBound, newValue))
                        if clamped != upper { upper = clamped }
                        if lower > upper { lower = upper }
                    }
                    .onEnded { _ in
                        isUpperEditing = false
                        onEditingChanged?(false)
                    }
            )
            .accessibilityLabel(upperLabel)
            .accessibilityValue("\(upper)%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: upper = min(range.upperBound, upper + 1)
                case .decrement:
                    upper = max(range.lowerBound, upper - 1)
                    if lower > upper { lower = upper }
                @unknown default: break
                }
            }
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
