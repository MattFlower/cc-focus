#!/bin/bash
set -e

APP_NAME="cc-focus"
INSTALL_DIR="$HOME/Applications"
PLIST_NAME="com.mflower.cc-focus"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SOCKET="/tmp/cc-focus-$(id -u).sock"
PID_FILE="/tmp/cc-focus-$(id -u).pid"

echo "=== cc-focus uninstaller ==="
echo ""

# 1. Stop running instance
if pgrep -f "$APP_NAME.app" >/dev/null 2>&1; then
    echo "Stopping cc-focus..."
    pkill -f "$APP_NAME.app" 2>/dev/null || true
    sleep 0.5
fi

# 2. Remove launch agent
if [ -f "$LAUNCH_PLIST" ]; then
    echo "Removing launch agent..."
    launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
    rm -f "$LAUNCH_PLIST"
fi

# 3. Remove installed app
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "Removing $INSTALL_DIR/$APP_NAME.app..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

# 4. Remove socket and PID file
rm -f "$SOCKET"
rm -f "$PID_FILE"

# 5. Remove hooks from settings.json
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/uninstall-hooks.sh"

echo ""
echo "=== Uninstall complete ==="
