import SwiftUI

// MARK: - Stubs (replaced in Tasks 15 & 16)

class BatteryViewModel: ObservableObject {}

struct MenuBarView: View {
    let vm: BatteryViewModel
    var body: some View { Text("BatteryCare") }
}

// MARK: - App entry point

@main
struct BatteryCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = BatteryViewModel()

    var body: some Scene {
        MenuBarExtra("BatteryCare", systemImage: "battery.100") {
            MenuBarView(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
