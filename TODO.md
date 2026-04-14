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
  - Fixed: MenuBarView sailing lower slider now clamps value to limit in setter
  - Prevents SwiftUI crash when range becomes invalid during constraint updates
  
- [ ] **Sailing slider UI: lower bound visually "jumps" when reducing upper limit**
  - Current behavior: dragging charge limit down causes sailingLower to snap down due to daemon constraint
  - Why: Daemon enforces invariant `sailingLower ≤ limit`; UI reflects this via StatusUpdate
  - Design decision: This is correct behavior (UI in sync with daemon), not a bug
  - May improve UX by showing a visual indicator that lower is constrained by limit

## Features (from research plan)

- [x] Prevent idle sleep during active charging session (`IOPMAssertionCreateWithName`)
  - Prevents idle-sleep only during `.charging` state; released at `.limitReached`, `.idle`, or `.disabled`
  - `SleepAssertionManager` wraps `IOPMAssertionCreateWithName`/`IOPMAssertionRelease`
  - `DaemonCore` calls `acquire()`/`release()` in `applyState()` based on charging state
  - 5-second wake-retry to outlast powerd SMC re-initialization
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
- [ ] Hardware battery % (raw BMS reading, more accurate than macOS-reported %)
- [ ] Apple Shortcuts integration (AppIntents)
