import SwiftUI
import BatteryCareShared

struct StatusIconView: View {
    let chargingState: ChargingState
    let isConnected: Bool

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
    }

    private var iconName: String {
        guard isConnected else { return "exclamationmark.triangle" }
        switch chargingState {
        case .charging:     return "bolt.fill"
        case .limitReached: return "lock.fill"
        case .idle:         return "battery.100"
        case .disabled:     return "battery.slash"
        }
    }
}
