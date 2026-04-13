#!/bin/bash
set -e

DERIVED_DATA=/tmp/BatteryCare-build
APP_SRC="$DERIVED_DATA/Build/Products/Release/BatteryCare.app"
APP_DEST="/Applications/BatteryCare.app"

echo "==> Building Release..."
xcodebuild \
    -project BatteryCare/BatteryCare.xcodeproj \
    -scheme BatteryCare \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"

echo "==> Stopping old daemon (if running)..."
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist 2>/dev/null || true

echo "==> Installing $APP_DEST..."
sudo rm -rf "$APP_DEST"
sudo ditto "$APP_SRC" "$APP_DEST"
sudo chown -R root:wheel "$APP_DEST"

echo "==> Stripping Gatekeeper provenance..."
sudo xattr -rc "$APP_DEST"

echo "==> Preparing settings directory..."
LOGGED_IN_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
sudo mkdir -p "/Library/Application Support/BatteryCare"
sudo chown "$LOGGED_IN_USER":staff "/Library/Application Support/BatteryCare"
sudo rm -f "/Library/Application Support/BatteryCare/settings.json"

echo "==> Launching app (registers daemon via SMAppService)..."
sudo -u "$LOGGED_IN_USER" open "$APP_DEST"

echo ""
echo "Done. Allow the background service prompt to start the daemon."
