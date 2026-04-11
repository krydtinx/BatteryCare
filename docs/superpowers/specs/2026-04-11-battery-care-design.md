# Battery Care — Design Spec
**Date:** 2026-04-11 (revised after Opus code review round 2)
**Target:** MacBook Pro M4, macOS Tahoe 26.4.1
**Scope:** Phase 1 MVP (architecture designed for all 4 phases without refactoring)
**Language:** Swift / SwiftUI + C (SMC bridge)

---

## Context

Build a personal macOS menu bar app that limits battery charge to any percentage (20–100%) on Apple Silicon M4. Native macOS only supports 80–100% limiting. Custom SMC control via `CH0B` / `CH0C` keys is required. The architecture is designed to support all 4 phases without refactoring — Phase 1 delivers the working core.

---

## Architecture Overview

Two independent binaries communicating over a Unix Domain Socket:

```
┌─────────────────────────────────────────────────────┐
│  BatteryCare.app  (user space, login item)           │
│                                                      │
│  MenuBarView ←→ BatteryViewModel (@MainActor)        │
│                      ↕  Combine @Published           │
│              DaemonClient (sends Commands)           │
└──────────────────────┬──────────────────────────────┘
                       │ Unix Domain Socket
                       │ /var/run/battery-care/daemon.sock
                       │ Newline-delimited JSON
┌──────────────────────▼──────────────────────────────┐
│  battery-care-daemon  (root, launchd)                │
│                                                      │
│  SocketServer → actor DaemonCore                     │
│                    └─ ChargingStateMachine           │
│                    └─ BatteryMonitor (async loop)    │
│                    └─ SleepWatcher (IOKit bridge)    │
└──────────────────────┬──────────────────────────────┘
                       │ IOKit / AppleSMC
┌──────────────────────▼──────────────────────────────┐
│  SMCService  (Swift wrapper over smc.c / smc.h)      │
│  CH0B + CH0C = 0x00 → enable charging               │
│  CH0B + CH0C = 0x02 → disable charging              │
└─────────────────────────────────────────────────────┘
```

**Invariants:**
- The daemon is the **only** process that writes SMC keys. The app never touches hardware directly.
- All daemon state lives inside `actor DaemonCore` — no shared mutable state outside the actor boundary.
- The daemon pushes `StatusUpdate` every N seconds (configurable, default 3s). The app never polls.
- On unplug, charging is re-enabled (fail-safe: never trap battery in a discharged state).
- SMC writes only happen on **state transitions**, never on stable repeated polls.
- Quitting the app does **not** stop the daemon. The daemon persists independently via launchd.

---

## Design Patterns

| Layer | Pattern | Reason |
|---|---|---|
| Daemon core | Swift Actor | Thread-safe by construction — critical when Phase 2–3 add concurrent concerns (sleep/wake, heat, discharge) |
| Charging logic | State Machine | Explicit transitions prevent invalid states and double SMC writes |
| IPC protocol | Command Pattern | Typed, Codable commands — type-safe, debuggable, extensible |
| App layer | MVVM + Combine | Natural SwiftUI pattern; `@Published` properties drive reactive UI |
| Battery/SMC | Protocol-injected services | Single-responsibility wrappers with clear throw boundaries; injectable for unit testing |

---

## Project Structure

```
BatteryCare/
├── BatteryCare.xcworkspace
├── BatteryCare.xcodeproj
│
├── App/                              # Target: BatteryCare.app
│   ├── AppDelegate.swift             # NSStatusItem, daemon registration, first-run checks
│   ├── Views/
│   │   ├── MenuBarView.swift         # Popover root
│   │   ├── StatusIconView.swift      # Menu bar icon (4 states)
│   │   └── OptimizedChargingBanner.swift  # First-run warning
│   ├── ViewModels/
│   │   └── BatteryViewModel.swift    # @MainActor ObservableObject
│   └── Services/
│       └── DaemonClient.swift        # Socket client, AsyncStream<StatusUpdate>
│
├── Daemon/                           # Target: battery-care-daemon (CLI tool, root)
│   ├── main.swift                    # Entry point, dependency wiring
                                      # (crash-loop protection lives in launchd ThrottleInterval)
│   ├── Core/
│   │   ├── DaemonCore.swift          # actor DaemonCore (injected deps)
│   │   ├── ChargingStateMachine.swift
│   │   └── BatteryMonitor.swift      # AppleSmartBattery IORegistry reader
│   ├── Hardware/
│   │   ├── SMCService.swift          # Swift wrapper (read + write)
│   │   ├── ThirdParty/
│   │   │   ├── smc.c                 # from charlie0129/gosmc (GPL-2.0)
│   │   │   ├── smc.h
│   │   │   └── NOTICE               # GPL-2.0 attribution notice
│   │   └── SMCBridgingHeader.h       # #include "ThirdParty/smc.h"
│   ├── Sleep/
│   │   └── SleepWatcher.swift        # IOKit C callbacks → AsyncStream<SleepEvent>
│   └── IPC/
│       └── SocketServer.swift        # Listens, verifies client UID, decodes/encodes JSON
│
├── Shared/                           # Local Swift Package (BatteryCareShared)
│   └── Sources/BatteryCareShared/
│       ├── Command.swift
│       ├── StatusUpdate.swift
│       ├── ChargingState.swift
│       └── DaemonMode.swift          # Mode layered above ChargingState (Phase 1: .normal only)
│
└── Resources/
    └── Contents/Library/LaunchDaemons/
        └── com.batterycare.daemon.plist   # Bundled inside .app for SMAppService
```

