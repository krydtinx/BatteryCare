# Battery Care MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that limits MacBook Pro M4 battery charge to any percentage (20–100%) using a privileged launchd daemon that writes SMC keys CH0B/CH0C.

**Architecture:** SwiftUI menu bar app (user space) communicates over a Unix Domain Socket with a root launchd daemon. The daemon owns all hardware access — it polls AppleSmartBattery IORegistry and writes SMC keys through a C bridge (smc.c from charlie0129/gosmc). All daemon state is protected by a Swift Actor; charging transitions are enforced by a State Machine; IPC uses typed Codable Commands over newline-delimited JSON.

**Tech Stack:** Swift 6, SwiftUI, Combine, IOKit, ServiceManagement (SMAppService), POSIX sockets, smc.c (C, GPL-2.0, charlie0129/gosmc), XCTest

---

## File Map

```
battery-care/
├── BatteryCare.xcworkspace
├── BatteryCare.xcodeproj               ← App + Daemon targets
│
├── App/                                ← Target: BatteryCare.app
│   ├── BatteryCareApp.swift            ← @main, NSStatusItem setup
│   ├── AppDelegate.swift               ← SMAppService install/uninstall, first-run checks
│   ├── Views/
│   │   ├── MenuBarView.swift           ← Popover root (gauge + controls)
│   │   ├── StatusIconView.swift        ← Menu bar icon, 4 states
│   │   └── OptimizedChargingBanner.swift
│   ├── ViewModels/
│   │   └── BatteryViewModel.swift      ← @MainActor ObservableObject
│   └── Services/
│       └── DaemonClient.swift          ← POSIX socket client, AsyncStream<StatusUpdate>
│
├── Daemon/                             ← Target: battery-care-daemon (Command Line Tool)
│   ├── main.swift                      ← Entry point, DI wiring, SIGPIPE ignore
│   ├── Core/
│   │   ├── DaemonCore.swift            ← actor DaemonCore + protocols
│   │   ├── ChargingStateMachine.swift
│   │   └── BatteryMonitor.swift        ← AppleSmartBattery IORegistry
│   ├── Hardware/
│   │   ├── SMCService.swift            ← Swift wrapper: open/probe/read/write/close
│   │   ├── SMCBridgingHeader.h         ← #include "ThirdParty/smc.h"
│   │   └── ThirdParty/
│   │       ├── smc.c                   ← from charlie0129/gosmc (GPL-2.0)
│   │       ├── smc.h
│   │       └── NOTICE
│   ├── Sleep/
│   │   └── SleepWatcher.swift          ← IOKit C callbacks → AsyncStream<SleepEvent>
│   ├── IPC/
│   │   └── SocketServer.swift          ← Unix socket listener + UID verification
│   └── Settings/
│       └── DaemonSettings.swift        ← Codable, JSON persist/load
│
├── Shared/                             ← Local Swift Package: BatteryCareShared
│   ├── Package.swift
│   └── Sources/BatteryCareShared/
│       ├── Command.swift               ← Command enum (Codable)
│       ├── StatusUpdate.swift          ← StatusUpdate struct + DaemonError enum
│       ├── ChargingState.swift
│       └── DaemonMode.swift
│
├── Tests/
│   ├── DaemonTests/
│   │   ├── ChargingStateMachineTests.swift
│   │   ├── DaemonCoreTests.swift
│   │   └── SocketServerFramingTests.swift
│   └── AppTests/
│       ├── CommandCodableTests.swift
│       └── BatteryViewModelTests.swift
│
└── Resources/
    └── Contents/Library/LaunchDaemons/
        └── com.batterycare.daemon.plist
```

---

## Task 1: Xcode Workspace + Project Setup

**Files:**
- Create: `BatteryCare.xcworkspace`
- Create: `BatteryCare.xcodeproj` (App + Daemon targets)
- Create: `Shared/Package.swift`

- [ ] **Step 1: Create the workspace folder and open Xcode**

```bash
cd /Users/kridtin/workspace/battery-care
mkdir -p App/Views App/ViewModels App/Services
mkdir -p Daemon/Core Daemon/Hardware/ThirdParty Daemon/Sleep Daemon/IPC Daemon/Settings
mkdir -p Shared/Sources/BatteryCareShared
mkdir -p Tests/DaemonTests Tests/AppTests
mkdir -p Resources/Contents/Library/LaunchDaemons
```

- [ ] **Step 2: Create Xcode project via Xcode GUI**

Open Xcode → File → New → Project → macOS → App.
- Product Name: `BatteryCare`
- Bundle Identifier: `com.batterycare.app`
- Interface: SwiftUI
- Language: Swift
- Uncheck "Include Tests" (we add test targets manually)
- Save to `/Users/kridtin/workspace/battery-care/`

This creates `BatteryCare.xcodeproj`. Move all generated app files into `App/`:
- In Xcode's Project Navigator: drag `BatteryCareApp.swift`, `ContentView.swift` into the `App` group.
- Delete `ContentView.swift` (not used).

- [ ] **Step 3: Add the Daemon command-line target**

In Xcode: File → New → Target → macOS → Command Line Tool.
- Product Name: `battery-care-daemon`
- Language: Swift
- Add to project: `BatteryCare`

Move the generated `main.swift` (stub) into `Daemon/` in the navigator.

- [ ] **Step 4: Create the BatteryCareShared local Swift package**

```bash
cd /Users/kridtin/workspace/battery-care/Shared
```

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryCareShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BatteryCareShared", targets: ["BatteryCareShared"])
    ],
    targets: [
        .target(name: "BatteryCareShared", path: "Sources/BatteryCareShared"),
        .testTarget(
            name: "BatteryCareSharedTests",
            dependencies: ["BatteryCareShared"],
            path: "../Tests/AppTests"
        )
    ]
)
```

- [ ] **Step 5: Add BatteryCareShared package to Xcode project**

In Xcode: File → Add Package Dependencies → Add Local → select `/Users/kridtin/workspace/battery-care/Shared`.
Add `BatteryCareShared` library to both the `BatteryCare` app target and `battery-care-daemon` target.

- [ ] **Step 6: Add test targets**

File → New → Target → macOS → Unit Testing Bundle.
- Name: `DaemonTests` → linked to `battery-care-daemon`
- Name: `AppTests` → linked to `BatteryCare`

Move generated test files into `Tests/DaemonTests/` and `Tests/AppTests/`.

- [ ] **Step 7: Configure App entitlements**

In Xcode: Select `BatteryCare` target → Signing & Capabilities → Add Capability → App Sandbox: **OFF** (SMC access requires no sandbox).

Create `App/BatteryCare.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.temporary-exception.shared-preference.read-write</key>
    <array>
        <string>com.batterycare</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 8: Verify the project builds (both targets)**

In Xcode: Product → Build (⌘B). Both `BatteryCare` and `battery-care-daemon` should compile with no errors.

Expected: Build Succeeded for both targets.

---

## Task 2: BatteryCareShared — Typed IPC Protocol

**Files:**
- Create: `Shared/Sources/BatteryCareShared/Command.swift`
- Create: `Shared/Sources/BatteryCareShared/StatusUpdate.swift`
- Create: `Shared/Sources/BatteryCareShared/ChargingState.swift`
- Create: `Shared/Sources/BatteryCareShared/DaemonMode.swift`

- [ ] **Step 1: Write ChargingState.swift**

```swift
// Shared/Sources/BatteryCareShared/ChargingState.swift
public enum ChargingState: String, Codable, Sendable {
    case charging       // below limit, actively charging — CH0B/CH0C = 0x00
    case limitReached   // at/above limit, charging paused — CH0B/CH0C = 0x02
    case idle           // unplugged
    case disabled       // user explicitly paused via .disableCharging command
}
```

- [ ] **Step 2: Write DaemonMode.swift**

```swift
// Shared/Sources/BatteryCareShared/DaemonMode.swift
// Phase 1 uses .normal only. Remaining cases are reserved for Phase 2-3.
public enum DaemonMode: String, Codable, Sendable {
    case normal       // standard charge-limit loop
    case discharging  // drain while plugged in (Phase 2)
    case topUp        // one-time charge to 100% then revert (Phase 3)
    case calibrating  // full cycle calibration (Phase 3)
}
```

- [ ] **Step 3: Write Command.swift with manual Codable**

Swift does not synthesize `Codable` for enums with associated values. Use a keyed container with a `"type"` discriminator field.

Wire format examples:
```json
{"type":"getStatus"}
{"type":"setLimit","percentage":80}
{"type":"setPollingInterval","seconds":5}
```

```swift
// Shared/Sources/BatteryCareShared/Command.swift
public enum Command: Sendable {
    case getStatus
    case setLimit(percentage: Int)        // clamped 20–100 by daemon
    case enableCharging
    case disableCharging
    case setPollingInterval(seconds: Int) // clamped 1–30 by daemon
}

extension Command: Codable {
    private enum CodingKeys: String, CodingKey { case type, percentage, seconds }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getStatus:
            try c.encode("getStatus", forKey: .type)
        case .setLimit(let p):
            try c.encode("setLimit", forKey: .type)
            try c.encode(p, forKey: .percentage)
        case .enableCharging:
            try c.encode("enableCharging", forKey: .type)
        case .disableCharging:
            try c.encode("disableCharging", forKey: .type)
        case .setPollingInterval(let s):
            try c.encode("setPollingInterval", forKey: .type)
            try c.encode(s, forKey: .seconds)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "getStatus":           self = .getStatus
        case "enableCharging":      self = .enableCharging
        case "disableCharging":     self = .disableCharging
        case "setLimit":
            self = .setLimit(percentage: try c.decode(Int.self, forKey: .percentage))
        case "setPollingInterval":
            self = .setPollingInterval(seconds: try c.decode(Int.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown command type: \(type)")
        }
    }
}
```

- [ ] **Step 4: Write StatusUpdate.swift**

```swift
// Shared/Sources/BatteryCareShared/StatusUpdate.swift
public enum DaemonError: String, Codable, Sendable {
    case smcConnectionFailed
    case smcKeyNotFound
    case smcWriteFailed
    case batteryReadFailed
}

public struct StatusUpdate: Codable, Sendable {
    public let currentPercentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let chargingState: ChargingState
    public let mode: DaemonMode
    public let limit: Int
    public let pollingInterval: Int
    public let error: DaemonError?
    public let errorDetail: String?   // e.g. which SMC key failed — nil when error is nil

    public init(
        currentPercentage: Int, isCharging: Bool, isPluggedIn: Bool,
        chargingState: ChargingState, mode: DaemonMode = .normal,
        limit: Int, pollingInterval: Int,
        error: DaemonError? = nil, errorDetail: String? = nil
    ) {
        self.currentPercentage = currentPercentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.chargingState = chargingState
        self.mode = mode
        self.limit = limit
        self.pollingInterval = pollingInterval
        self.error = error
        self.errorDetail = errorDetail
    }
}
```

