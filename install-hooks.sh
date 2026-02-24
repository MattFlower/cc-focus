#!/bin/bash
set -e

SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/cc-focus-hook.sh"

if [ ! -f "$SETTINGS" ]; then
    echo "Error: $SETTINGS not found"
    exit 1
fi

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "Error: $HOOK_SCRIPT not found"
    exit 1
fi

# Backup
BACKUP="$SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Backed up settings to: $BACKUP"

python3 << PYEOF
import json
import sys

settings_path = "$SETTINGS"
hook_script = "$HOOK_SCRIPT"

with open(settings_path, 'r') as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})

# Define the hooks to add
# Format: (hook_key, matcher_or_none, event_type_arg)
hook_defs = [
    ('SessionStart', None, 'session_start'),
    ('SessionEnd', None, 'session_end'),
    ('UserPromptSubmit', None, 'user_prompt'),
    ('PreToolUse', None, 'pre_tool_use'),
    ('Notification', 'idle_prompt', 'idle_prompt'),
    ('Notification', 'permission_prompt', 'permission_prompt'),
]

for hook_key, matcher, event_arg in hook_defs:
    command = f"{hook_script} {event_arg}"
    new_hook_entry = {"type": "command", "command": command}

    if hook_key not in hooks:
        hooks[hook_key] = []

    # Find existing matcher group or create new one
    found = False
    for group in hooks[hook_key]:
        group_matcher = group.get('matcher')
        if group_matcher == matcher:
            # Check if our hook command already exists
            existing_hooks = group.get('hooks', [])
            already_present = any(h.get('command') == command for h in existing_hooks)
            if not already_present:
                existing_hooks.append(new_hook_entry)
                group['hooks'] = existing_hooks
            found = True
            break

    if not found:
        new_group = {"hooks": [new_hook_entry]}
        if matcher is not None:
            new_group["matcher"] = matcher
        hooks[hook_key].append(new_group)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print("Hooks installed successfully.")
PYEOF

echo ""
echo "Installed cc-focus hooks into $SETTINGS"
echo "Original backed up to: $BACKUP"
echo ""
echo "Hook events configured:"
echo "  SessionStart    -> cc-focus-hook.sh session_start"
echo "  SessionEnd      -> cc-focus-hook.sh session_end"
echo "  UserPromptSubmit -> cc-focus-hook.sh user_prompt"
echo "  PreToolUse      -> cc-focus-hook.sh pre_tool_use"
echo "  Notification (idle_prompt)       -> cc-focus-hook.sh idle_prompt"
echo "  Notification (permission_prompt) -> cc-focus-hook.sh permission_prompt"