---

## IPC Protocol (Command Pattern)

Wire format: newline-delimited JSON (`\n`-terminated) over Unix Domain Socket at
`/var/run/battery-care/daemon.sock`.

The socket directory is created by the daemon at startup with `0755 root:wheel`.
The socket file itself is `chmod 0600 root:wheel` after `bind()`.
The daemon verifies each connecting client's UID via `getsockopt(LOCAL_PEERCRED)` and rejects
any connection whose UID does not match `settings.allowedUID`. This field is seeded by the app
during the install flow (see "Daemon Install Flow" below) — the app writes the current user's
`getuid()` into `settings.json` **before** `SMAppService.register()` is called, so the daemon
sees the correct UID on its very first startup.

### Commands (App → Daemon)

```swift
// Shared/Sources/BatteryCareShared/Command.swift
enum Command: Codable {
    case getStatus
    case setLimit(percentage: Int)          // valid: 20–100
    case enableCharging
    case disableCharging
    case setPollingInterval(seconds: Int)   // valid: 1–30
}
// installDaemon / uninstallDaemon are app-side actions (SMAppService), NOT IPC commands.
// The daemon isn't running yet when install is triggered.
```

**Command semantics:**

- `.getStatus` — `DaemonCore.handle` sends an immediate `StatusUpdate` to **the requesting
  client only**, not as a broadcast. This lets a newly-reconnected client pull a fresh snapshot
  without spamming every other connected client. Important for the reconnect flow: the app's
  first action after reconnecting is to send `.getStatus`.
- `.setPollingInterval(seconds:)` — values outside the valid `1…30` range are **silently
  clamped** at the daemon using `settings.pollingInterval = max(1, min(30, seconds))`. The
  clamped value is reflected in the next `StatusUpdate` broadcast, which lets the UI
  self-correct without needing a dedicated error channel for out-of-range input.
- `.setLimit(percentage:)` — values outside `20…100` are similarly clamped; the clamped value
  propagates via `StatusUpdate`.

### Status Update (Daemon → App)

Pushed every N seconds unprompted, and immediately after any state change or command.

```swift
// Shared/Sources/BatteryCareShared/StatusUpdate.swift
struct StatusUpdate: Codable {
    let currentPercentage: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let chargingState: ChargingState
    let mode: DaemonMode                  // Phase 1: always .normal
    let limit: Int
    let pollingInterval: Int
    let error: DaemonError?
    let errorDetail: String?              // e.g. which SMC key failed — nil when error is nil
}

enum DaemonError: String, Codable {
    case smcConnectionFailed
    case smcKeyNotFound
    case smcWriteFailed
    case batteryReadFailed
}
```

### Shared Enums

```swift
// Shared/Sources/BatteryCareShared/ChargingState.swift
enum ChargingState: String, Codable {
    case charging        // below limit, actively charging
    case limitReached    // at/above limit, charging paused
    case idle            // unplugged
    case disabled        // user explicitly paused via .disableCharging command
}

// Shared/Sources/BatteryCareShared/DaemonMode.swift
// Layered above ChargingState — controls which logic is active in DaemonCore.
// Phase 1 uses .normal only. Phase 3 adds remaining cases without breaking IPC.
enum DaemonMode: String, Codable {
    case normal         // standard charge-limit loop (Phase 1)
    case discharging    // drain while plugged in (Phase 2)
    case topUp          // one-time charge to 100%, revert after unplug (Phase 3)
    case calibrating    // full cycle calibration (Phase 3)
}
```

