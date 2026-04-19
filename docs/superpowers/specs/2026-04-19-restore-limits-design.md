# Restore Limits on App Reopen

**Date:** 2026-04-19  
**Status:** Approved

## Problem

When the app quits, `applicationWillTerminate` sends `setLimit(100)` to re-enable charging. The daemon persists `limit=100, sailingLower=100` to `settings.json`. On reopen, the daemon reports these 100% values and the user's real limits are gone.

## Goal

Save the user's charge limit and sailing lower bound before resetting to 100% on quit. Restore them automatically on the next app launch.

## Approach

App-side `UserDefaults`. No daemon changes, no new IPC commands, no `Shared` package changes.

## Changes

### 1. `AppDelegate.applicationWillTerminate`

Before calling `sendNow(.setLimit(100))`, write the current limits to `UserDefaults.standard`:

- Key `com.batterycare.savedLimit` → `viewModel.limit`
- Key `com.batterycare.savedSailingLower` → `viewModel.sailingLower`

### 2. `BatteryViewModel.bindClient` — new `restoreLimitsIfNeeded()`

In the `connectedPublisher` subscriber, when `connected == true`, call:

```swift
private func restoreLimitsIfNeeded() {
    let defaults = UserDefaults.standard
    guard let savedLimit = defaults.object(forKey: "com.batterycare.savedLimit") as? Int,
          let savedSailingLower = defaults.object(forKey: "com.batterycare.savedSailingLower") as? Int
    else { return }
    defaults.removeObject(forKey: "com.batterycare.savedLimit")
    defaults.removeObject(forKey: "com.batterycare.savedSailingLower")
    Task { await client.send(.setLimit(percentage: savedLimit)) }
    Task { await client.send(.setSailingLower(percentage: savedSailingLower)) }
}
```

Keys are cleared immediately after reading so daemon restarts mid-session don't re-restore.

Restoring on connect (not on first `StatusUpdate`) avoids a brief UI flash of 100%.

## Edge Cases

| Scenario | Behaviour |
|---|---|
| App crashes | `applicationWillTerminate` not called → UserDefaults empty → no restore needed (daemon still has real limits) |
| Daemon restarts mid-session | UserDefaults already cleared after first restore → no re-restore |
| User quits at limit=100 intentionally | Saves 100 → restores 100 → harmless no-op |
| `sailingLower == limit` (no sailing zone) | Both values saved and restored → sailing zone preserved |

## Files Changed

| File | Change |
|---|---|
| `BatteryCare/BatteryCare/AppDelegate.swift` | Save limits to UserDefaults before sendNow(.setLimit(100)) |
| `BatteryCare/BatteryCare/ViewModels/BatteryViewModel.swift` | Add `restoreLimitsIfNeeded()`, call on connect |
