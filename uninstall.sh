#!/bin/bash
set -e

echo "==> Re-enabling charging (before stopping daemon)..."
# Use setLimit(100) so the daemon also persists the 100% limit to settings.json.
# If the daemon is restarted later it won't re-apply a stale low limit.
SOCKET=/var/run/battery-care/daemon.sock
if [ -S "$SOCKET" ]; then
    echo '{"type":"setLimit","percentage":100}' | nc -U "$SOCKET" 2>/dev/null || true
    sleep 1  # give daemon time to process before we kill it
else
    echo "  Socket not found — daemon may already be stopped."
    # Fallback: re-enable charging directly via the debug tool if available
    REENABLE="$(dirname "$0")/debug-tools/reenable_charging"
    if [ -x "$REENABLE" ]; then
        echo "  Running reenable_charging fallback..."
        sudo "$REENABLE" || true
    fi
fi

echo "==> Quitting app (will also send setLimit(100) via applicationWillTerminate)..."
osascript -e 'quit app "BatteryCare"' 2>/dev/null || true
pkill -x BatteryCare 2>/dev/null || true
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