---

## Daemon Core

### Protocols (injectable for unit testing)

```swift
// Daemon/Core/DaemonCore.swift
protocol SMCServiceProtocol {
    func open() throws
    func perform(_ write: SMCWrite) throws
    func read(key: String) throws -> Data   // needed for Phase 3 temp reads, Phase 4 wattage
    func close()
}

protocol BatteryMonitorProtocol {
    func read() throws -> BatteryReading
}

protocol SleepWatcherProtocol {
    var events: AsyncStream<SleepEvent> { get }
}
```

### Actor

```swift
actor DaemonCore {
    private var settings: DaemonSettings
    private var stateMachine: ChargingStateMachine
    private let smc: any SMCServiceProtocol
    private let monitor: any BatteryMonitorProtocol
    private let sleepWatcher: any SleepWatcherProtocol
    private var connectedClients: [ClientID: SocketStream] = [:]  // owned here for broadcast

    init(
        settings: DaemonSettings,
        smc: any SMCServiceProtocol,
        monitor: any BatteryMonitorProtocol,
        sleepWatcher: any SleepWatcherProtocol
    ) { ... }

    func run() async throws {
        try smc.open()
        stateMachine = ChargingStateMachine(initialState: deriveInitialState())
        // If either loop throws or exits, the other is cancelled; daemon exits and launchd restarts.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.runMonitorLoop() }
            group.addTask { await self.runSleepLoop() }
            // First completion (throw or normal exit) cancels the other child and propagates.
            try await group.next()
            group.cancelAll()
        }
    }

    // Called by SocketServer when a client connects / disconnects
    func addClient(_ id: ClientID, stream: SocketStream) { connectedClients[id] = stream }
    func removeClient(_ id: ClientID) { connectedClients.removeValue(forKey: id) }

    // Called by SocketServer when a Command arrives
    func handle(_ command: Command) async throws { ... }
}
```

**Initial state seeding on startup:**
`deriveInitialState()` first checks `settings.isChargingDisabled`. If `true`, it returns
`.disabled` unconditionally — the user explicitly paused charging in a previous session and that
decision must survive daemon restarts, reboots, and crashes. Otherwise it reads the current
battery before entering the loop: if plugged in and below the persisted limit it returns
`.charging`; if at/above limit it returns `.limitReached`; if unplugged it returns `.idle`. This
prevents a spurious `enableCharging` SMC write on boot when the hardware default already matches.

**`.disabled` persistence:** When `DaemonCore.handle(.disableCharging)` is received, it calls
`stateMachine.forceDisable()` **and** sets `settings.isChargingDisabled = true`, then persists
settings. When `.enableCharging` is received, it sets `settings.isChargingDisabled = false`,
persists, and re-runs `stateMachine.evaluate(...)` against the current battery reading to fall
back into the normal charging/limitReached/idle path.

**Monitor loop — internal tick is always 1 second:**
```swift
private func runMonitorLoop() async throws {
    var ticksSinceLastBroadcast = 0
    while true {
        try await Task.sleep(for: .seconds(1))
        ticksSinceLastBroadcast += 1
        guard ticksSinceLastBroadcast >= settings.pollingInterval else { continue }
        ticksSinceLastBroadcast = 0

        let battery: BatteryReading
        do {
            battery = try monitor.read()
        } catch {
            logger.warning("Battery read failed: \(error)")
            await broadcast(makeErrorUpdate(.batteryReadFailed))
            continue   // keep current charging state — fail-safe
        }

        let write = stateMachine.evaluate(
            percentage: battery.percentage,
            limit: settings.limit,
            isPluggedIn: battery.isPluggedIn
        )
        if let write {
            do {
                try smc.perform(write)
            } catch let e as SMCError {
                logger.error("SMC write failed: \(e)")
                // Pull the actual failing key out of the thrown error, not the SMCWrite enum —
                // the write targets both CH0B and CH0C; only the active key is authoritative.
                if case .writeFailed(let key) = e {
                    await broadcast(makeErrorUpdate(.smcWriteFailed, detail: key))
                } else {
                    await broadcast(makeErrorUpdate(.smcWriteFailed, detail: nil))
                }
            } catch {
                logger.error("SMC write failed: \(error)")
                await broadcast(makeErrorUpdate(.smcWriteFailed, detail: nil))
            }
        }
        await broadcast(makeStatusUpdate(battery))
    }
}
// Polling every 1 second internally means setPollingInterval changes take effect within 1 second.
```