- [ ] **Step 5: Write the Codable round-trip test**

```swift
// Tests/AppTests/CommandCodableTests.swift
import XCTest
import BatteryCareShared

final class CommandCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundtrip(_ command: Command) throws -> Command {
        let data = try encoder.encode(command)
        return try decoder.decode(Command.self, from: data)
    }

    func testGetStatusRoundtrip() throws {
        guard case .getStatus = try roundtrip(.getStatus) else {
            XCTFail("Expected .getStatus"); return
        }
    }

    func testSetLimitRoundtrip() throws {
        guard case .setLimit(let p) = try roundtrip(.setLimit(percentage: 75)) else {
            XCTFail("Expected .setLimit"); return
        }
        XCTAssertEqual(p, 75)
    }

    func testSetPollingIntervalRoundtrip() throws {
        guard case .setPollingInterval(let s) = try roundtrip(.setPollingInterval(seconds: 5)) else {
            XCTFail("Expected .setPollingInterval"); return
        }
        XCTAssertEqual(s, 5)
    }

    func testEnableChargingRoundtrip() throws {
        guard case .enableCharging = try roundtrip(.enableCharging) else {
            XCTFail("Expected .enableCharging"); return
        }
    }

    func testDisableChargingRoundtrip() throws {
        guard case .disableCharging = try roundtrip(.disableCharging) else {
            XCTFail("Expected .disableCharging"); return
        }
    }

    func testStatusUpdateRoundtrip() throws {
        let update = StatusUpdate(
            currentPercentage: 72, isCharging: true, isPluggedIn: true,
            chargingState: .charging, mode: .normal,
            limit: 80, pollingInterval: 3,
            error: nil, errorDetail: nil
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(StatusUpdate.self, from: data)
        XCTAssertEqual(decoded.currentPercentage, 72)
        XCTAssertEqual(decoded.chargingState, .charging)
        XCTAssertEqual(decoded.mode, .normal)
        XCTAssertNil(decoded.error)
    }

    func testStatusUpdateWithErrorRoundtrip() throws {
        let update = StatusUpdate(
            currentPercentage: 80, isCharging: false, isPluggedIn: true,
            chargingState: .limitReached, limit: 80, pollingInterval: 3,
            error: .smcWriteFailed, errorDetail: "CH0B"
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(StatusUpdate.self, from: data)
        XCTAssertEqual(decoded.error, .smcWriteFailed)
        XCTAssertEqual(decoded.errorDetail, "CH0B")
    }

    func testUnknownCommandThrows() {
        let data = Data(#"{"type":"unknown"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(Command.self, from: data))
    }
}
```

- [ ] **Step 6: Run the Codable tests**

In Xcode: Select `AppTests` scheme → ⌘U.

Expected: All 7 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/kridtin/workspace/battery-care
git init
git add Shared/ Tests/AppTests/CommandCodableTests.swift
git commit -m "Add BatteryCareShared IPC protocol types with Codable round-trip tests"
```

---

## Task 3: SMC C Layer

**Files:**
- Create: `Daemon/Hardware/ThirdParty/smc.c`
- Create: `Daemon/Hardware/ThirdParty/smc.h`
- Create: `Daemon/Hardware/ThirdParty/NOTICE`
- Create: `Daemon/Hardware/SMCBridgingHeader.h`

- [ ] **Step 1: Download smc.c and smc.h from charlie0129/gosmc**

```bash
cd /Users/kridtin/workspace/battery-care/Daemon/Hardware/ThirdParty

# Download the C SMC interface files from charlie0129/gosmc
curl -O https://raw.githubusercontent.com/charlie0129/gosmc/master/smc.c
curl -O https://raw.githubusercontent.com/charlie0129/gosmc/master/smc.h
```

Verify the files were downloaded:
```bash
ls -la
# Expected: smc.c (~25KB) and smc.h (~5KB)
head -5 smc.h
# Expected: copyright header from charlie0129
```

- [ ] **Step 2: Write the NOTICE file**

```bash
cat > NOTICE << 'EOF'
smc.c / smc.h
Source: https://github.com/charlie0129/gosmc
License: GPL-2.0

This code is used for personal, non-commercial use only.
Do not distribute binaries containing this code commercially.
To replace with a clean-room implementation, delete this ThirdParty/
directory and update SMCService.swift accordingly.
EOF
```

- [ ] **Step 3: Write SMCBridgingHeader.h**

```c
// Daemon/Hardware/SMCBridgingHeader.h
#ifndef SMCBridgingHeader_h
#define SMCBridgingHeader_h

#include "ThirdParty/smc.h"

#endif
```

- [ ] **Step 4: Add smc.c to the Daemon target in Xcode**

In Xcode Project Navigator:
1. Right-click `Daemon/Hardware/ThirdParty` group → Add Files.
2. Select `smc.c` and `smc.h`. Ensure `battery-care-daemon` is checked as the target.
3. In the daemon target's Build Settings → Swift Compiler — General → Objective-C Bridging Header: set to `Daemon/Hardware/SMCBridgingHeader.h`.

- [ ] **Step 5: Verify the C files compile in the daemon target**

⌘B. Expected: Build Succeeded. If you see "implicit function declaration" errors, check that the bridging header path is correct.

- [ ] **Step 6: Commit**

```bash
git add Daemon/Hardware/
git commit -m "Add SMC C layer from charlie0129/gosmc with GPL-2.0 NOTICE"
```

---

## Task 4: SMCService Swift Wrapper

**Files:**
- Create: `Daemon/Hardware/SMCService.swift`

- [ ] **Step 1: Write the SMCService protocol and implementation**

```swift
// Daemon/Hardware/SMCService.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "smc")

// MARK: - Types

public enum SMCWrite {
    case enableCharging   // CH0B + CH0C = 0x00
    case disableCharging  // CH0B + CH0C = 0x02
}

public enum SMCError: Error {
    case connectionFailed
    case keyNotFound(String)
    case writeFailed(String)
    case readFailed(String)
}

// MARK: - Protocol (injectable for testing)

public protocol SMCServiceProtocol {
    func open() throws
    func perform(_ write: SMCWrite) throws
    func read(key: String) throws -> Data
    func close()
}

// MARK: - Real Implementation

public final class SMCService: SMCServiceProtocol {
    private var conn = SMCConnection()
    private var activeChargingKey: String = "CH0B"

    public init() {}

    public func open() throws {
        guard SMCOpen(&conn) == KERN_SUCCESS else {
            throw SMCError.connectionFailed
        }
        activeChargingKey = probeChargingKey()
        logger.info("SMC open — active charging key: \(self.activeChargingKey)")
        logger.info("Firmware: \(firmwareVersion())")
    }

    /// Writes both CH0B and CH0C unconditionally. Individual write return codes are
    /// ignored because only one key exists on any given firmware revision. The
    /// read-back on activeChargingKey is the authoritative check.
    public func perform(_ write: SMCWrite) throws {
        let value: UInt8 = write == .enableCharging ? 0x00 : 0x02
        _ = smcWriteByte(&conn, "CH0B", value)
        _ = smcWriteByte(&conn, "CH0C", value)
        let result = try read(key: activeChargingKey)
        guard result.first == value else {
            throw SMCError.writeFailed(activeChargingKey)
        }
    }

    public func read(key: String) throws -> Data {
        var val = SMCVal_t()
        let keys = Array(key.utf8CString)
        withUnsafeMutablePointer(to: &val.key) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 5) { charPtr in
                _ = keys.withUnsafeBufferPointer { buf in
                    strcpy(charPtr, buf.baseAddress!)
                }
            }
        }
        guard SMCReadKey2(&conn, &val) == KERN_SUCCESS else {
            throw SMCError.readFailed(key)
        }
        return Data(bytes: &val.bytes, count: Int(val.dataSize))
    }

    public func close() {
        SMCClose(&conn)
    }

    // MARK: - Private helpers

    /// Probe which charging key this firmware honors. Reads current value of CH0B;
    /// if that fails try CH0C. Falls back to CH0B if neither read succeeds.
    private func probeChargingKey() -> String {
        if (try? read(key: "CH0B")) != nil { return "CH0B" }
        if (try? read(key: "CH0C")) != nil { return "CH0C" }
        logger.warning("Neither CH0B nor CH0C readable — defaulting to CH0B")
        return "CH0B"
    }

    private func firmwareVersion() -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n")
            .first(where: { $0.contains("Boot ROM Version") })?
            .trimmingCharacters(in: .whitespaces) ?? "unknown"
    }
}

// MARK: - C helper (write a single byte to an SMC key)

/// Writes a single UInt8 value to the given 4-character SMC key.
/// Returns the kern_return_t from SMCWriteKey2.
private func smcWriteByte(_ conn: inout SMCConnection, _ key: String, _ byte: UInt8) -> kern_return_t {
    var val = SMCVal_t()
    let keyBytes = Array(key.utf8CString)
    withUnsafeMutablePointer(to: &val.key) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 5) { charPtr in
            _ = keyBytes.withUnsafeBufferPointer { strcpy(charPtr, $0.baseAddress!) }
        }
    }
    withUnsafeMutablePointer(to: &val.dataType) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 5) { charPtr in
            strcpy(charPtr, "ui8 ")
        }
    }
    val.dataSize = 1
    val.bytes.0 = byte
    return SMCWriteKey2(&conn, &val)
}
```

> **Note on SMC C API:** `SMCConnection`, `SMCVal_t`, `SMCOpen`, `SMCClose`, `SMCReadKey2`, `SMCWriteKey2` are all declared in `smc.h`. Check `smc.h` after download — if the function names differ (e.g. `SMCWriteKey` instead of `SMCWriteKey2`), update the calls above to match.

- [ ] **Step 2: Build to verify compilation**

⌘B on `battery-care-daemon` target. Expected: Build Succeeded.

- [ ] **Step 3: Commit**

```bash
git add Daemon/Hardware/SMCService.swift
git commit -m "Add SMCService Swift wrapper with CH0B/CH0C probe and read-back verification"
```

---

## Task 5: Hardware Gate — Verify SMC Writes on M4

**Stop here and verify the SMC approach works on your physical machine before writing more code.**

- [ ] **Step 1: Pre-verify with batt (before any custom code)**

```bash
# Install and test batt to confirm CH0B approach works on your M4
brew install batt
sudo brew services start batt
sudo batt limit 80
sudo batt status
# Expected: "Charge limit: 80%" and charging stopped at 80%

