# BatteryCare

A macOS menu bar app with a privileged root daemon that limits battery charging on Apple Silicon Macs. Set any charge limit between 20–100%; the daemon enforces it continuously by writing to SMC hardware registers, even across sleep/wake cycles and reboots.

**Target hardware:** Apple Silicon (M1, M2, M3, M4/Tahoe)
**Target OS:** macOS Tahoe 26.4+
**Language:** Swift 6.0 / SwiftUI

> **Note:** BatteryCare uses private IOKit/SMC interfaces. It cannot be distributed through the Mac App Store and is intended for personal use.

---

## How It Works

### Architecture

```
┌─────────────────────────────────────────────┐
│  Menu Bar App  (runs as your user)           │
│  SwiftUI UI · BatteryViewModel · DaemonClient│
└──────────────────┬──────────────────────────┘
                   │  Unix domain socket IPC
                   │  /var/run/battery-care/daemon.sock
                   │  newline-delimited JSON
┌──────────────────▼──────────────────────────┐
│  battery-care-daemon  (runs as root)         │
│  DaemonCore · ChargingStateMachine           │
│  BatteryMonitor · SleepWatcher · SocketServer│
└──────────────────┬──────────────────────────┘
                   │  IOKit / AppleSMC
┌──────────────────▼──────────────────────────┐
│  SMC Hardware                                │
│  smc.c / smc.h  (C bridge, charlie0129/gosmc)│
│  CHTE key (M4) · CH0B + CH0C (M1/M2/M3)     │
└─────────────────────────────────────────────┘
```

### Privilege Separation

The app and daemon are separate processes with a hard UID gate:

- The **menu bar app** runs as your user. It connects to the daemon socket, sends `Command` messages (JSON), and receives `StatusUpdate` pushes.
- The **daemon** runs as root via a `LaunchDaemon` plist (`UserName = root`). It holds the SMC connection and is the only process that touches hardware. On startup it reads `allowedUID` from `settings.json`; connections from any other UID are silently rejected via `getpeereid()`.
- Settings are stored at `/Library/Application Support/BatteryCare/settings.json`, writable only by root.

### SMC Key Research — Why Each Key Was Chosen

Apple Silicon has no BCLM key (the old Intel approach). Charge control is entirely software: a polling daemon detects the battery level and tells the SMC to stop or allow charging.

#### M4 Tahoe: CHTE (4-byte pass-through key)

On M4, `CHTE` is the correct key for charge limiting:

| Write value | Effect |
|---|---|
| `[0x01, 0x00, 0x00, 0x00]` | Disable charging; adapter still powers the system (pass-through mode) |
| `[0x00, 0x00, 0x00, 0x00]` | Re-enable charging |

Pass-through mode is the right choice: the laptop stays powered from the adapter while the battery is paused, matching what AlDente calls "Charge Limiter."

#### M4 Tahoe: CHIE as a firmware detector

`CHIE` returns `dataSize=1` on M4 Tahoe firmware and `dataSize=0` on legacy M1/M2/M3. `SMCService` uses this at `open()` to decide which key strategy to use — if CHIE is readable, use CHTE; otherwise fall back to CH0B/CH0C.

> **Do not use CHIE for charge limiting.** CHIE is a force-discharge key: it disconnects the adapter entirely and drains the battery. Only the firmware detector probe reads it.

#### Legacy M1/M2/M3: CH0B + CH0C

On pre-Tahoe Apple Silicon, the charging inhibit keys are:

| Key | Disable | Enable |
|---|---|---|
| `CH0B` | `0x02` | `0x00` |
| `CH0C` | `0x02` | `0x00` |

Both keys are written on every charge control operation. BCLM (the percentage cap key present in some older firmware) has `dataSize=0` on M4 and is non-functional.

#### Why macOS Optimized Charging conflicts

macOS `powerd` runs its own charging heuristics and can override SMC key writes. This is why:
1. The daemon re-applies the SMC state on every poll tick — not just on state transitions.
2. The daemon also re-applies state on `willSleep` — immediately before the system sleeps, when powerd often tries to resume charging.
3. Users should disable **System Settings → Battery → Battery Health → Optimized Battery Charging** to prevent macOS from fighting the daemon.

### ChargingStateMachine

`ChargingStateMachine` is a pure value type (no side effects). `DaemonCore` calls it and then acts on the resulting state:

```
         ┌─ unplugged ──────────────────────────────────┐
         │                                              │
    [ idle ] ──── plugged in, % < limit ────> [ charging ]
         │                                              │
         │              % >= limit                      │
         │         ┌──────────────────────────[ limitReached ]
         │         │   % drops below limit              │
         │         └────────────────────────────────────┘
         │
    .disableCharging command ──────────────> [ disabled ]
    .enableCharging command  <────────────── [ disabled ]
         (re-derives from current reading)
```

| State | SMC action |
|---|---|
| `charging` | `enableCharging` |
| `limitReached` | `disableCharging` |
| `disabled` | `disableCharging` |
| `idle` | (no-op — unplugged) |

### IPC Protocol