### setLimit Persistence Flow

When the daemon receives `.setLimit(percentage: 80)`:
```
1. settings.limit = 80
2. persist settings → /Library/Application Support/BatteryCare/settings.json
3. stateMachine.evaluate(currentBattery, limit: 80, isPluggedIn: currentBattery.isPluggedIn)
4. if SMC write returned → smc.perform(write)
5. broadcast StatusUpdate with updated limit
```

### State Machine Transitions

| Current State | isPluggedIn | % >= limit | Next State | SMC Write |
|---|---|---|---|---|
| idle | true | any | charging | enableCharging |
| charging | true | true | limitReached | disableCharging |
| limitReached | true | false | charging | enableCharging |
| charging | false | any | idle | nil |
| limitReached | false | any | idle | enableCharging (restore on unplug) |
| disabled | any | any | disabled | nil |

**Entering `disabled` state** is not a table transition — it is driven by the `.disableCharging`
command. `DaemonCore.handle(.disableCharging)` calls `stateMachine.forceDisable()`, which
directly sets state to `.disabled` and returns `.disableCharging` as the required SMC write.
Exiting `disabled` requires an explicit `.enableCharging` command.

### Sleep / Wake Handling

**Critical contract:** `IORegisterForSystemPower` requires `IOAllowPowerChange` be called
synchronously inside the C callback for `kIOMessageSystemWillSleep`, or macOS force-sleeps after
~30 seconds regardless. The `SleepWatcher` C layer **must** call `IOAllowPowerChange` inside the
callback before signaling Swift. The async `AsyncStream<SleepEvent>` is populated after the ack.

```swift
// SleepWatcher.swift — the C callback calls IOAllowPowerChange first, then signals Swift
// by yielding into an AsyncStream continuation retrieved from a heap-allocated context struct
// passed as refcon. Swift side only sees the event after the ack is already sent to the kernel.

enum SleepEvent { case willSleep, didWake }

// Daemon/Sleep/SleepWatcher.swift
// Uses kIOMessageSystemWillSleep + kIOMessageSystemHasPoweredOn (not WillPowerOn —
// SMC keys may not be honored until HasPoweredOn).
```

### SleepWatcher Implementation Note (C ↔ Swift bridging)

`IORegisterForSystemPower` takes a `refcon: UnsafeMutableRawPointer?` that is passed back into
every callback invocation. We use this to bridge from the C callback into the Swift async world:

1. **Context struct (heap-allocated):**
   ```swift
   final class SleepWatcherContext {
       let continuation: AsyncStream<SleepEvent>.Continuation
       init(_ c: AsyncStream<SleepEvent>.Continuation) { self.continuation = c }
   }
   ```
2. **Init flow in `SleepWatcher`:**
   - Create the `AsyncStream<SleepEvent>` and capture its `Continuation`.
   - Allocate a `SleepWatcherContext` on the heap via `Unmanaged.passRetained(...)`.
   - Pass the raw pointer as `refcon` to `IORegisterForSystemPower`.
   - Store both the `Unmanaged` reference and the `IONotificationPortRef` on `self` so they
     outlive any single callback invocation.
3. **C callback body** (`@convention(c)` free function):
   1. If `messageType == kIOMessageSystemWillSleep`, call
      `IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))` **first**. Missing this
      call causes macOS to force-sleep after ~30 s regardless of what Swift does.
   2. Recover the context via `Unmanaged<SleepWatcherContext>.fromOpaque(refcon!).takeUnretainedValue()`.
   3. Call a small Swift bridging function that does `context.continuation.yield(.willSleep)`
      or `.didWake`. Yielding on an `AsyncStream.Continuation` is thread-safe, so it is safe to
      call directly from the IOKit callback thread.
4. **Lifetime requirement:** the `SleepWatcherContext` **must** remain alive as long as the
   power notification port is registered. `SleepWatcher` owns the `Unmanaged` retain and only
   releases it in `deinit` (after `IODeregisterForSystemPower` + `IONotificationPortDestroy`).
   Losing the context early results in a use-after-free in the callback.
5. **Stream termination:** `deinit` calls `continuation.finish()` so any `for await` consumer
   exits cleanly when `SleepWatcher` is torn down.