# Clean up — batt MUST be fully removed before running our daemon
sudo brew services stop batt
sudo batt uninstall
brew uninstall batt

# Verify batt launchd entry is gone
launchctl print system | grep batt
# Expected: no output
```

- [ ] **Step 2: Write a throwaway SMC test binary**

Add a new macOS Command Line Tool target named `SMCTest` (temporary — delete after this task).

```swift
// SMCTest/main.swift
import Foundation

// This binary must be run as root: sudo ./SMCTest
let smc = SMCService()
do {
    try smc.open()
    print("SMC opened. Active charging key probe complete.")

    // Read current CH0B value
    let before = try smc.read(key: "CH0B")
    print("CH0B before: \(before.map { String(format: "%02x", $0) }.joined())")

    // Disable charging
    try smc.perform(.disableCharging)
    let afterDisable = try smc.read(key: "CH0B")
    print("CH0B after disableCharging: \(afterDisable.map { String(format: "%02x", $0) }.joined())")
    assert(afterDisable.first == 0x02, "Expected 0x02 after disableCharging")

    // Wait 3 seconds — check that charging actually stopped
    print("Waiting 3s — check that charging stopped in System Settings → Battery...")
    Thread.sleep(forTimeInterval: 3)

    // Re-enable charging
    try smc.perform(.enableCharging)
    let afterEnable = try smc.read(key: "CH0B")
    print("CH0B after enableCharging: \(afterEnable.map { String(format: "%02x", $0) }.joined())")
    assert(afterEnable.first == 0x00, "Expected 0x00 after enableCharging")

    smc.close()
    print("✓ SMC test passed — CH0B writes confirmed working on this M4")
} catch {
    print("✗ SMC test FAILED: \(error)")
    smc.close()
    exit(1)
}
```

- [ ] **Step 3: Build and run as root**

In Xcode: Build `SMCTest` target. Then:

```bash
sudo /path/to/DerivedData/.../SMCTest
# Expected output:
# SMC opened. Active charging key probe complete.
# CH0B before: 00
# CH0B after disableCharging: 02
# Waiting 3s...
# CH0B after enableCharging: 00
# ✓ SMC test passed — CH0B writes confirmed working on this M4
```

If this fails with `connectionFailed`, SIP may be blocking SMC access — verify `csrutil status` shows SIP is not fully enabled for SMC writes.

- [ ] **Step 4: Delete the SMCTest target**

In Xcode: Select `SMCTest` target → Delete. The `SMCTest/main.swift` file can be deleted too.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Verify SMC CH0B/CH0C writes work on M4 — hardware gate passed"
```

---

## Task 6: DaemonSettings (Persisted Configuration)

**Files:**
- Create: `Daemon/Settings/DaemonSettings.swift`

- [ ] **Step 1: Write DaemonSettings**

```swift
// Daemon/Settings/DaemonSettings.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "settings")

struct DaemonSettings: Codable {
    var limit: Int = 80
    var pollingInterval: Int = 3
    var isChargingDisabled: Bool = false  // persists .disabled state across daemon restarts
    var allowedUID: UInt32 = 501          // written by app during install; daemon enforces via LOCAL_PEERCRED

    // Phase 2+: var sailingLowerBound: Int = 20
    // Phase 3+: var heatProtectionEnabled: Bool = false
    // Phase 3+: var heatThreshold: Double = 35.0
}

extension DaemonSettings {
    static let settingsURL: URL = URL(filePath: "/Library/Application Support/BatteryCare/settings.json")

    static func load() -> DaemonSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(DaemonSettings.self, from: data) else {
            logger.info("No settings file found — using defaults")
            return DaemonSettings()
        }
        logger.info("Loaded settings: limit=\(settings.limit) interval=\(settings.pollingInterval) disabled=\(settings.isChargingDisabled)")
        return settings
    }

    func save() {
        do {
            let dir = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.settingsURL, options: .atomic)
        } catch {
            logger.error("Failed to save settings: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build daemon target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 3: Commit**

```bash
git add Daemon/Settings/DaemonSettings.swift
git commit -m "Add DaemonSettings with JSON persistence and disabled-state survival"
```

---

## Task 7: BatteryMonitor (AppleSmartBattery IORegistry)

**Files:**
- Create: `Daemon/Core/BatteryMonitor.swift`

- [ ] **Step 1: Write BatteryReading and BatteryMonitorProtocol**

```swift
// Daemon/Core/BatteryMonitor.swift
import Foundation
import IOKit
import IOKit.ps
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "battery")

// MARK: - Protocol

public protocol BatteryMonitorProtocol: Sendable {
    func read() throws -> BatteryReading
}

// MARK: - Reading struct

public struct BatteryReading: Sendable {
    public let percentage: Int    // 0–100 (CurrentCapacity * 100 / MaxCapacity)
    public let isCharging: Bool   // IsCharging key from IORegistry
    public let isPluggedIn: Bool  // ExternalConnected key from IORegistry
    // Phase 4 fields — populated now, used in Phase 4:
    public let cycleCount: Int
    public let designCapacity: Int  // mAh
    public let maxCapacity: Int     // mAh
    public let voltage: Double      // mV
    public let amperage: Double     // mA (negative = discharging)
}

// MARK: - Real implementation

public final class BatteryMonitor: BatteryMonitorProtocol {
    // Cache the service handle — avoids repeated IOServiceMatching on every poll
    private var serviceHandle: io_service_t = IO_OBJECT_NULL

    public init() {}

    public func read() throws -> BatteryReading {
        let props = try batteryProperties()
        guard
            let currentCap = props["CurrentCapacity"] as? Int,
            let maxCap = props["MaxCapacity"] as? Int,
            maxCap > 0
        else {
            throw BatteryMonitorError.missingProperty("CurrentCapacity/MaxCapacity")
        }

        let percentage = currentCap * 100 / maxCap
        let isCharging = (props["IsCharging"] as? Bool) ?? false
        let isPluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        let cycleCount = (props["CycleCount"] as? Int) ?? 0
        let designCap = (props["DesignCapacity"] as? Int) ?? 0
        let voltage = (props["Voltage"] as? Double) ?? 0
        let amperage = (props["Amperage"] as? Double) ?? 0

        return BatteryReading(
            percentage: min(100, max(0, percentage)),
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            cycleCount: cycleCount,
            designCapacity: designCap,
            maxCapacity: maxCap,
            voltage: voltage,
            amperage: amperage
        )
    }

    deinit {
        if serviceHandle != IO_OBJECT_NULL {
            IOObjectRelease(serviceHandle)
        }
    }

    // MARK: - Private

    private func batteryProperties() throws -> [String: Any] {
        // Re-use cached service handle if still valid
        if serviceHandle == IO_OBJECT_NULL {
            serviceHandle = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("AppleSmartBattery")
            )
        }
        guard serviceHandle != IO_OBJECT_NULL else {
            throw BatteryMonitorError.serviceNotFound
        }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(serviceHandle, &propertiesRef, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            // Release stale handle so next call re-matches
            IOObjectRelease(serviceHandle)
            serviceHandle = IO_OBJECT_NULL
            throw BatteryMonitorError.propertiesUnavailable
        }
        return props
    }
}

enum BatteryMonitorError: Error {
    case serviceNotFound
    case propertiesUnavailable
    case missingProperty(String)
}
```

- [ ] **Step 2: Build daemon target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 3: Quick manual smoke test**

Add a temporary `print(try BatteryMonitor().read())` call in `main.swift`, build, run without root:
```bash
./battery-care-daemon
# Expected: BatteryReading(percentage: 72, isCharging: true, isPluggedIn: true, ...)
```
Remove the test print afterward.

- [ ] **Step 4: Commit**

```bash
git add Daemon/Core/BatteryMonitor.swift
git commit -m "Add BatteryMonitor using AppleSmartBattery IORegistry"
```

---

## Task 8: ChargingStateMachine + Unit Tests

**Files:**
- Create: `Daemon/Core/ChargingStateMachine.swift`
- Create: `Tests/DaemonTests/ChargingStateMachineTests.swift`

- [ ] **Step 1: Write the failing tests first (TDD)**

```swift
// Tests/DaemonTests/ChargingStateMachineTests.swift
import XCTest
@testable import battery_care_daemon  // adjust module name to match target

final class ChargingStateMachineTests: XCTestCase {

    // MARK: - Transitions from .idle

    func testIdlePluggedInStartsCharging() {
        var sm = ChargingStateMachine(initialState: .idle)
        let write = sm.evaluate(percentage: 60, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .charging)
        XCTAssertEqual(write, .enableCharging)
    }

    func testIdleUnpluggedStaysIdle() {
        var sm = ChargingStateMachine(initialState: .idle)
        let write = sm.evaluate(percentage: 60, limit: 80, isPluggedIn: false)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(write)
    }

    // MARK: - Transitions from .charging

    func testChargingHitsLimitPausesCharging() {
        var sm = ChargingStateMachine(initialState: .charging)
        let write = sm.evaluate(percentage: 80, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .limitReached)
        XCTAssertEqual(write, .disableCharging)
    }

    func testChargingAboveLimitPausesCharging() {
        var sm = ChargingStateMachine(initialState: .charging)
        let write = sm.evaluate(percentage: 85, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .limitReached)
        XCTAssertEqual(write, .disableCharging)
    }

    func testChargingBelowLimitStaysCharging() {
        var sm = ChargingStateMachine(initialState: .charging)
        let write = sm.evaluate(percentage: 70, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .charging)
        XCTAssertNil(write)
    }

    func testChargingUnplugGoesIdle() {
        var sm = ChargingStateMachine(initialState: .charging)
        let write = sm.evaluate(percentage: 70, limit: 80, isPluggedIn: false)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(write)
    }

    // MARK: - Transitions from .limitReached

    func testLimitReachedDropsBelowResumesCharging() {
        var sm = ChargingStateMachine(initialState: .limitReached)
        let write = sm.evaluate(percentage: 79, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .charging)
        XCTAssertEqual(write, .enableCharging)
    }