The socket lives at `/var/run/battery-care/daemon.sock`. The framing is newline-delimited JSON: each message is a single JSON object followed by `\n`. There are no length-prefix headers.

**Commands (app → daemon):**

| Command JSON `type` | Parameters | Description |
|---|---|---|
| `getStatus` | — | Request a current status snapshot |
| `setLimit` | `percentage: Int` (clamped 20–100) | Set the charge limit |
| `enableCharging` | — | Re-enable charging (clears disabled flag) |
| `disableCharging` | — | Unconditionally stop charging |
| `setPollingInterval` | `seconds: Int` (clamped 1–30) | Change polling frequency |

**StatusUpdate (daemon → app):**

Sent as a response to any command and also pushed proactively after every poll tick and sleep/wake event. Key fields: `currentPercentage`, `isCharging`, `isPluggedIn`, `chargingState`, `limit`, `pollingInterval`, `error?`, `errorDetail?`.

### Sleep/Wake Handling

`SleepWatcher` registers with `IORegisterForSystemPower` and exposes an `AsyncStream<SleepEvent>`. `DaemonCore` listens in a dedicated `sleepLoop`:

- **`willSleep`**: Re-apply current SMC state immediately. This matters because macOS `powerd` often enables charging right before sleep (so the battery reaches 100% overnight). Re-applying the limit just before sleep blocks this.
- **`hasPoweredOn`**: Re-apply state and run a poll. The SMC can reset after hibernation; reapplying ensures limits survive wake.

`IOAllowPowerChange` is called synchronously in the IOKit callback before returning, which is required — if the callback does not ack within ~30 seconds, macOS force-sleeps regardless.

### SMAppService Daemon Registration

On first launch, `AppDelegate` calls `SMAppService.daemon(plistName:).register()` to install the daemon. Before registering, it seeds `settings.json` with the current user's UID into `allowedUID`. This must happen before the daemon starts so the daemon has the correct UID ready when it reads its settings on first launch.

If the app detects a stale registration (service is `.enabled` but `settings.json` is missing, e.g. after the app was reinstalled from a different path), it unregisters first and re-registers cleanly.

The LaunchDaemon plist (`com.batterycare.daemon.plist`) is bundled inside `BatteryCare.app` and references the daemon binary at `/Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon`. SMAppService copies the plist to `/Library/LaunchDaemons/` on `register()`.

Daemon logs are written to:
- `/Library/Logs/BatteryCare/daemon.log`
- `/Library/Logs/BatteryCare/daemon-error.log`

---

## Requirements

- Apple Silicon Mac (M1, M2, M3, or M4)
- macOS Tahoe 26.4 or later
- Xcode 16+ (for building from source)
- Administrator password (for daemon installation)

---

## Build and Install

### Quick install via script

```bash
git clone <your-repo-url>
cd battery-care
sudo bash install.sh
```

When the app opens, macOS will prompt you to allow the background service. Click **Allow**.

Then disable macOS Optimized Charging so it does not conflict:
**System Settings → Battery → Battery Health → Optimized Battery Charging → Off**

### What install.sh does, step by step

1. Builds the `BatteryCare` scheme in Release configuration into `/tmp/BatteryCare-build`.
2. Runs `sudo launchctl bootout` to stop any existing daemon.
3. Copies the built `BatteryCare.app` to `/Applications/BatteryCare.app` and sets `root:wheel` ownership.
4. Strips Gatekeeper provenance attributes (`xattr -rc`) so the app is not quarantined.
5. Creates `/Library/Application Support/BatteryCare/` owned by the logged-in user, and removes any stale `settings.json`.
6. Opens the app as the logged-in user, which triggers `AppDelegate` → seeds `settings.json` → calls `SMAppService.register()`.

### Build individual targets manually

```bash
# Build the menu bar app
xcodebuild -project BatteryCare/BatteryCare.xcodeproj \
           -scheme BatteryCare \
           -configuration Release \
           -derivedDataPath /tmp/bc-build \
           build

# Build the daemon only
xcodebuild -project BatteryCare/BatteryCare.xcodeproj \
           -scheme battery-care-daemon \
           -configuration Release \
           -derivedDataPath /tmp/bc-build \
           build
```

### Redeploy daemon after a rebuild

```bash
sudo cp /tmp/bc-build/Build/Products/Release/battery-care-daemon \
        /Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.batterycare.daemon.plist
```

---

## Uninstall

```bash
sudo bash uninstall.sh
```

This will re-enable charging, quit the app, stop and remove the daemon, and delete all app data. If charging remains disabled afterwards, compile and run `debug-tools/reenable_charging.c` as root (see Debug Tools below).

---

## Run Tests

```bash
# App-side unit tests (BatteryViewModel, DaemonClient mocks)
xcodebuild -project BatteryCare/BatteryCare.xcodeproj \
           -scheme AppTests \
           test

# Daemon unit tests (DaemonCore, ChargingStateMachine, SocketServer)
xcodebuild -project BatteryCare/BatteryCare.xcodeproj \
           -scheme DaemonTests \
           test
```

All daemon subsystems are protocol-based (`SMCServiceProtocol`, `BatteryMonitorProtocol`, `SleepWatcherProtocol`, `SocketServerProtocol`) so tests can inject mock implementations without touching hardware or sockets.

