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

    func applicationWillTerminate(_ notification: Notification) {
        // Re-enable charging so quitting the app restores normal behavior.
        // setLimit(100) is preferred over enableCharging: it also persists the 100% limit
        // to settings.json, so the daemon won't re-apply the old limit if restarted later.
        MainActor.assumeIsolated {
            UserDefaults.standard.set(viewModel.limit, forKey: "com.batterycare.savedLimit")
            UserDefaults.standard.set(viewModel.sailingLower, forKey: "com.batterycare.savedSailingLower")
            DaemonClient.shared.sendNow(.setLimit(percentage: 100))
        }
    }

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
        let image: NSImage?
        if !connected {
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        } else {
            switch state {
            case .charging:
                image = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: nil)
            case .limitReached:
                image = compositeIcon(base: "battery.0", overlay: "powerplug.fill")
            case .idle:
                image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)
            case .disabled:
                image = compositeIcon(base: "battery.0", overlay: "pause.fill")
            }
        }
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func compositeIcon(base: String, overlay: String) -> NSImage? {
        let size = CGSize(width: 22, height: 13)

        guard let baseImage = NSImage(systemSymbolName: base, accessibilityDescription: nil),
              let overlayImage = NSImage(systemSymbolName: overlay, accessibilityDescription: nil) else {
            return nil
        }

        let result = NSImage(size: size)
        result.lockFocus()

        // Draw base battery symbol scaled to fill the canvas
        baseImage.draw(in: CGRect(origin: .zero, size: size))

        // Draw overlay at ~40% of canvas width, centred horizontally and vertically
        let overlaySize = CGSize(width: size.width * 0.40, height: size.height * 0.70)
        let overlayOrigin = CGPoint(
            x: (size.width - overlaySize.width) / 2 - 1,
            y: (size.height - overlaySize.height) / 2
        )
        overlayImage.draw(in: CGRect(origin: overlayOrigin, size: overlaySize))

        result.unlockFocus()
        result.isTemplate = true
        return result
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