    func testLimitReachedAtLimitStaysLimitReached() {
        var sm = ChargingStateMachine(initialState: .limitReached)
        let write = sm.evaluate(percentage: 80, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .limitReached)
        XCTAssertNil(write)
    }

    func testLimitReachedUnplugRestoresChargingAndGoesIdle() {
        var sm = ChargingStateMachine(initialState: .limitReached)
        let write = sm.evaluate(percentage: 80, limit: 80, isPluggedIn: false)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(write, .enableCharging)  // restore CH0B on unplug — fail-safe
    }

    // MARK: - .disabled state

    func testDisabledIgnoresAllEvaluations() {
        var sm = ChargingStateMachine(initialState: .disabled)
        let write = sm.evaluate(percentage: 60, limit: 80, isPluggedIn: true)
        XCTAssertEqual(sm.state, .disabled)
        XCTAssertNil(write)
    }

    func testForceDisableSetsStateAndReturnsSMCWrite() {
        var sm = ChargingStateMachine(initialState: .charging)
        let write = sm.forceDisable()
        XCTAssertEqual(sm.state, .disabled)
        XCTAssertEqual(write, .disableCharging)
    }

    func testForceEnableFromDisabledTransitionsCorrectly() {
        var sm = ChargingStateMachine(initialState: .disabled)
        // forceEnable returns nil — caller must re-evaluate against current battery
        sm.forceEnable()
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - No redundant writes

    func testStableStateProducesNoSMCWrite() {
        var sm = ChargingStateMachine(initialState: .charging)
        // Still below limit, still plugged in — no transition, no write
        let write = sm.evaluate(percentage: 70, limit: 80, isPluggedIn: true)
        XCTAssertNil(write)
    }
}
```

- [ ] **Step 2: Run — verify all tests FAIL**

⌘U on `DaemonTests`. Expected: All tests fail with "type not found" (ChargingStateMachine doesn't exist yet).

- [ ] **Step 3: Write the minimal implementation to make tests pass**

```swift
// Daemon/Core/ChargingStateMachine.swift
import BatteryCareShared

public struct ChargingStateMachine {
    public private(set) var state: ChargingState

    public init(initialState: ChargingState) {
        self.state = initialState
    }

    /// Evaluates current battery conditions against the charging limit.
    /// Returns the SMC write required for a state transition, or nil if no transition occurred.
    /// SMC writes happen ONLY on transitions — never on stable repeated evaluations.
    @discardableResult
    public mutating func evaluate(percentage: Int, limit: Int, isPluggedIn: Bool) -> SMCWrite? {
        switch (state, isPluggedIn, percentage >= limit) {
        case (.idle, true, _):
            state = .charging
            return .enableCharging

        case (.charging, true, true):
            state = .limitReached
            return .disableCharging

        case (.limitReached, true, false):
            state = .charging
            return .enableCharging

        case (.charging, false, _):
            state = .idle
            return nil

        case (.limitReached, false, _):
            state = .idle
            return .enableCharging  // restore charging on unplug — fail-safe

        case (.disabled, _, _):
            return nil  // disabled ignores all automatic transitions

        default:
            return nil  // no transition
        }
    }

    /// Directly sets state to .disabled and returns the SMC write to pause charging.
    /// Called when user sends .disableCharging command.
    @discardableResult
    public mutating func forceDisable() -> SMCWrite {
        state = .disabled
        return .disableCharging
    }

    /// Resets to .idle so the next evaluate() call determines the correct state.
    /// Called when user sends .enableCharging command.
    public mutating func forceEnable() {
        state = .idle
    }
}
```

- [ ] **Step 4: Run tests — verify all pass**

⌘U on `DaemonTests`. Expected: All 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Daemon/Core/ChargingStateMachine.swift Tests/DaemonTests/ChargingStateMachineTests.swift
git commit -m "Add ChargingStateMachine with full transition table and unit tests"
```

---

## Task 9: SleepWatcher (IOKit C/Swift Bridge)

**Files:**
- Create: `Daemon/Sleep/SleepWatcher.swift`

- [ ] **Step 1: Write SleepWatcher with the IOAllowPowerChange ack contract**

The C callback must call `IOAllowPowerChange` synchronously before yielding to Swift.
The `AsyncStream.Continuation.yield` is thread-safe and can be called from any thread.

```swift
// Daemon/Sleep/SleepWatcher.swift
import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "sleep")

public enum SleepEvent: Sendable {
    case willSleep
    case didWake
}

// MARK: - Context (heap-allocated, passed as refcon to IOKit C callback)

private final class SleepWatcherContext {
    let continuation: AsyncStream<SleepEvent>.Continuation
    var rootPort: io_connect_t = 0  // set after IORegisterForSystemPower

    init(_ continuation: AsyncStream<SleepEvent>.Continuation) {
        self.continuation = continuation
    }
}

// MARK: - C callback (must be @convention(c) — a global free function)
// IOAllowPowerChange MUST be called here, inside the C callback, before yielding.
// Missing this call causes macOS to force-sleep after ~30s regardless of what Swift does.

private let sleepWatcherCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
    guard let refcon else { return }
    let ctx = Unmanaged<SleepWatcherContext>.fromOpaque(refcon).takeUnretainedValue()

    switch messageType {
    case UInt32(kIOMessageSystemWillSleep):
        // Ack the sleep notification synchronously — required by IOKit contract
        IOAllowPowerChange(ctx.rootPort, Int(bitPattern: messageArgument))
        ctx.continuation.yield(.willSleep)
        logger.info("System will sleep — charged disabled")

    case UInt32(kIOMessageSystemHasPoweredOn):
        // Use HasPoweredOn (not WillPowerOn) — SMC keys are live at this point
        ctx.continuation.yield(.didWake)
        logger.info("System powered on — re-evaluating charge state")

    default:
        // For any other power management message, ack it immediately and ignore
        IOAllowPowerChange(ctx.rootPort, Int(bitPattern: messageArgument))
    }
}

// MARK: - Protocol

public protocol SleepWatcherProtocol: Sendable {
    var events: AsyncStream<SleepEvent> { get }
}

// MARK: - Real implementation

public final class SleepWatcher: SleepWatcherProtocol {
    public let events: AsyncStream<SleepEvent>

    // Retain these for lifetime management — must outlive any callback invocation
    private let contextRetain: Unmanaged<SleepWatcherContext>
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    public init() {
        var continuation: AsyncStream<SleepEvent>.Continuation!
        events = AsyncStream { continuation = $0 }

        let ctx = SleepWatcherContext(continuation)
        contextRetain = Unmanaged.passRetained(ctx)
        let rawPtr = contextRetain.toOpaque()

        var port: IONotificationPortRef?
        var notif: io_object_t = 0

        // IORegisterForSystemPower returns the root port for IOAllowPowerChange calls
        let rootPort = IORegisterForSystemPower(rawPtr, &port, sleepWatcherCallback, &notif)
        ctx.rootPort = rootPort
        notificationPort = port
        notifier = notif

        if let port {
            // Add the notification port's run loop source to the current run loop
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                .defaultMode
            )
        }
    }

    deinit {
        // Deregister before releasing the context — prevents use-after-free in callback
        IODeregisterForSystemPower(&notifier)
        if let port = notificationPort {
            IONotificationPortDestroy(port)
        }
        // Signal stream consumers to exit their for-await loop cleanly
        contextRetain.takeUnretainedValue().continuation.finish()
        // Release our retain on the context (no more callbacks will fire)
        contextRetain.release()
    }
}
```

- [ ] **Step 2: Build daemon target**

⌘B. Expected: Build Succeeded. If `IOServiceInterestCallback` has a different signature in your SDK headers, adjust the closure parameter names but keep the body identical.

- [ ] **Step 3: Wire the run loop in main.swift (temporary, will be replaced in Task 14)**

Add `RunLoop.main.run()` at the bottom of `main.swift` so the IOKit notification port has a run loop to deliver events. Remove this once the full `main.swift` is written in Task 14.

- [ ] **Step 4: Commit**

```bash
git add Daemon/Sleep/SleepWatcher.swift
git commit -m "Add SleepWatcher with IOAllowPowerChange ack contract and AsyncStream bridge"
```

---

## Task 10: SocketServer (Unix Socket + UID Verification + JSON Framing)

**Files:**
- Create: `Daemon/IPC/SocketServer.swift`
- Create: `Tests/DaemonTests/SocketServerFramingTests.swift`

- [ ] **Step 1: Write the failing framing tests first**

```swift
// Tests/DaemonTests/SocketServerFramingTests.swift
import XCTest
import BatteryCareShared

/// Tests the newline-delimited JSON framing logic independently of the socket.
/// Exercises: full lines, partial reads, multiple commands in one buffer, malformed JSON.
final class SocketServerFramingTests: XCTestCase {

    func testSingleCommandLine() throws {
        let input = Data(#"{"type":"getStatus"}"#.utf8 + [0x0A]) // 0x0A = \n
        let commands = try FramingParser.parse(input)
        XCTAssertEqual(commands.count, 1)
        guard case .getStatus = commands[0] else { XCTFail("Expected .getStatus"); return }
    }

    func testTwoCommandsInOneBuffer() throws {
        let raw = #"{"type":"getStatus"}"# + "\n" + #"{"type":"enableCharging"}"# + "\n"
        let commands = try FramingParser.parse(Data(raw.utf8))
        XCTAssertEqual(commands.count, 2)
        guard case .getStatus = commands[0] else { XCTFail(); return }
        guard case .enableCharging = commands[1] else { XCTFail(); return }
    }

    func testPartialLineProducesNoCommands() throws {
        let partial = Data(#"{"type":"getStatus"}"#.utf8)  // no trailing newline
        let commands = try FramingParser.parse(partial)
        XCTAssertEqual(commands.count, 0)
    }

    func testMalformedJSONLineIsDiscarded() throws {
        let raw = "not-valid-json\n"
        // Malformed lines are discarded — no throw, no command
        let commands = try FramingParser.parse(Data(raw.utf8))
        XCTAssertEqual(commands.count, 0)
    }

    func testSetLimitCommandParsed() throws {
        let raw = #"{"type":"setLimit","percentage":75}"# + "\n"
        let commands = try FramingParser.parse(Data(raw.utf8))
        XCTAssertEqual(commands.count, 1)
        guard case .setLimit(let p) = commands[0] else { XCTFail(); return }
        XCTAssertEqual(p, 75)
    }
}

/// Stateless framing helper — splits a buffer on newlines and decodes each line as a Command.
enum FramingParser {
    static func parse(_ data: Data) throws -> [Command] {
        let decoder = JSONDecoder()
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)  // 0x0A = \n
            .compactMap { lineData in
                try? decoder.decode(Command.self, from: Data(lineData))
            }
    }
}
```

- [ ] **Step 2: Run — verify tests fail**

⌘U on `DaemonTests`. Expected: `FramingParser` type not found.

- [ ] **Step 3: Write SocketServer (includes FramingParser)**

```swift
// Daemon/IPC/SocketServer.swift
import Foundation
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "socket")

// MARK: - Types

typealias ClientID = UUID

// MARK: - Framing

/// Stateless newline-delimited JSON parser. Splits a raw buffer on \n, decodes each line.
/// Malformed lines are silently discarded (logged). Partial lines (no trailing \n) produce no output.
enum FramingParser {
    static func parse(_ data: Data) -> [Command] {
        let decoder = JSONDecoder()
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { lineData -> Command? in
                guard let cmd = try? decoder.decode(Command.self, from: Data(lineData)) else {
                    logger.warning("Discarding malformed command: \(String(data: Data(lineData), encoding: .utf8) ?? "<binary>")")
                    return nil
                }
                return cmd
            }
    }
}

// MARK: - SocketServer

final class SocketServer {
    private let socketDir  = "/var/run/battery-care"
    private let socketPath = "/var/run/battery-care/daemon.sock"
    private var serverFD: Int32 = -1

    func start(core: DaemonCore) async throws {
        // Ignore SIGPIPE — write errors are caught as errno, not signals
        signal(SIGPIPE, SIG_IGN)

        try createSocketDirectory()
        serverFD = try bindAndListen()
        logger.info("SocketServer listening on \(self.socketPath)")

        // Accept loop — each connection gets its own Task
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                logger.error("accept() failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Verify client UID via getpeereid before handing off
            guard allowedUID(clientFD: clientFD, settings: await core.currentSettings()) else {
                logger.warning("Rejected connection from unauthorized UID")
                close(clientFD)
                continue
            }

            let id = ClientID()
            Task {
                await handleClient(id: id, fd: clientFD, core: core)
            }
        }
    }

    // MARK: - Private

    private func createSocketDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: socketDir) {
            try fm.createDirectory(atPath: socketDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
        }
        // Remove stale socket from a previous run
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }
    }

    private func bindAndListen() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socketFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 108) { strncpy($0, src, 107) }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.stride)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }
        guard bindResult == 0 else { close(fd); throw SocketError.bindFailed }

        // Restrict socket to root — any local user could otherwise send commands
        chmod(socketPath, 0o600)

        guard listen(fd, 5) == 0 else { close(fd); throw SocketError.listenFailed }
        return fd
    }

    private func allowedUID(clientFD: Int32, settings: DaemonSettings) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(clientFD, &uid, &gid) == 0 else { return false }
        return uid == settings.allowedUID
    }

    private func handleClient(id: ClientID, fd: Int32, core: DaemonCore) async {
        defer {
            close(fd)
            Task { await core.removeClient(id) }
            logger.info("Client \(id) disconnected")
        }

        // Register write stream with DaemonCore
        let stream = SocketStream(fd: fd)
        await core.addClient(id, stream: stream)

        // Send immediate snapshot so the app has fresh state on connect
        await core.sendSnapshot(to: id)

        // Read loop — decode commands and forward to actor
        var buffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }

        while true {
            let n = read(fd, readBuf, 4096)
            guard n > 0 else { break }  // n == 0 → EOF, n < 0 → error
            buffer.append(readBuf, count: n)

            for command in FramingParser.parse(buffer) {
                try? await core.handle(command, from: id)
            }

            // Keep only unprocessed bytes (everything after the last \n)
            if let lastNewline = buffer.lastIndex(of: 0x0A) {
                buffer = buffer[buffer.index(after: lastNewline)...]
                    .map { $0 }
                    .reduce(into: Data()) { $0.append($1) }
            }
        }
    }
}

// MARK: - SocketStream (write side — used by DaemonCore.broadcast)

final class SocketStream: @unchecked Sendable {
    private let fd: Int32
    private let encoder = JSONEncoder()

    init(fd: Int32) { self.fd = fd }

    /// Returns false if the write fails (broken pipe — caller should remove client)
    func send(_ update: StatusUpdate) -> Bool {
        guard var data = try? encoder.encode(update) else { return false }
        data.append(0x0A)  // trailing \n
        return data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, ptr.count) == ptr.count
        }
    }
}

enum SocketError: Error {
    case socketFailed, bindFailed, listenFailed
}
```

- [ ] **Step 4: Run framing tests — verify all pass**

⌘U on `DaemonTests`. Expected: All 5 framing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Daemon/IPC/SocketServer.swift Tests/DaemonTests/SocketServerFramingTests.swift
git commit -m "Add SocketServer with UID verification, JSON framing, and framing tests"
```

---

## Task 11: DaemonCore Actor + Unit Tests

**Files:**
- Create: `Daemon/Core/DaemonCore.swift`
- Create: `Tests/DaemonTests/DaemonCoreTests.swift`

- [ ] **Step 1: Write DaemonCoreTests with mock dependencies first**

```swift
// Tests/DaemonTests/DaemonCoreTests.swift
import XCTest
import BatteryCareShared
@testable import battery_care_daemon

// MARK: - Mocks

final class MockSMC: SMCServiceProtocol {
    var opened = false
    var closed = false
    var writes: [SMCWrite] = []
    var readResult: Data = Data([0x00])
    var shouldThrow = false

