# macOS Battery Charge Limiter — Research & Build Plan

> Exported from Claude chat for continuation in Claude Code.
> Target: Personal macOS app replicating AlDente features on **MacBook Pro M4, macOS Tahoe 26.4.1**

---

## 1. Goal

Build a personal macOS menu bar app that:
- Limits battery charge to **any percentage (e.g. 20–100%)**, not just 80% or 100%
- Targets **Apple Silicon M4** exclusively
- Runs on **macOS Tahoe 26.4.1** (latest as of April 2026)
- Is written in **Swift / SwiftUI**

Native macOS 26.4 charge limiting only supports 80–100%. Custom SMC control is required to go below 80%.

---

## 2. AlDente Feature Reference

Source: https://apphousekitchen.com/aldente-overview/features

### Free Features
| Feature | Description |
|---|---|
| **Charge Limiter** | Set max charge %. MacBook stops charging at that level and runs on AC power only. |
| **Discharge** | Force battery to drain while plugged in, down to a target %. Simulates internal unplug. |

### Pro Features
| Feature | Description |
|---|---|
| **Automatic Discharge** | Auto-triggers Discharge when current % exceeds set limit. No manual activation needed. |
| **Sailing Mode** | Sets a lower bound (e.g. 75–80%) so battery doesn't micro-charge/discharge constantly. |
| **Heat Protection** | Pauses charging when battery temp exceeds threshold (default 35°C). Has 5-min hysteresis. |
| **Calibration Mode** | Full cycle: current → 100% → 10% → 100% → hold 1hr → restore limit. Fixes miscalibration. |
| **Top Up** | One-time override to charge to 100%, auto-reverts to original limit after unplugging. |
| **Schedule** | Cron-style tasks: set limit, calibrate, top up, discharge. Daily/weekly/biweekly/monthly. |
| **Stop Charging when Sleeping** | Pauses charging just before sleep so battery doesn't creep to 100% overnight. |
| **Stop Charging when App Closed** | Apple Silicon only — charge limit persists even when app quits (via launchd daemon). |
| **Disable Sleep until Charge Limit** | Prevents sleep until target % reached, then re-enables sleep. |
| **Hardware Battery %** | Reads raw % from battery management system (2–7% more accurate than macOS display). |
| **Power Flow (Sankey)** | Real-time visualization of power: charger → MacBook + battery. |
| **Live Status Icons** | Menu bar icons reflecting current state (charging / paused / discharging). |
| **MagSafe LED Control** | Controls MagSafe LED color to reflect charge state. Model-specific, fragile. |
| **Apple Shortcuts Integration** | Exposes actions (set limit, top up, get state) to macOS Shortcuts via AppIntents. |

---

## 3. Key Technical Finding: Apple Silicon SMC

### Intel vs Apple Silicon — Critical Difference

On **Intel** Macs: charge limiting was a single SMC key write:
```
BCLM = <percentage>   # e.g. 0x50 = 80%
```
Tools like SMCKit (beltex/SMCKit) handled this. **SMCKit is Intel-only and useless for M4.**

On **Apple Silicon** (M1/M2/M3/M4): there is **no BCLM key**. The hardware only understands on/off charging commands. The charge limit is **entirely implemented in software** via a polling daemon:

```
poll battery % every N seconds
  if % >= upper_limit → write CH0B = 0x02  (stop charging)
  if % <= lower_limit → write CH0B = 0x00  (start charging)
```

### The SMC Keys for Apple Silicon

| Key | Purpose | Value |
|---|---|---|
| `CH0B` | Enable/disable battery charging | `0x00` = enable, `0x02` = disable |
| `CH0C` | Also used for charging control (fallback) | Same as CH0B |
| `AC-W` | Enable/disable power adapter (simulates unplug) | Used for Discharge feature |
| `CH0I` | Power adapter inhibit | Used for Discharge feature |
| `TB0T` / `TB1T` | Battery temperature | Float, degrees Celsius |

> **Source:** `charlie0129/gosmc` — the C library used by `batt`. SMC key `CH0B` write is the entire secret.

### Note on macOS 26 Tahoe
A recent `batt` contributor specifically added **"Support Tahoe SMC keys with existing smc binary"** — the CH0B approach was verified and patched to work on macOS 26. Always verify against your firmware:
```bash
system_profiler SPHardwareDataType | grep -i firmware
```

---

## 4. Open Source Reference Projects

### 4.1 `charlie0129/batt` ⭐ Primary Reference
- **URL:** https://github.com/charlie0129/batt
- **License:** GPL-2.0 ⚠️ (viral — read carefully before reusing code directly)
- **Language:** Go + C (Objective-C for IOKit notifications)
- **Target:** Apple Silicon only, macOS Tahoe verified
- **Stars:** ~1.5k
- **Status:** Actively maintained (latest release v0.7.3, Mar 2026)

