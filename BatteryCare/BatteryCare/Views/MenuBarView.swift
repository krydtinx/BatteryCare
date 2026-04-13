import SwiftUI
import BatteryCareShared

struct MenuBarView: View {
    @ObservedObject var vm: BatteryViewModel
    @State private var showOptimizedWarning: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Optimized Charging conflict banner
            if showOptimizedWarning {
                OptimizedChargingBanner(isVisible: $showOptimizedWarning)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            // Battery percentage + state
            VStack(spacing: 4) {
                Text("\(vm.percentage)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 12)

            // Charge limit slider
            VStack(spacing: 4) {
                HStack {
                    Text("Charge limit").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(vm.limit)%").font(.caption).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(vm.limit) },
                    set: { vm.setLimit(Int($0)) }
                ), in: 20...100, step: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Poll interval picker
            VStack(spacing: 4) {
                HStack {
                    Text("Update interval").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Picker("", selection: Binding(
                    get: { vm.pollingInterval },
                    set: { vm.setPollingInterval($0) }
                )) {
                    Text("1s").tag(1)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Charging control buttons
            HStack(spacing: 8) {
                Button(action: { vm.enableCharging() }) {
                    Label("Enable", systemImage: "bolt")
                }
                .disabled(vm.chargingState != .disabled)
                Button(action: { vm.disableCharging() }) {
                    Label("Pause", systemImage: "pause.circle")
                }
                .disabled(vm.chargingState == .disabled)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Error banner
            if let errorMsg = vm.errorMessage {
                Divider().padding(.horizontal, 12)
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMsg).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider().padding(.horizontal, 12)

            // Connection status dot + quit
            HStack {
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(vm.isConnected ? "Connected" : "Disconnected")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption2).buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
        .onReceive(vm.$isOptimizedChargingEnabled) { enabled in
            if enabled { showOptimizedWarning = true }
        }
    }

    private var stateLabel: String {
        guard vm.isConnected else { return "Daemon not running" }
        switch vm.chargingState {
        case .charging:     return "Charging"
        case .limitReached: return "Limit reached — paused"
        case .idle:         return "Not plugged in"
        case .disabled:     return "Charging paused by user"
        }
    }
}