---

## Debug Tools

The `debug-tools/` directory contains C programs for probing and testing SMC keys directly. All tools must be run as root. Compile from the repo root so that the include path to `BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.h` resolves correctly.

### probe_smc.c — probe all charging-related SMC keys

Reads `dataSize`, type, and raw byte values for CHIE, CH0J, CH0B, CH0C, BCLM, CH0I, ACLC, and BUIC. Use this to verify which keys are active on your firmware.

```bash
clang -o probe_smc debug-tools/probe_smc.c \
      -framework IOKit -framework CoreFoundation
sudo ./probe_smc
```

Expected output on M4 Tahoe: CHIE has `dataSize=1`; CH0B, CH0C, and BCLM all show `dataSize=0`.

### test_chte.c — CHTE write/read cycle test

Writes `[0x01, 0x00, 0x00, 0x00]` to CHTE (disable charging), waits 5 seconds, then writes `[0x00, 0x00, 0x00, 0x00]` to re-enable. Use this to confirm CHTE works on your firmware before relying on the daemon.

```bash
clang -o test_chte debug-tools/test_chte.c \
      -framework IOKit -framework CoreFoundation
sudo ./test_chte
# In another terminal while the tool waits:
# pmset -g batt   →  should show "AC Power" + "Not Charging"
```

### chie_monitor.c — CHIE key monitor (powerd override detector)

Writes `CHIE=0x00`, then reads CHIE once per second for 30 seconds, printing whether `powerd` has overridden the value back. Used during research to confirm CHIE is unstable under powerd and unsuitable as a primary charge-limiting key.

```bash
clang -o chie_monitor debug-tools/chie_monitor.c \
      -framework IOKit -framework CoreFoundation
sudo ./chie_monitor
```

### reenable_charging.c — emergency charging re-enabler

Writes `CHIE=0x00` to re-enable charging via the legacy path. Use this if the daemon is not running and the battery is stuck in a no-charge state.

```bash
clang -o reenable_charging debug-tools/reenable_charging.c \
      -framework IOKit -framework CoreFoundation
sudo ./reenable_charging
```

> **M4 note:** This tool writes to CHIE (legacy key). On M4 Tahoe, if the daemon used CHTE to disable charging, run `test_chte` instead — it re-enables at step 4 of its cycle.

---

## Repository Layout

```
battery-care/
├── BatteryCare/                      # Xcode project root
│   ├── BatteryCare.xcodeproj
│   ├── BatteryCare/                  # Menu bar app target
│   │   ├── BatteryCareApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── Services/DaemonClient.swift
│   │   ├── ViewModels/BatteryViewModel.swift
│   │   └── Views/
│   ├── battery-care-daemon/          # Daemon target (root process)
│   │   ├── Core/
│   │   │   ├── DaemonCore.swift
│   │   │   ├── ChargingStateMachine.swift
│   │   │   └── BatteryMonitor.swift
│   │   ├── Hardware/
│   │   │   ├── SMCService.swift
│   │   │   └── ThirdParty/           # smc.c, smc.h, NOTICE (GPL-2.0)
│   │   ├── IPC/SocketServer.swift
│   │   ├── Settings/DaemonSettings.swift
│   │   └── Sleep/SleepWatcher.swift
│   ├── AppTests/
│   └── DaemonTests/
├── Shared/                           # SPM package: Command, StatusUpdate, ChargingState
│   └── Sources/BatteryCareShared/
├── debug-tools/                      # C diagnostic tools
├── install.sh                        # Build + install script
├── uninstall.sh                      # Uninstall script
└── battery-limiter-research.md       # Original SMC key research notes
```

---

## Contributing

- **Daemon source is under `BatteryCare/battery-care-daemon/`** — this is the only compiled daemon target.
- **All subsystems are protocol-based** (`SMCServiceProtocol`, `BatteryMonitorProtocol`, etc.) — use mock implementations in tests rather than touching hardware or sockets.
- **SMC access requires root** — daemon tests that call real SMC APIs will be skipped or fail unless run as root. This is expected.

---

## Credits

### smc.c / smc.h

The C bridge for IOKit SMC access is taken from [charlie0129/gosmc](https://github.com/charlie0129/gosmc):

```
Apple System Management Control (SMC) Tool
Copyright (C) 2006 devnull
Portions Copyright (C) 2013 Michael Wilber
Portions Copyright (C) 2023 Charlie Chiang

Licensed under the GNU General Public License, version 2 (GPL-2.0).
```

See `BatteryCare/battery-care-daemon/Hardware/ThirdParty/NOTICE` for full attribution.

### CHTE / CHIE key discovery for M4 Tahoe

The discovery that CHTE (not CHIE or CH0B/CH0C) is the correct 4-byte charging control key on M4 Tahoe firmware came from [actuallymentor/battery](https://github.com/actuallymentor/battery), which first documented Tahoe-specific SMC key changes. Cross-referenced against [charlie0129/batt](https://github.com/charlie0129/batt), which added explicit Tahoe SMC key support in its v0.7 series.