    func open() throws { if shouldThrow { throw SMCError.connectionFailed }; opened = true }
    func close() { closed = true }
    func perform(_ write: SMCWrite) throws {
        if shouldThrow { throw SMCError.writeFailed("CH0B") }
        writes.append(write)
    }
    func read(key: String) throws -> Data { readResult }
}

final class MockBatteryMonitor: BatteryMonitorProtocol {
    var reading = BatteryReading(percentage: 70, isCharging: true, isPluggedIn: true,
                                  cycleCount: 100, designCapacity: 5000, maxCapacity: 4800,
                                  voltage: 12400, amperage: -500)
    var shouldThrow = false
    func read() throws -> BatteryReading {
        if shouldThrow { throw BatteryMonitorError.serviceNotFound }
        return reading
    }
}

final class MockSleepWatcher: SleepWatcherProtocol {
    private var _continuation: AsyncStream<SleepEvent>.Continuation?
    let events: AsyncStream<SleepEvent>

    init() {
        var cont: AsyncStream<SleepEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        _continuation = cont
    }

    func send(_ event: SleepEvent) { _continuation?.yield(event) }
    func finish() { _continuation?.finish() }
}

// MARK: - Tests

final class DaemonCoreTests: XCTestCase {

    func makeSUT(limit: Int = 80, isChargingDisabled: Bool = false) -> (DaemonCore, MockSMC, MockBatteryMonitor, MockSleepWatcher) {
        var settings = DaemonSettings()
        settings.limit = limit
        settings.isChargingDisabled = isChargingDisabled
        let smc = MockSMC()
        let monitor = MockBatteryMonitor()
        let sleepWatcher = MockSleepWatcher()
        let core = DaemonCore(settings: settings, smc: smc, monitor: monitor, sleepWatcher: sleepWatcher)
        return (core, smc, monitor, sleepWatcher)
    }

    func testSetLimitCommandUpdatesSettings() async throws {
        let (core, smc, monitor, _) = makeSUT(limit: 80)
        monitor.reading = BatteryReading(percentage: 90, isCharging: false, isPluggedIn: true,
                                          cycleCount: 0, designCapacity: 5000, maxCapacity: 5000,
                                          voltage: 12000, amperage: 0)
        try await core.handle(.setLimit(percentage: 70), from: UUID())
        let settings = await core.currentSettings()
        XCTAssertEqual(settings.limit, 70)
        // Battery at 90% > new limit 70% — daemon should have disabled charging
        XCTAssertTrue(smc.writes.contains(.disableCharging))
    }

    func testSetLimitClampsBelow20() async throws {
        let (core, _, _, _) = makeSUT()
        try await core.handle(.setLimit(percentage: 10), from: UUID())
        let settings = await core.currentSettings()
        XCTAssertEqual(settings.limit, 20)
    }

    func testSetLimitClampsAbove100() async throws {
        let (core, _, _, _) = makeSUT()
        try await core.handle(.setLimit(percentage: 110), from: UUID())
        let settings = await core.currentSettings()
        XCTAssertEqual(settings.limit, 100)
    }

    func testDisableChargingPersistsState() async throws {
        let (core, smc, _, _) = makeSUT()
        try await core.handle(.disableCharging, from: UUID())
        let settings = await core.currentSettings()
        XCTAssertTrue(settings.isChargingDisabled)
        XCTAssertTrue(smc.writes.contains(.disableCharging))
    }

    func testEnableChargingClearsPersistenceFlag() async throws {
        let (core, _, _, _) = makeSUT(isChargingDisabled: true)
        try await core.handle(.enableCharging, from: UUID())
        let settings = await core.currentSettings()
        XCTAssertFalse(settings.isChargingDisabled)
    }

    func testSetPollingIntervalClampsBelow1() async throws {
        let (core, _, _, _) = makeSUT()
        try await core.handle(.setPollingInterval(seconds: 0), from: UUID())
        let settings = await core.currentSettings()
        XCTAssertEqual(settings.pollingInterval, 1)
    }