**Why it's the best reference:**
- Apple Silicon only, M1–M4 tested
- Handles all sleep/wake edge cases correctly
- Open source daemon + client architecture
- Has calibration, MagSafe LED, pre-sleep charging disable
- Firmware compatibility matrix documented

**Architecture:**
```
batt daemon (launchd, root) ←——unix socket——→ batt client (CLI or SwiftUI GUI)
       ↓
   smc.c / smc.h  (C, talks to AppleSMC via IOKit)
       ↓
   CH0B SMC key (enable/disable charging)
```

**Key features implemented in batt:**
- `limit` — upper bound charge limit
- `lower-limit-delta` — sets lower bound (sailing mode equivalent)
- `disable-charging-pre-sleep` — stops charging before lid close / sleep
- `prevent-idle-sleep` — prevents idle sleep during charging session
- `prevent-system-sleep` — stronger sleep prevention (experimental)
- `adapter` — disable/enable power adapter (discharge feature)
- `calibration` — full cycle calibration with phases
- `magsafe-led` — MagSafe LED control
- `schedule` — cron-based scheduling

### 4.2 `charlie0129/gosmc` — The SMC C Library
- **URL:** https://github.com/charlie0129/gosmc
- **License:** GPL-2.0
- **Language:** C (66%) + Go (33%)
- **Key files:** `smc.c`, `smc.h`, `smc.go`

This is the actual hardware interface layer. The C files (`smc.c`, `smc.h`) can be used directly in a Swift project via a bridging header.

**Example usage (Go, but C API is the same):**
```go
c := gosmc.New()
c.Open()
defer c.Close()

// Disable charging
c.Write("CH0B", []byte{0x2})

// Enable charging  
c.Write("CH0B", []byte{0x0})

// Read temperature
v, _ := c.Read("TB0T")
```

**For Swift:** include `smc.c` and `smc.h` in your Xcode project with a bridging header:
```swift
// BridgingHeader.h
#include "smc.h"
```

### 4.3 `actuallymentor/battery`
- **URL:** https://github.com/actuallymentor/battery
- **License:** MIT ✅ (more permissive)
- **Language:** JavaScript/Electron (GUI) + bundled `smc` binary (C)
- **Target:** Apple Silicon M1/M2/M3 (M4 not explicitly listed but same SMC)
- **Stars:** ~4.6k

Useful for cross-referencing SMC key names. The bundled `smc` binary is the same C approach.

### 4.4 `AppHouseKitchen/AlDente-Battery_Care_and_Monitoring` — Original AlDente
- **URL:** https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring
- **License:** Custom (closed source notice in README)
- **Status:** ⚠️ **No longer open source** as of current version
- **Language:** Swift (76.5%) — legacy code only

> README: *"This project is no longer open source. Although the GitHub repository contains legacy code and archived releases, the current version of the software is proprietary and closed-source."*

The legacy code still shows the `SMJobBless` helper pattern and UI structure, but the core SMC logic is Intel-era and outdated for M4.

### 4.5 `beltex/SMCKit` — Intel Only, Do Not Use for M4
- **URL:** https://github.com/beltex/SMCKit
- **License:** MIT
- **Status:** ⚠️ **Intel-only**. Uses `AppleSMC.kext` which does not exist on Apple Silicon.

---

## 5. Feasibility Assessment (M4 + macOS 26.4)

| Feature | Difficulty | Gap Closed by OSS? | Source |
|---|---|---|---|
| Read battery stats (%, temp, cycle count) | **Low** | ✅ Public IOKit APIs | Apple SDK |
| SMC write — charge enable/disable | **Medium** | ✅ `CH0B`/`CH0C` keys + `smc.c`/`smc.h` | `charlie0129/gosmc` |
| Charge limiter polling loop | **Medium** | ✅ Daemon loop pattern fully documented | `charlie0129/batt` |
| Discharge (drain while plugged in) | **Medium** | ✅ Power adapter SMC keys documented | `charlie0129/batt` |
| Privileged daemon (launchd, root) | **Low–Medium** | ✅ Full launchd plist setup in batt source | `charlie0129/batt` |
| Sleep/wake handling + pre-sleep stop | **Low–Medium** | ✅ IOKit notifications in C, NSWorkspace in Swift | `charlie0129/batt` |
| Prevent idle sleep during charging | **Low–Medium** | ✅ `IOPMAssertionCreateWithName` pattern shown | `charlie0129/batt` |
| SMC read — temperature | **Medium** | ✅ `TB0T`/`TB1T` key confirmed | `charlie0129/batt` |
| Sailing mode logic | **Medium** | ✅ Pure app logic on charge on/off primitives | `charlie0129/batt` |
| Calibration mode | **Medium** | ✅ Phase-based implementation in batt | `charlie0129/batt` |
| Schedule (cron-style tasks) | **Low–Medium** | ✅ `batt schedule` + launchd pattern | `charlie0129/batt` |
| Menu bar UI (SwiftUI) | **Low** | — No gap, standard SwiftUI | Apple SDK |
| LaunchAtLogin | **Low** | ✅ `sindresorhus/LaunchAtLogin` (MIT) | External lib |
| MagSafe LED control | **High** | ⚠️ Partial — batt implements it but fragile | `charlie0129/batt` |
| Shortcuts (AppIntents) | **Medium** | — Apple docs sufficient | Apple SDK |

