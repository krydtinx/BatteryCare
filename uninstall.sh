#!/bin/bash
set -e

echo "==> Stopping and removing daemon..."
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist 2>/dev/null || true

echo "==> Re-enabling charging (in case daemon left it disabled)..."
if [ -f /Applications/BatteryCare.app/Contents/MacOS/battery-care-daemon ]; then
    # Send enableCharging command via socket if daemon is still running
    echo '{"type":"enableCharging"}' | nc -U /var/run/battery-care/daemon.sock 2>/dev/null || true
fi

echo "==> Removing app..."
sudo rm -rf /Applications/BatteryCare.app

echo "==> Removing settings and logs..."
sudo rm -rf "/Library/Application Support/BatteryCare"
sudo rm -rf /Library/Logs/BatteryCare
sudo rm -rf /var/run/battery-care

echo ""
echo "Done. BatteryCare has been uninstalled."
echo "Note: If charging is still disabled, compile and run debug-tools/reenable_charging.c as root."
