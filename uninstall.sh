#!/bin/bash
set -e

APP_NAME="cc-focus"
INSTALL_DIR="$HOME/Applications"
PLIST_NAME="com.mflower.cc-focus"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SOCKET="/tmp/cc-focus-501.sock"
SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/cc-focus-hook.sh"

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

# 4. Remove socket
rm -f "$SOCKET"

# 5. Remove hooks from settings.json
if [ -f "$SETTINGS" ]; then
    echo "Removing cc-focus hooks from Claude settings..."
    python3 << PYEOF
import json

settings_path = "$SETTINGS"
hook_script = "$HOOK_SCRIPT"

with open(settings_path, 'r') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
modified = False

for hook_key in list(hooks.keys()):
    for group in hooks[hook_key]:
        original_len = len(group.get('hooks', []))
        group['hooks'] = [h for h in group.get('hooks', []) if not (h.get('command', '').startswith(hook_script))]
        if len(group['hooks']) != original_len:
            modified = True

    # Remove empty groups
    hooks[hook_key] = [g for g in hooks[hook_key] if g.get('hooks')]

    # Remove empty hook keys
    if not hooks[hook_key]:
        del hooks[hook_key]
        modified = True

if modified:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    print("  Hooks removed.")
else:
    print("  No cc-focus hooks found.")
PYEOF
fi

echo ""
echo "=== Uninstall complete ==="