---

## 6. Recommended Architecture

### Pattern: Daemon + Client (same as `batt`)

```
┌─────────────────────────────────────────────┐
│  SwiftUI Menu Bar App (client)               │
│  - NSStatusItem + popover UI                 │
│  - Reads state from daemon                   │
│  - Sends commands to daemon                  │
│  - Launched at login via LaunchAtLogin       │
└──────────────┬──────────────────────────────┘
               │ Unix Domain Socket (IPC)
               │ /tmp/battery-helper.sock
┌──────────────▼──────────────────────────────┐
│  Privileged Daemon (root, launchd)           │
│  - Installed to /Library/LaunchDaemons/      │
│  - Polls battery % every ~5 seconds          │
│  - Writes CH0B via smc.c                     │
│  - Handles sleep/wake via IOKit              │
│  - Persists across app quit + sleep          │
└──────────────┬──────────────────────────────┘
               │ IOKit / AppleSMC
┌──────────────▼──────────────────────────────┐
│  smc.c / smc.h  (C, bridged to Swift)        │
│  - Reads/writes SMC keys                     │
│  - Key: CH0B (charge on/off)                 │
│  - Key: TB0T (battery temp)                  │
└─────────────────────────────────────────────┘
```

### Why daemon not SMJobBless helper?
- SMJobBless is Apple's old pattern (used in legacy AlDente). 
- `launchd` daemon installed to `/Library/LaunchDaemons/` is the modern pattern (used in batt).
- More reliable: persists across user logout, sleep, app quit.
- Simpler security model: one-time install with admin password.

### IPC: Unix Domain Socket
- Daemon listens on `/tmp/<appname>.sock`
- Client (SwiftUI app) connects and sends JSON commands
- Commands: `setLimit`, `getStatus`, `setMode`, `setSailingRange`, etc.

---

## 7. Key Implementation Details

### 7.1 SMC C Bridging in Swift
```
YourApp/
├── Sources/
│   ├── smc.c          ← from charlie0129/gosmc
│   ├── smc.h          ← from charlie0129/gosmc
│   └── BridgingHeader.h
```

`BridgingHeader.h`:
```c
#include "smc.h"
```

### 7.2 Daemon Install Flow
1. SwiftUI app bundles the daemon binary
2. On first launch, prompts admin password via `AuthorizationCreate`
3. Copies daemon binary to `/usr/local/bin/<appname>-daemon`
4. Writes plist to `/Library/LaunchDaemons/<bundle-id>.plist`
5. Loads via `launchctl load`

### 7.3 Sleep/Wake Notifications (C/ObjC required)
```c
// Register for sleep/wake via IOKit
IORegisterForSystemPower(self, &notifierPort, sleepWakeCallback, &notifier);

void sleepWakeCallback(void* refCon, io_service_t service,
                       natural_t messageType, void* messageArgument) {
    if (messageType == kIOMessageSystemWillSleep) {
        // disable charging before sleep
    } else if (messageType == kIOMessageSystemHasPoweredOn) {
        // re-evaluate charging state on wake
    }
}
```

### 7.4 Prevent Idle Sleep
```swift
var assertionID: IOPMAssertionID = 0
IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Battery charging in progress" as CFString,
    &assertionID
)
// Release when done:
IOPMAssertionRelease(assertionID)
```

### 7.5 Reading Battery Info (IOKit)
```swift
import IOKit.ps

let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
for source in sources {
    let info = IOPSGetPowerSourceDescription(snapshot, source)
        .takeUnretainedValue() as! [String: Any]
    let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int  // %
    let temperature = info["Temperature"] as? Double              // raw
    let cycleCount = info[kIOPSBatteryHealthConfidenceKey]        // varies
}
```

---

## 8. Recommended Build Order (MVP First)