    func testSetPollingIntervalClampsAbove30() async throws {
        let (core, _, _, _) = makeSUT()
        try await core.handle(.setPollingInterval(seconds: 60), from: UUID())
        let settings = await core.currentSettings()
        XCTAssertEqual(settings.pollingInterval, 30)
    }
}
```

- [ ] **Step 2: Run — verify all tests fail**

⌘U on `DaemonTests`. Expected: `DaemonCore` type not found.

- [ ] **Step 3: Write DaemonCore**

```swift
// Daemon/Core/DaemonCore.swift
import Foundation
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.daemon", category: "core")

// MARK: - Protocols (declared here, implemented elsewhere)

public protocol SMCServiceProtocol: Sendable {
    func open() throws
    func perform(_ write: SMCWrite) throws
    func read(key: String) throws -> Data
    func close()
}

public protocol BatteryMonitorProtocol: Sendable {
    func read() throws -> BatteryReading
}

public protocol SleepWatcherProtocol: Sendable {
    var events: AsyncStream<SleepEvent> { get }
}

// MARK: - DaemonCore

public actor DaemonCore {
    private var settings: DaemonSettings
    private var stateMachine: ChargingStateMachine
    private let smc: any SMCServiceProtocol
    private let monitor: any BatteryMonitorProtocol
    private let sleepWatcher: any SleepWatcherProtocol
    private var connectedClients: [ClientID: SocketStream] = [:]
    private var lastBatteryReading: BatteryReading?

    public init(
        settings: DaemonSettings,
        smc: any SMCServiceProtocol,
        monitor: any BatteryMonitorProtocol,
        sleepWatcher: any SleepWatcherProtocol
    ) {
        self.settings = settings
        self.smc = smc
        self.monitor = monitor
        self.sleepWatcher = sleepWatcher
        self.stateMachine = ChargingStateMachine(initialState: .idle)  // seeded in run()
    }

    // MARK: - Entry point

    public func run() async throws {
        try smc.open()
        logger.info("DaemonCore started — limit=\(self.settings.limit) interval=\(self.settings.pollingInterval) disabled=\(self.settings.isChargingDisabled)")
        stateMachine = ChargingStateMachine(initialState: deriveInitialState())
        // Re-enforce SMC state on startup (Apple Silicon resets SMC on cold boot)
        if let write = currentSMCTarget() { try? smc.perform(write) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.runMonitorLoop() }
            group.addTask { await self.runSleepLoop() }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Client management (called by SocketServer)

    public func addClient(_ id: ClientID, stream: SocketStream) {
        connectedClients[id] = stream
        logger.info("Client \(id) connected (\(self.connectedClients.count) total)")
    }

    public func removeClient(_ id: ClientID) {
        connectedClients.removeValue(forKey: id)
        logger.info("Client \(id) removed (\(self.connectedClients.count) remaining)")
    }

    /// Sends the current StatusUpdate to a specific client only (used for .getStatus + on connect)
    public func sendSnapshot(to id: ClientID) {
        guard let stream = connectedClients[id], let reading = lastBatteryReading else { return }
        _ = stream.send(makeStatusUpdate(reading))
    }

    // MARK: - Command handling (called by SocketServer per received command)

    public func handle(_ command: Command, from clientID: ClientID) throws {
        switch command {
        case .getStatus:
            // Reply only to the requesting client — not a broadcast
            sendSnapshot(to: clientID)

        case .setLimit(let percentage):
            settings.limit = max(20, min(100, percentage))
            settings.save()
            reevaluateCharging()
            if let reading = lastBatteryReading { broadcast(makeStatusUpdate(reading)) }

        case .enableCharging:
            settings.isChargingDisabled = false
            settings.save()
            stateMachine.forceEnable()
            reevaluateCharging()
            if let reading = lastBatteryReading { broadcast(makeStatusUpdate(reading)) }

        case .disableCharging:
            let write = stateMachine.forceDisable()
            settings.isChargingDisabled = true
            settings.save()
            try smc.perform(write)
            if let reading = lastBatteryReading { broadcast(makeStatusUpdate(reading)) }

        case .setPollingInterval(let seconds):
            settings.pollingInterval = max(1, min(30, seconds))
            settings.save()
            if let reading = lastBatteryReading { broadcast(makeStatusUpdate(reading)) }
        }
    }

    public func currentSettings() -> DaemonSettings { settings }

    // MARK: - Monitor loop (internal tick = 1s; broadcasts every pollingInterval ticks)

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
                broadcast(makeErrorUpdate(.batteryReadFailed))
                continue  // fail-safe: keep current charging state
            }
            lastBatteryReading = battery

            let write = stateMachine.evaluate(
                percentage: battery.percentage,
                limit: settings.limit,
                isPluggedIn: battery.isPluggedIn
            )
            if let write {
                do {
                    try smc.perform(write)
                } catch let e as SMCError {
                    if case .writeFailed(let key) = e {
                        broadcast(makeErrorUpdate(.smcWriteFailed, detail: key))
                    } else {
                        broadcast(makeErrorUpdate(.smcWriteFailed))
                    }
                }
            }
            broadcast(makeStatusUpdate(battery))
        }
    }

    // MARK: - Sleep loop

    private func runSleepLoop() async {
        for await event in sleepWatcher.events {
            switch event {
            case .willSleep:
                // Disable charging before sleep — prevents creeping to 100% overnight
                // Do NOT update stateMachine state; wake re-evaluates from fresh battery reading
                try? smc.perform(.disableCharging)

            case .didWake:
                // SMC keys are live on HasPoweredOn. Wait 2s for hardware to stabilize.
                try? await Task.sleep(for: .seconds(2))
                guard let battery = try? monitor.read() else { continue }
                lastBatteryReading = battery
                let write = stateMachine.evaluate(
                    percentage: battery.percentage,
                    limit: settings.limit,
                    isPluggedIn: battery.isPluggedIn
                )
                if let write { try? smc.perform(write) }
                broadcast(makeStatusUpdate(battery))
            }
        }
    }

    // MARK: - Helpers

    private func deriveInitialState() -> ChargingState {
        // Persisted .disabled survives reboots and crashes
        if settings.isChargingDisabled { return .disabled }
        guard let battery = try? monitor.read() else { return .idle }
        lastBatteryReading = battery
        guard battery.isPluggedIn else { return .idle }
        return battery.percentage >= settings.limit ? .limitReached : .charging
    }

    /// Returns the SMC write that matches the current state machine state (for re-applying on startup)
    private func currentSMCTarget() -> SMCWrite? {
        switch stateMachine.state {
        case .charging:     return .enableCharging
        case .limitReached: return .disableCharging
        case .disabled:     return .disableCharging
        case .idle:         return nil
        }
    }

    private func reevaluateCharging() {
        guard let battery = lastBatteryReading else { return }
        let write = stateMachine.evaluate(
            percentage: battery.percentage,
            limit: settings.limit,
            isPluggedIn: battery.isPluggedIn
        )
        if let write { try? smc.perform(write) }
    }

    private func broadcast(_ update: StatusUpdate) {
        // Serialize writes to all clients sequentially under the actor — fine for 1–2 clients
        var toRemove: [ClientID] = []
        for (id, stream) in connectedClients {
            if !stream.send(update) { toRemove.append(id) }
        }
        toRemove.forEach { connectedClients.removeValue(forKey: $0) }
    }

    private func makeStatusUpdate(_ battery: BatteryReading, error: DaemonError? = nil, detail: String? = nil) -> StatusUpdate {
        StatusUpdate(
            currentPercentage: battery.percentage,
            isCharging: battery.isCharging,
            isPluggedIn: battery.isPluggedIn,
            chargingState: stateMachine.state,
            mode: .normal,
            limit: settings.limit,
            pollingInterval: settings.pollingInterval,
            error: error,
            errorDetail: detail
        )
    }

    private func makeErrorUpdate(_ error: DaemonError, detail: String? = nil) -> StatusUpdate {
        let battery = lastBatteryReading
        return StatusUpdate(
            currentPercentage: battery?.percentage ?? 0,
            isCharging: battery?.isCharging ?? false,
            isPluggedIn: battery?.isPluggedIn ?? false,
            chargingState: stateMachine.state,
            mode: .normal,
            limit: settings.limit,
            pollingInterval: settings.pollingInterval,
            error: error,
            errorDetail: detail
        )
    }
}
```

- [ ] **Step 4: Run DaemonCoreTests — verify all pass**

⌘U on `DaemonTests`. Expected: All 7 DaemonCore tests pass.

- [ ] **Step 5: Commit**

```bash
git add Daemon/Core/DaemonCore.swift Tests/DaemonTests/DaemonCoreTests.swift
git commit -m "Add DaemonCore actor with protocol injection, command handling, and unit tests"
```

---

## Task 12: Daemon main.swift + LaunchDaemon Plist

**Files:**
- Modify: `Daemon/main.swift`
- Create: `Resources/Contents/Library/LaunchDaemons/com.batterycare.daemon.plist`

- [ ] **Step 1: Write main.swift**

```swift
// Daemon/main.swift
import Foundation
import os.log

let logger = Logger(subsystem: "com.batterycare.daemon", category: "main")

// Ignore SIGPIPE — write failures to disconnected sockets return -1/EPIPE, not a signal crash
signal(SIGPIPE, SIG_IGN)

// Create /Library/Logs/BatteryCare if needed
let logDir = "/Library/Logs/BatteryCare"
try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

logger.info("battery-care-daemon starting")

// Wire up dependencies
let settings = DaemonSettings.load()
let smc = SMCService()
let monitor = BatteryMonitor()
let sleepWatcher = SleepWatcher()
let core = DaemonCore(settings: settings, smc: smc, monitor: monitor, sleepWatcher: sleepWatcher)
let socketServer = SocketServer()

// Run SocketServer on a background Task — DaemonCore.run() occupies the main Task
Task {
    do {
        try await socketServer.start(core: core)
    } catch {
        logger.critical("SocketServer failed: \(error) — exiting")
        exit(1)
    }
}

// Run the IOKit SleepWatcher on the main RunLoop (required for IOKit notifications)
// DaemonCore.run() is launched from a Task above; the main RunLoop pumps IOKit events
Task {
    do {
        try await core.run()
    } catch {
        logger.critical("DaemonCore exited with error: \(error) — exiting")
        exit(1)
    }
}

RunLoop.main.run()  // keeps the process alive and pumps IOKit notifications
```

- [ ] **Step 2: Write the LaunchDaemon plist**

```xml
<!-- Resources/Contents/Library/LaunchDaemons/com.batterycare.daemon.plist -->
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

- [ ] **Step 3: Add plist to App target in Xcode**

The plist must be bundled at `BatteryCare.app/Contents/Library/LaunchDaemons/`.
In Xcode: select `BatteryCare` app target → Build Phases → Copy Bundle Resources → add `com.batterycare.daemon.plist`.
Set the destination in Copy Files phase to `Wrapper/Contents/Library/LaunchDaemons/`.

