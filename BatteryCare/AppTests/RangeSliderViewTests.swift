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

    func test_x_forValueBelowRange_clampsToZero() {
        XCTAssertEqual(rangeSliderX(for: 10, trackWidth: 200, range: 20...100), 0, accuracy: 0.001)
    }

    func test_x_forValueAboveRange_clampsToTrackWidth() {
        XCTAssertEqual(rangeSliderX(for: 110, trackWidth: 200, range: 20...100), 200, accuracy: 0.001)
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
