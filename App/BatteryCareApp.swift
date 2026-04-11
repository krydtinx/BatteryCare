import SwiftUI

// MARK: - Stubs — MenuBarView replaced in Task 16

struct MenuBarView: View {
    let vm: BatteryViewModel
    var body: some View { Text("BatteryCare") }
}

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
