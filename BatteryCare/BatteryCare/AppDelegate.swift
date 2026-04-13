import AppKit
import SwiftUI
import Combine
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "install")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = BatteryViewModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // hide from Dock
        setupStatusItem()

        // Ensure settings.json exists (install.sh seeds it, but guard against manual installs).
        let settingsPath = "/Library/Application Support/BatteryCare/settings.json"
        if !FileManager.default.fileExists(atPath: settingsPath) {
            do {
                try seedInitialSettings()
            } catch {
                logger.error("Failed to seed settings.json: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        let pop = NSPopover()
        pop.contentSize = CGSize(width: 280, height: 420)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MenuBarView(vm: viewModel))
        popover = pop

        updateIcon(state: viewModel.chargingState, connected: viewModel.isConnected)

        viewModel.$chargingState
            .combineLatest(viewModel.$isConnected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, connected in
                self?.updateIcon(state: state, connected: connected)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(state: ChargingState, connected: Bool) {
        let name: String
        if !connected {
            name = "exclamationmark.triangle"
        } else {
            switch state {
            case .charging:     name = "bolt.fill"
            case .limitReached: name = "lock.fill"
            case .idle:         name = "battery.100"
            case .disabled:     name = "battery.slash"
            }
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Private

    private func seedInitialSettings() throws {
        let settingsURL = URL(filePath: "/Library/Application Support/BatteryCare/settings.json")
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Inline minimal settings struct — mirrors DaemonSettings without importing the Daemon module
        struct MinimalSettings: Encodable {
            let limit: Int = 80
            let pollingInterval: Int = 5
            let isChargingDisabled: Bool = false
            let allowedUID: uid_t
        }
        let settings = MinimalSettings(allowedUID: getuid())
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        logger.info("Seeded settings.json with allowedUID=\(getuid())")
    }
}