```swift
private func runSleepLoop() async {
    for await event in sleepWatcher.events {
        switch event {
        case .willSleep:
            // Disable charging before sleep regardless of state (prevents creep to 100%)
            // Do not update stateMachine — wake re-evaluates from current battery reading
            try? smc.perform(.disableCharging)

        case .didWake:
            // SMC keys are live on HasPoweredOn. Wait 2s for hardware to stabilise.
            try? await Task.sleep(for: .seconds(2))
            guard let battery = try? monitor.read() else { continue }
            let write = stateMachine.evaluate(
                percentage: battery.percentage,
                limit: settings.limit,
                isPluggedIn: battery.isPluggedIn
            )
            if let write { try? smc.perform(write) }
            await broadcast(makeStatusUpdate(battery))
        }
    }
}
```

---

## SMC Layer

### Key Probe Strategy

Some firmware revisions only honor `CH0B`, others only `CH0C`. On `open()`, probe both:

```swift
final class SMCService: SMCServiceProtocol {
    private var conn: SMCConnection = SMCConnection()
    private var activeChargingKey: String = "CH0B"  // updated after probe

    func open() throws {
        guard SMCOpen(&conn) == kIOReturnSuccess else { throw SMCError.connectionFailed }
        // Probe which key this firmware uses — write a benign read-back test
        activeChargingKey = probeChargingKey()  // tries CH0B, falls back to CH0C
        logger.info("SMC charging key: \(activeChargingKey)")
        // Log firmware version for diagnostics
        logger.info("Firmware: \(firmwareVersion())")
    }

    func perform(_ write: SMCWrite) throws {
        let value: UInt8 = write == .enableCharging ? 0x00 : 0x02
        // Both CH0B and CH0C are written unconditionally. Individual return codes are ignored
        // because only one key exists on any given firmware revision. The read-back below is
        // the authoritative check — if the active key accepted the write, the value will match.
        _ = SMCWriteSimple(&conn, "CH0B", value)
        _ = SMCWriteSimple(&conn, "CH0C", value)
        // Verify via read-back on the active key
        let result = try read(key: activeChargingKey)
        guard result.first == value else { throw SMCError.writeFailed(activeChargingKey) }
    }

    func read(key: String) throws -> Data {
        // Used by Phase 3 heat protection (TB0T/TB1T) and Phase 4 power flow
        var result = Data()
        guard SMCReadData(&conn, key, &result) == kIOReturnSuccess else {
            throw SMCError.readFailed(key)
        }
        return result
    }

    func close() { SMCClose(&conn) }
}

enum SMCWrite {
    case enableCharging
    case disableCharging
}

enum SMCError: Error {
    case connectionFailed
    case keyNotFound(String)
    case writeFailed(String)
    case readFailed(String)
}
```

**Note:** `smc.c` / `smc.h` are in `Daemon/Hardware/ThirdParty/` with a `NOTICE` file.
GPL-2.0 — personal use is fine. Do not distribute commercially. A `NOTICE` file documents
the upstream URL and license so a clean-room rewrite can replace this directory later if needed.

---

## Battery Monitor

Use `AppleSmartBattery` IORegistry (not `IOPSCopyPowerSourcesInfo`) as the authoritative source.
This provides atomic, accurate readings for percentage, charging state, plug state, cycle count,
and raw wattage — required for Phase 4 Hardware Battery % and Power Flow features.

```swift
struct BatteryReading {
    let percentage: Int         // 0–100. On AppleSmartBattery, CurrentCapacity is in mAh,
                                // NOT a percent. Compute as:
                                //     CurrentCapacity * 100 / MaxCapacity
                                // or read StateOfCharge directly from the IORegistry dict.
    let isCharging: Bool        // IsCharging
    let isPluggedIn: Bool       // ExternalConnected
    // Phase 4 fields (populated from day one, unused in Phase 1):
    let cycleCount: Int         // CycleCount
    let designCapacity: Int     // DesignCapacity (mAh)
    let maxCapacity: Int        // MaxCapacity (mAh)
    let voltage: Double         // Voltage (mV)
    let amperage: Double        // Amperage (mA, negative = discharging)
}

// BatteryMonitor reads via:
// IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
// + IORegistryEntryCreateCFProperties(...)
```

---

## Daemon Settings (Persisted)