- [ ] **Step 4: Build daemon target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
git add Daemon/main.swift Resources/
git commit -m "Add daemon entry point and LaunchDaemon plist"
```

---

## Task 13: AppDelegate + SMAppService Install Flow

**Files:**
- Create: `App/AppDelegate.swift`
- Modify: `App/BatteryCareApp.swift`

- [ ] **Step 1: Write AppDelegate**

```swift
// App/AppDelegate.swift
import AppKit
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "install")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let daemonPlist = "com.batterycare.daemon.plist"

    // MARK: - Daemon install/status

    var daemonStatus: SMAppService.Status {
        SMAppService.daemon(plistName: daemonPlist).status
    }

    /// Seeds initial settings.json with the current user's UID, then registers the daemon.
    /// Must be called BEFORE SMAppService.register() so the daemon reads the correct UID on first start.
    func installDaemon() throws {
        try seedInitialSettings()
        try SMAppService.daemon(plistName: daemonPlist).register()
        logger.info("Daemon registered via SMAppService")
    }

    func uninstallDaemon() throws {
        try SMAppService.daemon(plistName: daemonPlist).unregister()
        logger.info("Daemon unregistered")
    }

    // MARK: - Private

    /// Writes a minimal settings.json with allowedUID set to the current process's UID.
    /// This file is read by the daemon on its very first startup for LOCAL_PEERCRED verification.
    private func seedInitialSettings() throws {
        let settingsURL = URL(filePath: "/Library/Application Support/BatteryCare/settings.json")
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var settings = DaemonSettings()
        settings.allowedUID = getuid()
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        logger.info("Seeded settings.json with allowedUID=\(getuid())")
    }
}
```

> **Note:** `seedInitialSettings()` writes to `/Library/Application Support/BatteryCare/`. On first install this directory doesn't exist. The app may need to run with elevated privileges to create it, OR this write can be done by the daemon itself (which runs as root). If the write fails due to permissions, prompt the user to enter their admin password via an `NSAlert` and retry with `AuthorizationExecuteWithPrivileges` as a fallback.

- [ ] **Step 2: Wire AppDelegate into BatteryCareApp.swift**

```swift
// App/BatteryCareApp.swift
import SwiftUI

@main
struct BatteryCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = BatteryViewModel()

    var body: some Scene {
        MenuBarExtra("BatteryCare", systemImage: "battery.100") {
            MenuBarView(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Build App target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add App/AppDelegate.swift App/BatteryCareApp.swift
git commit -m "Add AppDelegate with SMAppService install/uninstall and UID seeding"
```

---

## Task 14: DaemonClient (Async Socket Client)

**Files:**
- Create: `App/Services/DaemonClient.swift`

- [ ] **Step 1: Write DaemonClient**

```swift
// App/Services/DaemonClient.swift
import Foundation
import BatteryCareShared
import os.log

private let logger = Logger(subsystem: "com.batterycare.app", category: "client")

final class DaemonClient: Sendable {
    private let socketPath = "/var/run/battery-care/daemon.sock"
    private let encoder = JSONEncoder()

    // MARK: - Status stream

    /// Connects to the daemon socket and returns an AsyncStream of StatusUpdates.
    /// The stream terminates when the socket closes (daemon stopped or crashed).
    /// Throws DaemonClientError.notInstalled if the socket file does not exist.
    func statusStream() throws -> AsyncStream<StatusUpdate> {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DaemonClientError.notInstalled
        }

        let fd = connectSocket()
        guard fd >= 0 else { throw DaemonClientError.connectionRefused }

        let decoder = JSONDecoder()
        return AsyncStream { continuation in
            Task {
                var buffer = Data()
                let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { readBuf.deallocate(); close(fd) }

                while true {
                    let n = read(fd, readBuf, 4096)
                    guard n > 0 else { break }

                    buffer.append(readBuf, count: n)

                    // Parse all complete lines (terminated by \n)
                    while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = Data(buffer[..<newlineIdx])
                        buffer = Data(buffer[buffer.index(after: newlineIdx)...])

                        if let update = try? decoder.decode(StatusUpdate.self, from: lineData) {
                            continuation.yield(update)
                        } else {
                            logger.warning("Discarding malformed StatusUpdate line")
                        }
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Send command

    func send(_ command: Command) async throws {
        let fd = connectSocket()
        guard fd >= 0 else { throw DaemonClientError.connectionRefused }
        defer { close(fd) }

        var data = try encoder.encode(command)
        data.append(0x0A)  // trailing \n
        try data.withUnsafeBytes { ptr in
            let written = write(fd, ptr.baseAddress!, ptr.count)
            guard written == ptr.count else { throw DaemonClientError.writeFailed }
        }
    }

    // MARK: - Private

    private func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 108) { strncpy($0, src, 107) }
            }
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }
}

enum DaemonClientError: Error {
    case notInstalled     // socket file doesn't exist
    case connectionRefused // socket exists but connect() failed
    case writeFailed
}
```

- [ ] **Step 2: Build App target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 3: Commit**

```bash
git add App/Services/DaemonClient.swift
git commit -m "Add DaemonClient with AsyncStream status updates and command sending"
```

---

## Task 15: BatteryViewModel + Unit Tests

**Files:**
- Create: `App/ViewModels/BatteryViewModel.swift`
- Create: `Tests/AppTests/BatteryViewModelTests.swift`

- [ ] **Step 1: Write the failing ViewModel tests first**

```swift
// Tests/AppTests/BatteryViewModelTests.swift
import XCTest
import BatteryCareShared
@testable import BatteryCare

final class MockDaemonClient: @unchecked Sendable {
    var statusUpdates: [StatusUpdate] = []
    var sentCommands: [Command] = []
    var throwOnStatusStream = false
    var throwNotInstalled = false

    func statusStream() throws -> AsyncStream<StatusUpdate> {
        if throwNotInstalled { throw DaemonClientError.notInstalled }
        if throwOnStatusStream { throw DaemonClientError.connectionRefused }
        var idx = 0
        let updates = statusUpdates
        return AsyncStream { continuation in
            Task {
                for update in updates {
                    continuation.yield(update)
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
        }
    }

    func send(_ command: Command) async throws {
        sentCommands.append(command)
    }
}

@MainActor
final class BatteryViewModelTests: XCTestCase {

    func testAppliesStatusUpdate() async throws {
        let client = MockDaemonClient()
        client.statusUpdates = [
            StatusUpdate(currentPercentage: 72, isCharging: true, isPluggedIn: true,
                         chargingState: .charging, limit: 80, pollingInterval: 3)
        ]
        let vm = BatteryViewModel(client: client)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.currentPercentage, 72)
        XCTAssertEqual(vm.chargingState, .charging)
        XCTAssertTrue(vm.isCharging)
        XCTAssertEqual(vm.connectionState, .disconnected) // stream finished
    }

    func testNotInstalledConnectionState() async throws {
        let client = MockDaemonClient()
        client.throwNotInstalled = true
        let vm = BatteryViewModel(client: client)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.connectionState, .notInstalled)
    }

    func testSetLimitSendsCommand() async throws {
        let client = MockDaemonClient()
        let vm = BatteryViewModel(client: client)
        vm.setLimit(75)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.limit, 75) // optimistic update
        guard case .setLimit(let p) = client.sentCommands.last else {
            XCTFail("Expected .setLimit command"); return
        }
        XCTAssertEqual(p, 75)
    }

    func testSetPollingIntervalSendsCommand() async throws {
        let client = MockDaemonClient()
        let vm = BatteryViewModel(client: client)
        vm.setPollingInterval(5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.pollingInterval, 5)
        guard case .setPollingInterval(let s) = client.sentCommands.last else {
            XCTFail("Expected .setPollingInterval command"); return
        }
        XCTAssertEqual(s, 5)
    }

    func testErrorFieldPopulatedFromStatusUpdate() async throws {
        let client = MockDaemonClient()
        client.statusUpdates = [
            StatusUpdate(currentPercentage: 70, isCharging: false, isPluggedIn: true,
                         chargingState: .limitReached, limit: 80, pollingInterval: 3,
                         error: .smcWriteFailed, errorDetail: "CH0B")
        ]
        let vm = BatteryViewModel(client: client)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.error, .smcWriteFailed)
        XCTAssertEqual(vm.errorDetail, "CH0B")
    }
}
```

- [ ] **Step 2: Run — verify tests fail**

⌘U on `AppTests`. Expected: `BatteryViewModel` not found.

- [ ] **Step 3: Write BatteryViewModel**

```swift
// App/ViewModels/BatteryViewModel.swift
import Foundation
import Combine
import BatteryCareShared
import ServiceManagement

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var currentPercentage: Int = 0
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false
    @Published var chargingState: ChargingState = .idle
    @Published var mode: DaemonMode = .normal
    @Published var limit: Int = 80
    @Published var pollingInterval: Int = 3
    @Published var connectionState: ConnectionState = .disconnected
    @Published var error: DaemonError? = nil
    @Published var errorDetail: String? = nil
    @Published var showOptimizedChargingWarning: Bool = false

    enum ConnectionState: Equatable {
        case connected
        case connecting
        case disconnected
        case notInstalled
    }

    private let client: DaemonClient

    init(client: DaemonClient = DaemonClient()) {
        self.client = client
        checkOptimizedCharging()
        Task { await connect() }
    }

    // MARK: - Public commands

    func setLimit(_ value: Int) {
        limit = value  // optimistic update
        Task { try? await client.send(.setLimit(percentage: value)) }
    }

    func setPollingInterval(_ value: Int) {
        pollingInterval = value
        Task { try? await client.send(.setPollingInterval(seconds: value)) }
    }

    func disableCharging() {
        Task { try? await client.send(.disableCharging) }
    }

    func enableCharging() {
        Task { try? await client.send(.enableCharging) }
    }

    // MARK: - Connection

    private func connect() async {
        connectionState = .connecting
        do {
            let stream = try client.statusStream()
            for await update in stream {
                apply(update)
                if connectionState != .connected { connectionState = .connected }
            }
            // Stream ended cleanly — daemon stopped or crashed
            connectionState = .disconnected
            await retryWithBackoff()
        } catch DaemonClientError.notInstalled {
            connectionState = .notInstalled
        } catch {
            connectionState = .disconnected
            await retryWithBackoff()
        }
    }

    private func retryWithBackoff() async {
        var delay: TimeInterval = 1.0
        while true {
            try? await Task.sleep(for: .seconds(delay))
            if FileManager.default.fileExists(atPath: "/var/run/battery-care/daemon.sock") {
                await connect()
                return
            }
            delay = min(delay * 2, 30.0)
        }
    }

    private func apply(_ update: StatusUpdate) {
        currentPercentage = update.currentPercentage
        isCharging = update.isCharging
        isPluggedIn = update.isPluggedIn
        chargingState = update.chargingState
        mode = update.mode
        limit = update.limit
        pollingInterval = update.pollingInterval
        error = update.error
        errorDetail = update.errorDetail
    }

    // MARK: - Optimized charging detection

    private func checkOptimizedCharging() {
        Task.detached(priority: .background) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let detected = output.lowercased().contains("optimized")
            await MainActor.run {
                self.showOptimizedChargingWarning = detected
            }
        }
    }
}
```

- [ ] **Step 4: Run BatteryViewModelTests — verify all pass**

⌘U on `AppTests`. Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/ViewModels/BatteryViewModel.swift Tests/AppTests/BatteryViewModelTests.swift
git commit -m "Add BatteryViewModel with MVVM reactive binding and unit tests"
```