### Phase 1 — Core (MVP)
1. Set up Xcode project: SwiftUI menu bar app + C bridging for `smc.c`
2. Read battery % and charging state via IOKit
3. Write `CH0B` to enable/disable charging (test this first, everything else depends on it)
4. Build privileged launchd daemon with install/uninstall flow
5. Unix socket IPC between app and daemon
6. Basic UI: slider or text field to set limit %, current % display, status icon

### Phase 2 — Reliability
7. Sleep/wake handling: stop charging before sleep, resume on wake
8. Prevent idle sleep during charging session
9. Persist limit across app quit (daemon keeps running)
10. Discharge feature (disable power adapter via `AC-W` / `CH0I` SMC key)

### Phase 3 — Advanced
11. Sailing mode (upper + lower bound)
12. Heat protection (temp monitoring + hysteresis)
13. Top Up (one-time 100% override)
14. Calibration mode (phase-based full cycle)
15. Schedule (cron-style tasks)

### Phase 4 — Polish
16. Power flow visualization (Sankey diagram)
17. Hardware battery % reading
18. Apple Shortcuts integration (AppIntents)
19. MagSafe LED control (optional, fragile)

---

## 9. Known Risks & Gotchas

| Risk | Details |
|---|---|
| **SMC key changes across firmware** | `batt` has a firmware compatibility matrix — SMC keys have shifted between versions. Always test on target firmware. Check: `system_profiler SPHardwareDataType \| grep -i firmware` |
| **Daemon persists charge state after reboot** | Apple Silicon resets SMC on cold boot/reboot. Daemon must re-apply limit on startup. `batt` documents this explicitly. |
| **Clamshell mode + discharge** | Disabling power adapter in clamshell (lid closed, external monitor) causes sleep. batt documents this as a macOS limitation. |
| **Hibernate vs sleep** | If Mac enters hibernation (not sleep), firmware resets SMC keys. batt's fix: `sudo pmset -a hibernatemode 3` (factory default). |
| **GPL-2.0 license on batt/gosmc** | GPL is viral — if you include GPL code directly, your app must also be GPL. For personal use this doesn't matter. For distribution, use it as reference only and rewrite the SMC layer independently. |
| **Requires disabling macOS Optimized Charging** | Must instruct user to disable `System Settings → Battery → Battery Health → Optimized Battery Charging`. Otherwise conflicts with native logic. |
| **Not Mac App Store compatible** | SMC access uses private/undocumented IOKit interfaces. This will never pass App Store review. Personal use / direct distribution only. |

---

## 10. External Libraries

| Library | Purpose | License | URL |
|---|---|---|---|
| `sindresorhus/LaunchAtLogin` | Login item management | MIT | https://github.com/sindresorhus/LaunchAtLogin |
| `charlie0129/gosmc` (C files only) | SMC read/write for Apple Silicon | GPL-2.0 | https://github.com/charlie0129/gosmc |
| `charlie0129/batt` | Reference implementation | GPL-2.0 | https://github.com/charlie0129/batt |

---

## 11. Quick SMC Test (Verify CH0B Works on Your M4)

Before writing any Swift, verify the SMC key works on your machine:

```bash
# Install batt to test
brew install batt
sudo brew services start batt

# Check current status
sudo batt status

# Test limiting to 80%
sudo batt limit 80

# Verify it stopped charging above 80%
# Then disable and uninstall when done
sudo batt disable
sudo batt uninstall
```

If this works on your M4 under macOS 26.4.1, the `CH0B` approach is confirmed valid and you can proceed with building your own app using the same mechanism.

---

## 12. File Structure Suggestion for the Project

```
BatteryLimiter/
├── BatteryLimiter.xcodeproj
├── App/                          # SwiftUI menu bar app
│   ├── AppDelegate.swift
│   ├── StatusBarController.swift
│   ├── Views/
│   │   ├── PopoverView.swift
│   │   ├── SettingsView.swift
│   │   └── StatusIconView.swift
│   └── BridgingHeader.h
├── Core/                         # Shared models & IPC
│   ├── BatteryState.swift
│   ├── DaemonClient.swift        # Unix socket client
│   └── Models.swift
├── Daemon/                       # Privileged daemon target
│   ├── main.swift
│   ├── ChargeController.swift    # Polling loop + SMC writes
│   ├── SleepWatcher.swift        # IOKit sleep/wake
│   ├── DaemonServer.swift        # Unix socket server
│   └── SMC/
│       ├── smc.c                 # from gosmc
│       ├── smc.h                 # from gosmc
│       └── SMCBridge.swift       # Swift wrapper
└── Resources/
    └── com.yourname.battery-daemon.plist   # LaunchDaemon plist
```

---

*Last updated: April 2026. Research conducted via Claude (claude.ai). Continue implementation in Claude Code.*