```swift
// Stored at: /Library/Application Support/BatteryCare/settings.json
// Owner: root:wheel, mode: 0644 (daemon writes, app cannot write directly)
// Directory created during daemon first-launch if missing.
struct DaemonSettings: Codable {
    var limit: Int = 80
    var pollingInterval: Int = 3
    var isChargingDisabled: Bool = false     // persisted .disabled state across restarts
    var allowedUID: uid_t = 501              // UID the daemon accepts via LOCAL_PEERCRED;
                                             // written by the app during install (first-created
                                             // user is typically 501, but must be set explicitly).
    // Phase 2+: sailingLowerBound, heatThreshold, disableChargingOnSleep
    // Phase 3+: scheduledTasks: [ScheduledTask]
    // Phase 3+: heatProtectionEnabled: Bool  (cross-cutting, not a DaemonMode)
}
```

Settings are re-applied on daemon startup — Apple Silicon resets SMC keys on cold boot/reboot,
so the daemon must re-enforce the limit every time it starts.

---

## App Layer (MVVM)

### ViewModel

```swift
@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var currentPercentage: Int = 0
    @Published var isCharging: Bool = false
    @Published var chargingState: ChargingState = .idle
    @Published var mode: DaemonMode = .normal
    @Published var limit: Int = 80
    @Published var pollingInterval: Int = 3
    @Published var connectionState: ConnectionState = .disconnected
    @Published var error: DaemonError? = nil
    @Published var errorDetail: String? = nil
    @Published var showOptimizedChargingWarning: Bool = false

    enum ConnectionState {
        case connected
        case connecting
        case disconnected   // daemon installed but not reachable — show "Start" button
        case notInstalled   // show "Install" button
    }

    private let client: DaemonClient

    init(client: DaemonClient = .init()) {
        self.client = client
        checkOptimizedCharging()
        Task { await connect() }
    }

    private func connect() async {
        connectionState = .connecting
        do {
            for await update in client.statusStream() {
                apply(update)
                connectionState = .connected
            }
            // Stream ended (daemon disconnected) — start retry
            connectionState = .disconnected
            await retryWithBackoff()
        } catch {
            connectionState = .notInstalled
        }
    }

    // Exponential backoff: 1s → 2s → 4s → 8s → 30s cap
    private func retryWithBackoff() async { ... }

    func setLimit(_ value: Int) {
        limit = value  // optimistic update
        Task { try? await client.send(.setLimit(percentage: value)) }
    }

    func setPollingInterval(_ value: Int) {
        pollingInterval = value
        Task { try? await client.send(.setPollingInterval(seconds: value)) }
    }

    // Checks pmset output for "optimized" — shows banner if enabled
    private func checkOptimizedCharging() { ... }
}
```

### App Reconnect / Broken Socket Detection

- **App side:** `DaemonClient.statusStream()` returns an `AsyncStream<StatusUpdate>`. When the
  socket drops (EOF or error), the stream terminates, `connect()` catches the end, and
  `retryWithBackoff()` retries. No explicit ping needed.
- **Daemon side:** `SocketServer` wraps each client socket in a write-guarded task. On broken
  pipe / SIGPIPE, the write fails, the client task catches it, and calls
  `DaemonCore.removeClient(id)`. `SIGPIPE` is ignored at daemon startup (`signal(SIGPIPE, SIG_IGN)`).

### UI Components

- **MenuBarView** — battery gauge, limit slider (20–100), poll interval picker (1/3/5/10s),
  error banner (if `error != nil`), connection status row
- **StatusIconView** — **four** states:
  - Bolt icon: `.charging`
  - Lock icon: `.limitReached`
  - Battery-outline icon: `.idle` or `.disabled`
  - Warning/exclamation icon: `.disconnected` or `.notInstalled`
- **OptimizedChargingBanner** — shown once on first launch if macOS Optimized Battery Charging
  is detected. Links to `System Settings → Battery → Battery Health` with instructions to disable.

---

## Daemon Install Flow (SMAppService)

`AuthorizationCreate` / `AuthorizationExecuteWithPrivileges` are deprecated and unreliable on
Tahoe 26. The correct modern approach is `SMAppService` (ServiceManagement, macOS 13+).

**Bundle layout required by SMAppService:**
```
BatteryCare.app/
└── Contents/
    └── Library/
        └── LaunchDaemons/
            └── com.batterycare.daemon.plist   ← daemon plist lives here
```
The daemon binary path in the plist must point to a location inside the app bundle or a path
that the system will install to automatically.

