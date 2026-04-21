# Sleep Charging: Scheduled Maintenance Wakes

**Date:** 2026-04-21
**Status:** Approved

## Problem

When the user closes the Mac lid while the battery is below the charge limit, the daemon is suspended by the OS. The SMC continues charging unchecked — the battery can significantly overshoot the limit by the time the user reopens the lid.

Root cause: `willSleep` in `DaemonCore.sleepLoop()` calls `applyState()`, which writes `enableCharging` to SMC when `state == .charging`. The daemon then goes dark with charging enabled and no polling loop running.

Small overshoot (a few percent) is acceptable. Large overshoot (10–30%) is not.

## Solution

Use `IOPMSchedulePowerEvent` to schedule periodic dark (maintenance) wakes while the system is asleep. On each wake the daemon polls the battery, re-evaluates state, corrects the SMC if needed, and lets the system return to sleep. The cycle repeats until the limit is reached or the user wakes the Mac naturally.

Charging is disabled before each sleep as a safety net. It is re-enabled on wake if the battery is still below the limit.

## Architecture

### Sleep cycle

```
willSleep
  if plugged + below limit + not disabled:
    smc.perform(.disableCharging)       // safety: stop charging before going dark
    sleepAssertion.release()            // not actively charging anymore
    scheduleWake(in: sleepWakeInterval) // dark wake in N minutes
  else:
    applyState()                        // existing behavior

hasPoweredOn
  cancelScheduledWake()                 // always cancel, regardless of wake source
  pollOnce()                            // re-evaluate from fresh battery reading
  // applyState() inside pollOnce() re-enables charging if still below limit
  // system returns to sleep naturally → willSleep fires → cycle repeats
```

### Termination condition

When `pollOnce()` on wake finds `battery >= limit`, state becomes `.limitReached`, `applyState()` keeps charging disabled, and `willSleep` (when Mac sleeps again) takes the `else` branch — no further wake is scheduled.

## Components

### `DaemonSettings`

Add field:
```swift
var sleepWakeInterval: Int  // minutes, default 5, clamped 5–30
```

- Persisted in `settings.json`
- Custom decoder fallback: missing key → default 5 (same pattern as `sailingLower`)
- No UI for now; configurable via `setSleepWakeInterval` IPC command

### `Shared/Command`

Add case:
```swift
case setSleepWakeInterval(minutes: Int)
```

### `DaemonCore`

New stored state:
```swift
private var scheduledWakeDate: Date? = nil
```

New private helpers:

**`shouldScheduleWake() -> Bool`**
Reads current battery. Returns `true` when all of:
- `reading.isPluggedIn == true`
- `reading.percentage < settings.limit`
- `settings.isChargingDisabled == false`

**`scheduleWake()`**
- Calls `cancelScheduledWake()` first (defensive — avoids duplicate entries)
- Computes `date = Date() + sleepWakeInterval * 60`
- Calls `IOPMSchedulePowerEvent(date, "com.batterycare.daemon", kIOPMAutoWake)`
- Stores `scheduledWakeDate = date`
- Logs result at info level

**`cancelScheduledWake()`**
- Returns immediately if `scheduledWakeDate == nil`
- Calls `IOPMCancelScheduledPowerEvent(date, "com.batterycare.daemon", kIOPMAutoWake)`
- Clears `scheduledWakeDate = nil`
- Logs result at info level

**`handle(.setSleepWakeInterval)`**
- Clamps to 5–30
- Saves settings
- Returns `makeStatusUpdate()`

**`sleepLoop()` — updated:**
```swift
case .willSleep:
    if shouldScheduleWake() {
        try? smc.perform(.disableCharging)
        sleepAssertion.release()
        scheduleWake()
    } else {
        applyState()
    }

case .hasPoweredOn:
    cancelScheduledWake()
    pollOnce()
```

### Log file

Written to: `/Library/Application Support/BatteryCare/daemon.log`

A `FileLogger` helper (single new file) wraps a file descriptor, exposes an `info(_ message: String)` method, and reopens the file on `SIGHUP`.

### `newsyslog` rotation config

Installed to `/etc/newsyslog.d/com.batterycare.daemon.conf`:
```
/Library/Application Support/BatteryCare/daemon.log  644  5  256  *  JN  com.batterycare.daemon
```
- 5 bzip2-compressed archives
- Rotate at 256 KB
- Size-based only (no time trigger)
- Max ~1.5 MB total on disk

Config file added to `Resources/` alongside the LaunchDaemon plist.

### `main.swift`

Install a `SIGHUP` signal handler that calls `fileLogger.reopen()` so the daemon writes to the fresh file after `newsyslog` rotates.

## Log Lines

All written to both `os.log` (info level) and the log file.

| Event | Format |
|-------|--------|
| `willSleep` — wake scheduled | `[sleep] willSleep: battery=57% limit=60% → disableCharging, wake scheduled in 5 min` |
| `willSleep` — no wake | `[sleep] willSleep: battery=62% limit=60% → applyState (no wake scheduled)` |
| `scheduleWake` success | `[sleep] scheduleWake: scheduled at <timestamp> OK` |
| `scheduleWake` failure | `[sleep] scheduleWake: FAILED: <error>` |
| `hasPoweredOn` | `[sleep] hasPoweredOn: battery=58% limit=60% state=charging → enableCharging` |
| `cancelScheduledWake` | `[sleep] cancelScheduledWake: cancelled <timestamp>` |
| `pollOnce` | `[poll] battery=58% plugged=true charging=true state=charging limit=60%` |

## Error Handling

| Failure | Behavior |
|---------|----------|
| `IOPMSchedulePowerEvent` fails | Log warning, continue. Charging is already disabled. No correction wake fires; daemon corrects on next natural wake. |
| `IOPMCancelScheduledPowerEvent` fails | Log warning, clear `scheduledWakeDate`. Stale wake fires; `hasPoweredOn` handles it correctly. |
| User opens lid before scheduled wake | `cancelScheduledWake()` in `hasPoweredOn` cancels the pending entry unconditionally. |
| Second `willSleep` before wake fires | `scheduleWake()` cancels existing entry before scheduling new one. |
| Daemon restart mid-sleep | No `scheduledWakeDate` in memory. Stale system entry fires, `hasPoweredOn` handles correctly. Entry self-expires. |
| `isChargingDisabled` toggled while asleep | Persisted; `pollOnce()` on next wake reads fresh settings, `applyState()` respects it. |

## Files Changed

| File | Change |
|------|--------|
| `BatteryCare/battery-care-daemon/Settings/DaemonSettings.swift` | Add `sleepWakeInterval` field + decoder fallback |
| `BatteryCare/battery-care-daemon/Core/DaemonCore.swift` | Update `sleepLoop()`, add `scheduleWake()`, `cancelScheduledWake()`, `shouldScheduleWake()`, handle new command |
| `BatteryCare/battery-care-daemon/Logging/FileLogger.swift` | New file: log file helper with `reopen()` |
| `BatteryCare/battery-care-daemon/main.swift` | Install `SIGHUP` handler, wire `FileLogger` |
| `Shared/Sources/BatteryCareShared/Command.swift` | Add `setSleepWakeInterval(minutes:)` case |
| `Resources/newsyslog/com.batterycare.daemon.conf` | New file: newsyslog rotation config |

## Out of Scope

- UI slider for `sleepWakeInterval` (future)
- Hardware-level charge limits (not functional on M4)
- Discharge feature
