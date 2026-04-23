import SwiftUI

public enum AccentColor: String, CaseIterable, Equatable {
    case blue   = "blue"
    case green  = "green"
    case orange = "orange"
    case purple = "purple"
    case red    = "red"
    case pink   = "pink"

    public static let `default`: AccentColor = .blue

    public var color: Color {
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
