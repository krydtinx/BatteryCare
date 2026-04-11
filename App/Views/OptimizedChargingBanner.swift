import SwiftUI

struct OptimizedChargingBanner: View {
    @Binding var isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Optimized Battery Charging is ON").font(.caption).bold()
                Spacer()
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("Disable it to allow BatteryCare to control your charge limit.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Open Battery Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!)
                isVisible = false
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }
}
