#!/bin/bash
set -e

SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/cc-focus-hook.sh}"

if [ ! -f "$SETTINGS" ]; then
    echo "No settings file found at $SETTINGS, nothing to remove."
    exit 0
fi

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