**Install:**
```swift
// AppDelegate.swift
import ServiceManagement

func installDaemon() throws {
    // 1. Seed the allowed UID BEFORE registering the daemon. The app writes an initial
    //    settings.json containing the current user's UID into
    //    /Library/Application Support/BatteryCare/settings.json via an authorized
    //    install helper (the same elevation path SMAppService uses). The daemon reads
    //    this file on startup and uses settings.allowedUID for LOCAL_PEERCRED checks.
    try seedInitialSettings(allowedUID: getuid())

    // 2. Register with launchd via SMAppService.
    let service = SMAppService.daemon(plistName: "com.batterycare.daemon.plist")
    try service.register()   // system presents approval prompt; no custom password UI needed
}

func uninstallDaemon() throws {
    let service = SMAppService.daemon(plistName: "com.batterycare.daemon.plist")
    try service.unregister()
}
```

`SMAppService.register()` handles copying, plist installation, and loading. The user sees a
single system-level approval dialog. No manual `launchctl` calls needed.

**Status detection:**
```swift
let status = SMAppService.daemon(plistName: "com.batterycare.daemon.plist").status
// .notRegistered → show Install button (connectionState = .notInstalled)
// .enabled       → daemon should be running
// .requiresApproval → user needs to approve in System Settings
```

---

## LaunchDaemon Plist

Bundled at `Contents/Library/LaunchDaemons/com.batterycare.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.batterycare.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Library/Application Support/BatteryCare/battery-care-daemon</string>
    </array>

    <key>UserName</key>
    <string>root</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>/Library/Logs/BatteryCare/daemon.log</string>

    <key>StandardErrorPath</key>
    <string>/Library/Logs/BatteryCare/daemon-error.log</string>
</dict>
</plist>
```

`ThrottleInterval: 10` — if the daemon crashes, launchd waits 10 seconds before restarting,
preventing a tight crash loop from hammering the SMC.

---

## Error Handling

**Principle: fail-safe over fail-open.** When uncertain, leave charging enabled.

| Error | Daemon Behavior | App Behavior |
|---|---|---|
| SMC `connectionFailed` on open | Log + exit (launchd restarts after ThrottleInterval) | Show "Daemon error" banner |
| SMC `keyNotFound` | Log + exit | Show "SMC key not found — check firmware" |
| SMC `writeFailed` | Log + keep current state + broadcast error | Show error banner with detail |
| Battery read failed | Log + skip cycle, keep charging state unchanged | Show stale indicator |
| Socket not found / refused | — | connectionState = .notInstalled or .disconnected |
| Timeout (no StatusUpdate >3× pollingInterval) | — | Show stale indicator, start backoff retry |
| Malformed JSON | Log + discard | Keep last known state |
| Broken pipe (client disconnected) | Remove client from registry, continue | Reconnect with backoff |

---

## Logging

All daemon logging uses `os.Logger` with a consistent subsystem:

```swift
let logger = Logger(subsystem: "com.batterycare.daemon", category: "core")
```

Log output goes to `/Library/Logs/BatteryCare/daemon.log` (via plist `StandardOutPath`).
On startup the daemon logs:
- Firmware version (`system_profiler SPHardwareDataType | grep Firmware`)
- Active SMC charging key (`CH0B` or `CH0C`, from probe)
- Persisted settings (limit, pollingInterval)

---

## Known Risks and Gotchas

| Risk | Mitigation in Design |
|---|---|
| **macOS Optimized Charging conflict** | App detects via `pmset -g` on first launch, shows `OptimizedChargingBanner` linking to System Settings |
| **SMC key changes across firmware** | `open()` probes `CH0B`/`CH0C`, logs active key + firmware version |
| **Hibernate resets SMC** | Daemon re-applies limit on startup; default `hibernatemode 3` is fine (safe sleep) |
| **Cold-boot SMC reset** | `deriveInitialState()` reads hardware state before entering the loop |
| **Clamshell mode + discharge (Phase 2)** | Documented known limitation; disabling adapter in clamshell causes sleep — will be user-warned in Phase 2 UI |
| **GPL-2.0 `smc.c`** | Segregated in `ThirdParty/` with `NOTICE` file; personal use only; replaceable |
| **App Store incompatible** | SMC access uses private IOKit — direct distribution only, expected |

---

## Testing Strategy

### Unit Tests (no hardware)

