import SwiftUI

@main
struct BatteryCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = BatteryViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vm: viewModel)
        } label: {
            StatusIconView(chargingState: viewModel.chargingState, isConnected: viewModel.isConnected)
        }
        .menuBarExtraStyle(.window)
    }
}
