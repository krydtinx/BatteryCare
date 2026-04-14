# Idle Sleep Prevention During Active Charging

**Date:** 2026-04-14  
**Status:** Approved

---

## Overview

Prevent macOS idle-sleep while the daemon is actively charging the battery toward the configured limit. Release the assertion immediately when charging stops (limit reached, unplugged, or charging disabled).

---

## Problem

When a user plugs in their MacBook and a charge session begins, macOS may idle-sleep the system before the battery reaches the configured limit. This interrupts the charging session unnecessarily. Conversely, keeping the system awake once the limit is reached wastes power and prevents normal sleep behavior.

---

## Decision: Assert Only During `.charging` State

| State | Assertion | Reason |
|-------|-----------|--------|
| `.charging` | **Active** | Actively pulling power from adapter into battery |
| `.limitReached` | Released | At limit, adapter still powers system, no need to stay awake |
| `.idle` | Released | Unplugged — conserve battery, allow normal sleep |
| `.disabled` | Released | User explicitly disabled charging — don't interfere |

**Assertion type:** `kIOPMAssertionTypePreventUserIdleSystemSleep`  
- Blocks automatic idle-sleep timer  
- Does NOT block lid-close sleep (clamshell)  
- Does NOT block user-initiated sleep (Cmd-Option-Eject)  
- Screen can still dim/sleep independently  

---

## Architecture

### New Component: `SleepAssertionManager`

A small, focused type responsible only for acquiring and releasing a single IOKit power assertion.

**File:** `BatteryCare/battery-care-daemon/Power/SleepAssertionManager.swift`

```
SleepAssertionProtocol
  + acquire() -> Void
  + release() -> Void

SleepAssertionManager : SleepAssertionProtocol
  - assertionID: IOPMAssertionID
  + acquire()   // IOPMAssertionCreateWithName
  + release()   // IOPMAssertionRelease
  + deinit      // safety release

MockSleepAssertion : SleepAssertionProtocol   (test target only)
  - isActive: Bool
```

### Integration in `DaemonCore`

`DaemonCore` receives a `SleepAssertionProtocol` via constructor injection (alongside existing dependencies). It tracks the previous charging state and calls `acquire()`/`release()` on transitions in `applyState()`:

```
previous state != .charging, new state == .charging  →  acquire()
previous state == .charging, new state != .charging  →  release()
```

`applyState()` is already called on every state change (poll tick, sleep/wake, command handler), so no additional call sites are needed.

The assertion is also released when `DaemonCore.run()` exits (task cancellation / daemon shutdown).

---

## Data Flow

```
pollingLoop / sleepLoop / handle(command)
    └── stateMachine.evaluate(...)
    └── applyState()
            ├── smc.perform(...)          (existing)
            ├── socketServer.broadcast()  (existing)
            └── updateSleepAssertion()    (new)
                    ├── .charging   → sleepAssertion.acquire()
                    └── otherwise   → sleepAssertion.release()
```

---

## Error Handling

- `IOPMAssertionCreateWithName` returns `kIOReturnSuccess` on success. Log a warning on failure; do not crash — charging control continues unaffected.
- `acquire()` is idempotent: if an assertion ID is already held, skip the IOKit call (no leak, no double-acquire).
- `release()` is idempotent: no-op if no assertion is held.
- `deinit` calls `release()` as a safety net for unexpected teardown.

---

## Testing

`DaemonCoreTests` injects `MockSleepAssertion`. Tests verify:

1. Assertion acquired when state transitions to `.charging`
2. Assertion released when state transitions from `.charging` to `.limitReached`
3. Assertion released when state transitions from `.charging` to `.idle` (unplug)
4. Assertion released when state transitions from `.charging` to `.disabled`
5. Assertion not acquired in `.limitReached`, `.idle`, or `.disabled` states
6. Assertion released on daemon shutdown

---

## Out of Scope

- No user-facing toggle (configurable in a future iteration if needed)
- No display-sleep prevention (only system idle-sleep)
- Lid-close behavior unchanged — `kIOPMAssertionTypePreventUserIdleSystemSleep` does not block clamshell sleep
