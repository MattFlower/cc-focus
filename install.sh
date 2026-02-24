#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="cc-focus"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
SOCKET="/tmp/cc-focus-$(id -u).sock"

echo "=== cc-focus installer ==="
echo ""

# 1. Build
echo "Building..."
bash "$SCRIPT_DIR/build.sh"
echo ""

# 2. Kill existing instance if running
if pgrep -f "$APP_NAME.app" >/dev/null 2>&1; then
    echo "Stopping existing cc-focus..."
    pkill -f "$APP_NAME.app" 2>/dev/null || true
    sleep 0.5
fi

# 3. Install app to ~/Applications
echo "Installing to $INSTALL_DIR/$APP_NAME.app..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INSTALL_DIR/$APP_NAME.app"

# Clean up local build artifacts to avoid launching the wrong copy
rm -rf "$APP_BUNDLE" "$SCRIPT_DIR/$APP_NAME"

# 4. Install hooks
echo ""
bash "$SCRIPT_DIR/install-hooks.sh"

# 5. Set up login item (launch at login via launchd)
PLIST_NAME="com.mflower.cc-focus"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo ""
echo "Setting up launch at login..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>$INSTALL_DIR/$APP_NAME.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

# Load the launch agent (unload first if already loaded)
launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
launchctl load "$LAUNCH_PLIST"

# 6. Launch
echo "Launching cc-focus..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "=== Done ==="
echo ""
echo "  App installed:  $INSTALL_DIR/$APP_NAME.app"
echo "  Launch agent:   $LAUNCH_PLIST"
echo "  Hooks:          installed in ~/.claude/settings.json"
echo ""
echo "  cc-focus will start automatically at login."
echo "  To uninstall:   bash $SCRIPT_DIR/uninstall.sh"
