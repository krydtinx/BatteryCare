import SwiftUI
import BatteryCareShared

struct MenuBarView: View {
    @ObservedObject var vm: BatteryViewModel
    @State private var showOptimizedWarning: Bool = false
    @State private var showBatteryDetail: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(vm: vm, onDismiss: {
                    showSettings = false
                    showBatteryDetail = false
                })
                    .transition(.move(edge: .trailing))
            } else {
                mainContent
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .onReceive(vm.$isOptimizedChargingEnabled) { enabled in
            if enabled { showOptimizedWarning = true }
        }
    }

    // MARK: Main content

    private var mainContent: some View {
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
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 12)

            // Range slider with accent color
            rangeSlider

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

            if vm.batteryDetail != nil {
                Divider().padding(.horizontal, 12)
                batteryDetailSection
            }

            Divider().padding(.horizontal, 12)

            // Footer: connection status + gear + quit
            HStack {
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(vm.isConnected ? "Connected" : "Disconnected")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption2).buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: Range slider

    private var rangeSlider: some View {
        var config = RangeSliderConfig.default
        config.fillColor = vm.accentColor.color
        config.lowerHandleColor = vm.accentColor.color
        return RangeSliderView(
            lower: Binding(
                get: { vm.sailingLower },
                set: { vm.setSailingLower($0) }
            ),
            upper: Binding(
                get: { vm.limit },
                set: { vm.setLimit($0) }
            ),
            config: config
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Battery detail

    private var batteryDetailSection: some View {
        VStack(spacing: 0) {
            Button(action: { showBatteryDetail.toggle() }) {
                HStack {
                    Text("Battery Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showBatteryDetail ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: showBatteryDetail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showBatteryDetail, let detail = vm.batteryDetail {
                VStack(spacing: 3) {
                    detailRow("Raw %",        "\(detail.rawPercentage)%")
                    detailRow("Cycle count",  "\(detail.cycleCount)")
                    detailRow("Health",       "\(detail.healthPercent)%")
                    detailRow("Max capacity", "\(detail.maxCapacityMAh.formatted()) mAh")
                    detailRow("Design cap.",  "\(detail.designCapacityMAh.formatted()) mAh")
                    detailRow("Temperature",  String(format: "%.1f °C", detail.temperatureCelsius))
                    detailRow("Voltage",      String(format: "%.2f V", Double(detail.voltageMillivolts) / 1000))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
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
