import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: BatteryViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            updateIntervalRow
            Divider().padding(.horizontal, 12)
            sleepCheckRow
            Divider().padding(.horizontal, 12)
            accentColorRow
            Spacer()
        }
        .frame(width: 280)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.accentColor.color)
            }
            .buttonStyle(.plain)
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Update interval

    private var updateIntervalRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Update interval")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(.vertical, 8)
    }

    // MARK: Sleep check interval

    private var sleepCheckRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep check interval")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { vm.sleepWakeInterval },
                set: { vm.setSleepWakeInterval($0) }
            )) {
                Text("1m").tag(1)
                Text("3m").tag(3)
                Text("5m").tag(5)
                Text("10m").tag(10)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Accent color

    private var accentColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent color")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(AccentColor.allCases, id: \.self) { accent in
                    Button(action: { vm.setAccentColor(accent) }) {
                        ZStack {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 22, height: 22)
                            if vm.accentColor == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
