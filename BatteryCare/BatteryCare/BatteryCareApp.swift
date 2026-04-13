import SwiftUI

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