---

## Task 16: Menu Bar UI

**Files:**
- Create: `App/Views/StatusIconView.swift`
- Create: `App/Views/MenuBarView.swift`
- Create: `App/Views/OptimizedChargingBanner.swift`

- [ ] **Step 1: Write StatusIconView (4 icon states)**

```swift
// App/Views/StatusIconView.swift
import SwiftUI
import BatteryCareShared

/// Returns the SF Symbol name for the current charging state / connection state.
struct StatusIconView: View {
    let chargingState: ChargingState
    let connectionState: BatteryViewModel.ConnectionState

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
    }

    private var iconName: String {
        switch connectionState {
        case .notInstalled, .disconnected:
            return "exclamationmark.triangle"
        case .connecting:
            return "battery.0"
        case .connected:
            switch chargingState {
            case .charging:     return "bolt.fill"
            case .limitReached: return "lock.fill"
            case .idle:         return "battery.100"
            case .disabled:     return "battery.100"
            }
        }
    }
}
```

- [ ] **Step 2: Write OptimizedChargingBanner**

```swift
// App/Views/OptimizedChargingBanner.swift
import SwiftUI

struct OptimizedChargingBanner: View {
    @Binding var isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Optimized Battery Charging is ON").font(.caption).bold()
                Spacer()
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("Disable it to allow BatteryCare to control your charge limit.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Open Battery Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!)
                isVisible = false
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }
}
```

- [ ] **Step 3: Write MenuBarView**

```swift
// App/Views/MenuBarView.swift
import SwiftUI
import BatteryCareShared

struct MenuBarView: View {
    @ObservedObject var vm: BatteryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if vm.showOptimizedChargingWarning {
                OptimizedChargingBanner(isVisible: $vm.showOptimizedChargingWarning)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            // Battery percentage display
            VStack(spacing: 4) {
                Text("\(vm.currentPercentage)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 12)

            // Charge limit slider
            VStack(spacing: 4) {
                HStack {
                    Text("Charge limit")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(vm.limit)%")
                        .font(.caption).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(vm.limit) },
                    set: { vm.setLimit(Int($0)) }
                ), in: 20...100, step: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Poll interval picker
            VStack(spacing: 4) {
                HStack {
                    Text("Update interval")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Picker("", selection: Binding(
                    get: { vm.pollingInterval },
                    set: { vm.setPollingInterval($0) }
                )) {
                    Text("1s").tag(1)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Charging control buttons
            HStack(spacing: 8) {
                Button(action: { vm.enableCharging() }) {
                    Label("Enable", systemImage: "bolt")
                }
                .disabled(vm.chargingState != .disabled)
                Button(action: { vm.disableCharging() }) {
                    Label("Pause", systemImage: "pause.circle")
                }
                .disabled(vm.chargingState == .disabled)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Error banner
            if let error = vm.error {
                Divider().padding(.horizontal, 12)
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage(error, detail: vm.errorDetail))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider().padding(.horizontal, 12)

            // Connection status + quit
            HStack {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Text(connectionLabel)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption2).buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: - Labels

    private var stateLabel: String {
        switch vm.connectionState {
        case .notInstalled: return "Daemon not installed"
        case .disconnected:  return "Daemon not running"
        case .connecting:    return "Connecting..."
        case .connected:
            switch vm.chargingState {
            case .charging:     return "Charging"
            case .limitReached: return "Limit reached — paused"
            case .idle:         return "Not plugged in"
            case .disabled:     return "Charging paused by user"
            }
        }
    }

    private var connectionLabel: String {
        switch vm.connectionState {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Disconnected"
        case .notInstalled: return "Not installed"
        }
    }

    private var connectionColor: Color {
        switch vm.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .orange
        case .notInstalled: return .red
        }
    }

    private func errorMessage(_ error: DaemonError, detail: String?) -> String {
        let base: String
        switch error {
        case .smcConnectionFailed: base = "SMC connection failed"
        case .smcKeyNotFound:      base = "SMC key not found — check firmware"
        case .smcWriteFailed:      base = "SMC write failed"
        case .batteryReadFailed:   base = "Battery read failed"
        }
        if let detail { return "\(base): \(detail)" }
        return base
    }
}
```

- [ ] **Step 4: Build App target**

⌘B. Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
git add App/Views/
git commit -m "Add menu bar UI: StatusIconView, MenuBarView, OptimizedChargingBanner"
```

---

## Task 17: End-to-End Verification

**Manual test sequence — no automated tests possible for hardware-dependent paths.**

- [ ] **Step 1: Build both targets in Release configuration**

In Xcode: Product → Scheme → Edit Scheme → Run → Build Configuration: Release.
⌘B. Expected: Both targets build with no warnings.

- [ ] **Step 2: Run daemon smoke test without UI**

```bash
# Build daemon
xcodebuild -target battery-care-daemon -configuration Release

# Locate built binary
DAEMON=$(find ~/Library/Developer/Xcode/DerivedData -name "battery-care-daemon" -type f | grep Release | head -1)
echo "Daemon at: $DAEMON"

# Run as root
sudo "$DAEMON" &
DAEMON_PID=$!
sleep 2

# Verify socket exists
ls -la /var/run/battery-care/daemon.sock
# Expected: srw------- (socket, 0600, root:wheel)

# Send getStatus command
echo '{"type":"getStatus"}' | nc -U /var/run/battery-care/daemon.sock
# Expected: JSON StatusUpdate line with current battery percentage

# Send setLimit
echo '{"type":"setLimit","percentage":85}' | nc -U /var/run/battery-care/daemon.sock
# Expected: StatusUpdate with limit:85

# Stop daemon
sudo kill $DAEMON_PID
```

- [ ] **Step 3: Install daemon via app**

1. Run `BatteryCare.app` in Xcode (⌘R).
2. The menu bar icon should appear with a warning (exclamation mark) — daemon not installed.
3. Implement and trigger the install flow (add an Install button to `MenuBarView` that calls `appDelegate.installDaemon()`).
4. System shows approval dialog — approve it.
5. Wait 3 seconds — menu bar icon should change to show current battery state.

- [ ] **Step 4: Verify charge limiting works end-to-end**

1. Note current battery %. Set limit to (current% - 5) using the slider.
2. Expected: charging pauses within one poll interval. Verify in `System Settings → Battery` that charging indicator stops.
3. Set limit back to 100%. Expected: charging resumes.

- [ ] **Step 5: Verify daemon persists across app quit**

1. Quit BatteryCare.app (Quit button in popover).
2. Open Activity Monitor — `battery-care-daemon` should still be running.
3. Verify limit is still enforced (battery doesn't charge past the set limit).

- [ ] **Step 6: Verify limit survives reboot**

1. Set limit to 80%, reboot.
2. After reboot, open BatteryCare.app — should show limit of 80% from persisted settings.
3. Verify charging stops at 80%.

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "Battery Care MVP complete — charge limiting, daemon persistence, SwiftUI app"
```

---

## Self-Review Against Spec

**Spec section coverage:**

| Spec Section | Covered By Task |
|---|---|
| Architecture / two-binary split | Tasks 1, 12 |
| IPC Protocol — Command enum | Task 2 |
| IPC Protocol — StatusUpdate | Task 2 |
| IPC Protocol — ChargingState, DaemonMode | Task 2 |
| Wire format (newline-delimited JSON) | Task 10 |
| Socket path + 0600 permissions | Task 10 |
| UID verification via getpeereid | Task 10 |
| SMC CH0B + CH0C dual write + probe | Tasks 3, 4 |
| SMC read path (Phase 3/4 ready) | Task 4 |
| Battery monitor (AppleSmartBattery) | Task 7 |
| ChargingStateMachine + full transition table | Task 8 |
| forceDisable / forceEnable | Task 8 |
| DaemonSettings persistence | Task 6 |
| isChargingDisabled persistence across restarts | Tasks 6, 11 |
| allowedUID in DaemonSettings | Tasks 6, 13 |
| DaemonCore actor with injected protocols | Task 11 |
| runMonitorLoop (1s tick, pollingInterval) | Task 11 |
| runSleepLoop (willSleep/didWake) | Tasks 9, 11 |
| IOAllowPowerChange ack contract | Task 9 |
| SleepWatcher C/Swift bridge + context lifetime | Task 9 |
| setLimit persistence flow (5 steps) | Task 11 |
| .getStatus → caller-only reply | Task 11 |
| Clamping (setLimit 20–100, setPollingInterval 1–30) | Task 11 |
| withThrowingTaskGroup (no async let) | Task 11 |
| deriveInitialState (checks isChargingDisabled first) | Task 11 |
| broadcast + broken-pipe client removal | Tasks 10, 11 |
| SIGPIPE ignore | Tasks 12, 14 |
| SMAppService install/uninstall | Task 13 |
| seedInitialSettings (allowedUID before register) | Task 13 |
| LaunchDaemon plist (all required keys) | Task 12 |
| DaemonClient AsyncStream | Task 14 |
| BatteryViewModel @MainActor MVVM | Task 15 |
| retryWithBackoff (exponential, 1→30s cap) | Task 15 |
| checkOptimizedCharging (pmset -g) | Task 15 |
| StatusIconView (4 icon states) | Task 16 |
| MenuBarView (slider, picker, error, connection) | Task 16 |
| OptimizedChargingBanner | Task 16 |
| os.Logger subsystem | Tasks 4, 9, 10, 11, 12 |
| Hardware gate (batt verify + cleanup) | Task 5 |
| End-to-end test | Task 17 |

All spec requirements are covered. No gaps found.
