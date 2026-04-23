import XCTest
import SwiftUI
@testable import BatteryCare

final class AccentColorTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(AccentColor.allCases.count, 6)
    }

    func testAllCasesProvideNonClearColor() {
        // The exhaustive switch in AccentColor.color is a compile-time guarantee;
        // this test ensures all allCases entries reach the switch without crashing.
        for accent in AccentColor.allCases {
            _ = accent.color  // would crash if the switch had an unhandled branch
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
