#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="cc-focus"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
PLIST_NAME="com.mflower.cc-focus"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
INSTALL_DIR="$HOME/Applications"

echo "=== cc-focus installer ==="
echo ""

# 1. Build
echo "Building..."
bash "$SCRIPT_DIR/build.sh"
echo ""

# 2. Migrate: clean up old manual launchd agent and ~/Applications copy
if [ -f "$LAUNCH_PLIST" ]; then
    echo "Migrating: removing old launch agent..."
    launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
    rm -f "$LAUNCH_PLIST"
fi

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "Migrating: removing old ~/Applications/$APP_NAME.app..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

# 3. Kill existing instance if running
if pgrep -f "$APP_NAME.app" >/dev/null 2>&1; then
    echo "Stopping existing cc-focus..."
    pkill -f "$APP_NAME.app" 2>/dev/null || true
    sleep 0.5
fi

# 4. Install hooks
echo ""
bash "$SCRIPT_DIR/install-hooks.sh"

# Clean up local build artifacts
rm -rf "$APP_BUNDLE" "$SCRIPT_DIR/$APP_NAME"

echo ""
echo "=== Done ==="
echo ""
echo "  Hooks:  installed in ~/.claude/settings.json"
echo ""
echo "  To start cc-focus:"
echo "    brew services restart cc-focus"
echo ""
echo "  To uninstall:"
echo "    bash $SCRIPT_DIR/uninstall.sh"
