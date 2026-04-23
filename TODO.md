# BatteryCare TODO

## Bugs / Reliability

- [x] **Fix uninstall.sh: enable charging before removing app**
  - Changed `enableCharging` → `setLimit(100)` (also persists 100% limit to settings.json)
  - Added `sleep 1` after socket send so daemon processes command before being killed
  - Added socket existence check; fallback to `debug-tools/reenable_charging` if socket is unavailable
  - App quit moved after socket send so `applicationWillTerminate` fires as a second safety net

- [x] **Enable charging when app quits**
  - `applicationWillTerminate(_:)` in `AppDelegate` calls `DaemonClient.shared.sendNow(.setLimit(percentage: 100))`
  - Added `sendNow()` synchronous variant to `DaemonClient`; `send()` delegates to it

- [x] **App crash when reducing upper limit below 21**
  - Fixed: MenuBarView sailing lower slider ensures range width ≥ 1 (min max=21)
  - Also clamps slider value to current limit in setter
  - Prevents SwiftUI zero-width range crash (20...20)
  
- [ ] **Sailing slider UI: lower bound visually "jumps" when reducing upper limit**
  - Current behavior: dragging charge limit down causes sailingLower to snap down due to daemon constraint
  - Why: Daemon enforces invariant `sailingLower ≤ limit`; UI reflects this via StatusUpdate
  - Design decision: This is correct behavior (UI in sync with daemon), not a bug
  - May improve UX by showing a visual indicator that lower is constrained by limit

- [x] **Sleep prevention not blocking over-charge when closing lid**
  - **FIXED: Scheduled maintenance wakes during sleep**
  - Root cause: When Mac sleeps, daemon suspends. SMC continues charging unchecked. No polling to stop at limit.
  - Solution: `IOPMSchedulePowerEvent` schedules dark (maintenance) wakes every N minutes during sleep
  - On each wake: daemon polls battery, re-evaluates state, corrects SMC if needed, returns to sleep
  - Cycle repeats until limit reached or user wakes Mac naturally
  - Implemented in Task 5 with comprehensive logging and error handling

## Features (from research plan)

- [x] Prevent idle sleep during active charging session (`IOPMAssertionCreateWithName`)
  - Prevents idle-sleep only during `.charging` state; released at `.limitReached`, `.idle`, or `.disabled`
  - `SleepAssertionManager` wraps `IOPMAssertionCreateWithName`/`IOPMAssertionRelease`
  - `DaemonCore` calls `acquire()`/`release()` in `applyState()` based on charging state
  - 5-second wake-retry to outlast powerd SMC re-initialization
- [x] **Restore limits on app reopen**
  - Saves limit + sailingLower to UserDefaults on quit (before setLimit(100))
  - Restores both on first daemon reconnect; clears keys immediately to prevent re-restore on mid-session daemon restart
- [ ] Discharge feature (drain to target % while plugged in — `AC-W` / `CH0I` SMC keys)
- [x] Sailing mode (lower bound to prevent micro-charge/discharge cycling)
  - Hysteresis state machine: battery < lower → charge to upper; in zone → stay in current direction
  - setSailingLower command; sailingLower persisted in settings.json (default=limit, old behaviour preserved)
  - MenuBarView: sailing lower slider with range 20...limit
  - Settings migration: custom Codable decoder handles pre-sailingLower settings.json
- [ ] Heat protection (pause charging when battery temp > threshold, `TB0T` key)
- [ ] Top Up (one-time charge-to-100% override, auto-reverts on unplug)
- [ ] Calibration mode (full cycle: current → 100% → 10% → 100% → hold)
- [ ] Schedule (cron-style: set limit, top up, discharge on timer)
- [x] **Hardware battery % (raw BMS reading, more accurate than macOS-reported %)**
  - Battery Detail Panel: expandable section in menu bar popover showing 7 stats
  - Raw %, cycle count, health %, max capacity, design capacity, temperature, voltage
  - Reads from IORegistry AppleSmartBattery; refreshes on same polling interval
  - BatteryDetail struct (Codable, Equatable) flows through daemon → app via StatusUpdate
- [ ] Apple Shortcuts integration (AppIntents)
- [ ] **Settings Menu**
  - Sleep prevention interval (configurable duration for idle sleep prevention)
  - Color theme (light/dark/system appearance)
  - Move check interval inside settings (polling interval configuration)
