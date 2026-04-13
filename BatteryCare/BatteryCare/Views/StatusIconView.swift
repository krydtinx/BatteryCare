import SwiftUI
import BatteryCareShared

struct StatusIconView: View {
    let chargingState: ChargingState
    let isConnected: Bool

    var body: some View {
        Group {
            if !isConnected {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
            } else {
                switch chargingState {
                case .charging:
                    Image(systemName: "battery.100.bolt")
                        .symbolRenderingMode(.hierarchical)
                case .limitReached:
                    batteryWithOverlay("powerplug.fill")
                case .idle:
                    Image(systemName: "battery.100")
                        .symbolRenderingMode(.hierarchical)
                case .disabled:
                    batteryWithOverlay("pause.fill")
                }
            }
        }
    }

    @ViewBuilder
    private func batteryWithOverlay(_ overlayName: String) -> some View {
        ZStack {
            Image(systemName: "battery.0")
                .symbolRenderingMode(.hierarchical)
            Image(systemName: overlayName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 7, weight: .bold))
                .offset(x: -1, y: 0)
        }
    }
}
