# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BatteryCare is a macOS menu bar app + privileged root daemon that limits battery charging on Apple Silicon Macs. The app sends commands over IPC; the daemon writes to SMC hardware registers to enable/disable charging.

## Build & Test

This is an **Xcode project** at `BatteryCare/BatteryCare.xcodeproj`. All builds go through `xcodebuild` from the `BatteryCare/` directory.

```bash
# Build all targets
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme BatteryCare build
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme battery-care-daemon build

# Run tests
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme DaemonTests test
xcodebuild -project BatteryCare/BatteryCare.xcodeproj -scheme AppTests test
```

There is no top-level SPM build. The `Shared/` package is consumed as a local SPM dependency by Xcode.

## Architecture

**Privilege separation model:**

```
Menu Bar App (user)  ──Unix socket IPC──>  Daemon (root)  ──IOKit──>  SMC Hardware
```

### Three codebases, two that matter

| Directory | Purpose | Built by Xcode? |
|-----------|---------|-----------------|
| `BatteryCare/App/` | SwiftUI menu bar UI, ViewModel, DaemonClient | Yes (BatteryCare target) |
| `BatteryCare/battery-care-daemon/` | Root daemon: SMC, battery, IPC server | Yes (battery-care-daemon target) |
| `Shared/` | SPM package: Command, StatusUpdate, ChargingState | Yes (local dependency) |
| `Daemon/` | **Legacy/prototype** — same structure as battery-care-daemon | **No** — not built by Xcode |

**IMPORTANT:** Always edit files under `BatteryCare/battery-care-daemon/` for daemon changes, NOT `Daemon/`. The `Daemon/` directory is an older copy that is not compiled by the Xcode project.

### Daemon internals

- **DaemonCore** (Swift actor) — orchestrates everything: polling loop, sleep/wake loop, command handling
- **ChargingStateMachine** — pure value type with states: `idle`, `charging`, `limitReached`, `disabled`
- **SMCService** — IOKit wrapper that probes for charging keys at open():
  - M4 Tahoe: `CHIE` key (dataSize=1)
  - Legacy M1/M2/M3: `CH0B` + `CH0C` keys
- **BatteryMonitor** — reads battery state from IOPSCopyPowerSourcesInfo
- **SleepWatcher** — IORegisterForSystemPower for sleep/wake events
- **SocketServer** — Unix domain socket at `/var/run/battery-care/daemon.sock`, newline-delimited JSON

### IPC protocol

Newline-delimited JSON over Unix stream socket. Types defined in `Shared/Sources/BatteryCareShared/`:
- `Command` (app -> daemon): `.getStatus`, `.setLimit(percentage:)`, `.enableCharging`, `.disableCharging`, `.setPollingInterval(seconds:)`
- `StatusUpdate` (daemon -> app): battery %, charging state, limits, errors
- UID-gated via `getpeereid()` — only the installing user's UID can send commands

### App internals

- **BatteryViewModel** — Combine-based `@Published` properties, consumes StatusUpdate stream from DaemonClient
- **DaemonClient** — connects to daemon socket, exponential backoff reconnect, dedicated read thread
- **AppDelegate** — registers daemon via SMAppService on first launch

## Key Protocols

All daemon subsystems are protocol-based for testability:
- `SMCServiceProtocol` — open/perform/read/close
- `BatteryMonitorProtocol` — read() -> BatteryReading
- `SleepWatcherProtocol` — events() -> AsyncStream<SleepEvent>
- `SocketServerProtocol` — start/broadcast/stop
- `DaemonClientProtocol` — statusPublisher/connectedPublisher/send

Tests use mock implementations of these protocols (defined inline in test files).

## SMC Hardware Notes

- SMC access requires **root privileges** (daemon runs as root via LaunchDaemon)
- C bridging: `battery-care-daemon/Hardware/ThirdParty/smc.{h,c}` with `SMCBridgingHeader.h`
- **CHTE** on M4 Tahoe: 4-byte key for pass-through mode (stop charging, keep adapter power)
  - `[0x01, 0x00, 0x00, 0x00]` = disable charging (adapter still powers system)
  - `[0x00, 0x00, 0x00, 0x00]` = enable charging
- **CHIE** is force-discharge (disconnects adapter entirely) — do NOT use for charge limiting
- Legacy keys CH0B/CH0C/BCLM all have dataSize=0 on M4 (non-functional)
- Legacy charging control: CH0B+CH0C (0x02=disable, 0x00=enable)

## Deployment

- LaunchDaemon plist: `Resources/Contents/Library/LaunchDaemons/com.batterycare.daemon.plist`
- Daemon binary installed to: `/Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon` — **this is the actual running path** (SMAppService installs here, not `/Library/Application Support/`)
- Settings persisted at: `/Library/Application Support/BatteryCare/settings.json`
- Platform: macOS 13+, Swift 6.0, Apple Silicon only

To redeploy after a build:
```bash
sudo cp <DerivedData>/Release/battery-care-daemon /Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.batterycare.daemon.plist
```
