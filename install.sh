#!/bin/bash
set -e

DERIVED_DATA=~/BatteryCare-build
APP_SRC="$DERIVED_DATA/Build/Products/Release/BatteryCare.app"
APP_DEST="/Applications/BatteryCare.app"
PLIST_SRC="$APP_DEST/Contents/Library/LaunchDaemons/com.batterycare.daemon.plist"
PLIST_DEST="/Library/LaunchDaemons/com.batterycare.daemon.plist"
SETTINGS_DIR="/Library/Application Support/BatteryCare"

echo "==> Building Release..."
xcodebuild \
    -project BatteryCare/BatteryCare.xcodeproj \
    -scheme BatteryCare \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Stopping old daemon (if running)..."
sudo launchctl bootout system "$PLIST_DEST" 2>/dev/null || true

echo "==> Installing $APP_DEST..."
sudo rm -rf "$APP_DEST"
sudo ditto "$APP_SRC" "$APP_DEST"
sudo chown -R root:wheel "$APP_DEST"

echo "==> Stripping Gatekeeper provenance..."
sudo xattr -rc "$APP_DEST"

echo "==> Seeding settings.json..."
LOGGED_IN_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER")
sudo mkdir -p "$SETTINGS_DIR"
sudo chown "$LOGGED_IN_USER":staff "$SETTINGS_DIR"
sudo tee "$SETTINGS_DIR/settings.json" > /dev/null <<EOF
{"limit":80,"allowedUID":$LOGGED_IN_UID,"pollingInterval":5,"isChargingDisabled":false}
EOF

echo "==> Installing daemon plist..."
sudo cp "$PLIST_SRC" "$PLIST_DEST"
sudo chown root:wheel "$PLIST_DEST"
sudo chmod 644 "$PLIST_DEST"

echo "==> Starting daemon..."
sudo launchctl bootstrap system "$PLIST_DEST"

echo "==> Launching app..."
sudo -u "$LOGGED_IN_USER" open "$APP_DEST"

echo ""
echo "Done."
