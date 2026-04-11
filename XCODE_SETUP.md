# Xcode Manual Setup Steps

These steps must be done by hand in Xcode after the automated file setup.

## Step 1: Create Xcode Project

1. Open Xcode → File → New → Project → macOS → App
2. Settings:
   - Product Name: `BatteryCare`
   - Bundle Identifier: `com.batterycare.app`
   - Interface: SwiftUI
   - Language: Swift
   - Uncheck "Include Tests"
3. Save to `/Users/kridtin/workspace/battery-care/`

## Step 2: Add Daemon Target

1. File → New → Target → macOS → Command Line Tool
2. Product Name: `battery-care-daemon`
3. Language: Swift

## Step 3: Add Test Targets

1. File → New → Target → macOS → Unit Testing Bundle → Name: `DaemonTests`
2. File → New → Target → macOS → Unit Testing Bundle → Name: `AppTests`

## Step 4: Add BatteryCareShared Local Package

1. File → Add Package Dependencies → Add Local
2. Select: `/Users/kridtin/workspace/battery-care/Shared`
3. Add `BatteryCareShared` library to BOTH `BatteryCare` and `battery-care-daemon` targets

## Step 5: Disable App Sandbox

1. Select `BatteryCare` target → Signing & Capabilities
2. Remove "App Sandbox" capability (click X next to it)
3. Set Entitlements File to `App/BatteryCare.entitlements`

## Step 6: Configure Daemon Bridging Header (do when adding smc.c in Task 4)

1. Select `battery-care-daemon` target → Build Settings
2. Search "Objective-C Bridging Header"
3. Set to: `Daemon/Hardware/SMCBridgingHeader.h`

## Step 7: Bundle Daemon Plist (do when plist is created in Task 12)

1. Select `BatteryCare` app target → Build Phases
2. Add Copy Files phase → Destination: `Wrapper`, Subpath: `Contents/Library/LaunchDaemons`
3. Add: `com.batterycare.daemon.plist`