- **`ChargingStateMachineTests`** — every transition in the table above + `forceDisable()` path; assert correct `SMCWrite?` output
- **`CommandCodableTests`** — round-trip encode/decode every `Command`, `StatusUpdate`, `DaemonMode`, `DaemonError` variant
- **`BatteryViewModelTests`** — inject mock `DaemonClient`, feed `StatusUpdate` values, assert `@Published` properties update correctly
- **`DaemonCoreTests`** — inject mock `SMCServiceProtocol` + `BatteryMonitorProtocol` + `SleepWatcherProtocol`; assert correct SMC calls on simulated state transitions
- **`SocketServerFramingTests`** — exercise the newline-delimited JSON framing against a
  loopback `AF_UNIX` socket: full-line reads, partial reads split mid-JSON, multiple commands
  arriving in one `recv()`, malformed lines, and client disconnect mid-write. Framing bugs are
  extremely hard to diagnose in production, so loopback coverage is mandatory.

### Pre-implementation Hardware Verification

```bash
# Verify CH0B/CH0C works on M4 FIRST, before writing any Swift.
# Must uninstall batt afterwards — it will race with the new daemon over CH0B.
brew install batt && sudo brew services start batt
sudo batt limit 80
sudo batt status          # confirm charging stopped at 80%
sudo brew services stop batt
sudo batt uninstall
brew uninstall batt
```

### Daemon Smoke Test (no UI)

```bash
sudo ./battery-care-daemon &
# In another terminal:
echo '{"getStatus":{}}' | nc -U /var/run/battery-care/daemon.sock
# Expected: StatusUpdate JSON line
```

---

## Build Order (MVP Phase 1)

1. Set up Xcode workspace: two targets (App, Daemon) + `BatteryCareShared` local Swift package
2. Add `ThirdParty/smc.c` + `smc.h` to Daemon target; write `SMCService.swift` (read + write + probe)
3. **Hardware gate:** verify `SMCService` in a throwaway CLI binary — confirm `CH0B`/`CH0C` write works on M4 before any further code
4. Implement `BatteryMonitor` using `AppleSmartBattery` IORegistry
5. Implement `ChargingStateMachine` + unit tests (full transition table)
6. Implement `SleepWatcher` C/Swift bridge (with IOAllowPowerChange ack inside C callback)
7. Implement `actor DaemonCore` with injected protocols + `SocketServer`
8. Write `com.batterycare.daemon.plist` + `SMAppService` install/uninstall flow in `AppDelegate`
9. Implement `DaemonClient` + `BatteryViewModel` (with reconnect + backoff)
10. Build `MenuBarView`, `StatusIconView` (4 states), `OptimizedChargingBanner`
11. End-to-end: app installs daemon → daemon controls SMC → app reflects live battery state

---

## Phase Extensibility Notes

These additions are not implemented in Phase 1 but the architecture is ready for them:

- **Phase 2 discharge:** Add `SMCWrite.disableAdapter` / `.enableAdapter` for `AC-W`/`CH0I` keys. `DaemonMode.discharging` activates this path. `ChargingState` gains a sibling `AdapterState` enum in `DaemonSettings` — avoids flattening a 2D state space into one enum.
- **Phase 3 heat protection:** `smc.read(key: "TB0T")` is already in `SMCServiceProtocol`. `DaemonSettings` gains `heatThreshold: Double` and `heatProtectionEnabled: Bool`. A `HeatMonitor` task runs alongside the monitor loop inside `DaemonCore`. **Heat protection is a cross-cutting concern, not a `DaemonMode`** — it can activate alongside any mode (`.normal`, `.discharging`, `.topUp`, `.calibrating`). `DaemonMode` intentionally stays single-value; heat protection is a separate boolean flag in `DaemonSettings` so it composes with whatever mode is currently active.
- **Phase 3 calibration:** `DaemonMode.calibrating` runs a multi-phase `Task` inside `DaemonCore`. Phase states are internal to the calibration task — `StatusUpdate` reports mode only.
- **Phase 4 hardware battery %:** `BatteryReading` already contains `designCapacity`, `maxCapacity`, `voltage`, `amperage` from `AppleSmartBattery`. No change needed.
- **Phase 4 Shortcuts (AppIntents):** Live in the App target only; invoke existing `DaemonClient` commands. No daemon changes needed.

---

*Research source: `battery-limiter-research.md`. SMC reference: `charlie0129/gosmc`, `charlie0129/batt`.*
*Revised after Opus code review — all Critical and Important issues addressed.*
