#!/bin/bash
set -e

echo "==> Re-enabling charging (before stopping daemon)..."
echo '{"type":"enableCharging"}' | nc -U /var/run/battery-care/daemon.sock 2>/dev/null || true

echo "==> Quitting app..."
osascript -e 'quit app "BatteryCare"' 2>/dev/null || true
sleep 1

echo "==> Stopping daemon..."
sudo launchctl bootout system /Library/LaunchDaemons/com.batterycare.daemon.plist 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.batterycare.daemon.plist

echo "==> Removing app..."
sudo rm -rf /Applications/BatteryCare.app

echo "==> Removing settings and logs..."
sudo rm -rf "/Library/Application Support/BatteryCare"
sudo rm -rf /Library/Logs/BatteryCare
sudo rm -rf /var/run/battery-care

echo ""
echo "Done. BatteryCare has been uninstalled."
echo "Note: If charging is still disabled, compile and run debug-tools/reenable_charging.c as root."
