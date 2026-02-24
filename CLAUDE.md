# cc-focus

macOS menu bar status indicator for Claude Code sessions. Single-file Swift/AppKit app.

## Architecture

```
Claude Code hooks (JSON on stdin)
  → cc-focus-hook.sh <event_type>     # injects event_type, sends to socket
    → nc -U /tmp/cc-focus-$(id -u).sock
      → cc-focus.swift                # NSStatusItem menu bar app
```

All logic is in `cc-focus.swift` (~350 lines). No external dependencies, no packages.

## Files

- `cc-focus.swift` - The entire app: socket listener, state machine, menu bar UI
- `cc-focus-hook.sh` - Shell hook that reads Claude Code JSON from stdin, injects event_type via python3, sends to Unix socket
- `cc-focus-cli` - CLI wrapper: `cc-focus-cli setup` / `cc-focus-cli teardown` for hook management
- `Info.plist` - App bundle config (LSUIElement=true for no dock icon)
- `build.sh` - Compiles Swift and creates .app bundle
- `install.sh` - Builds, installs to ~/Applications, sets up hooks and launchd agent
- `install-hooks.sh` - Merges hook entries into ~/.claude/settings.json (preserves existing hooks)
- `uninstall-hooks.sh` - Removes cc-focus hooks from ~/.claude/settings.json
- `uninstall.sh` - Removes app, launch agent, socket, and hooks from settings

## Build & Test

```bash
bash build.sh                    # compile
bash install.sh                  # full install (build + hooks + launchd)
bash uninstall.sh                # full removal
```

Manual test events:
```bash
echo '{"event_type":"session_start","session_id":"test1","cwd":"/tmp"}' | nc -U /tmp/cc-focus-$(id -u).sock
echo '{"event_type":"stop","session_id":"test1","cwd":"/tmp"}' | nc -U /tmp/cc-focus-$(id -u).sock
echo '{"event_type":"session_end","session_id":"test1"}' | nc -U /tmp/cc-focus-$(id -u).sock
```

## Key Design Decisions

- **Stop hook for idle detection**: The `idle_prompt` Notification hook does not fire reliably. The `Stop` hook (fires when Claude finishes its turn) is used instead to detect when a session needs input.
- **Notification events lack session_id**: `Notification` hook events (permission_prompt, idle_prompt) don't include `session_id`. The app falls back to extracting it from `transcript_path`.
- **Resume creates orphan sessions**: When continuing a session, Claude fires two `session_start` events: a "startup" wrapper and a "resume". Only the resumed session gets a `session_end`. The app cleans up the orphaned wrapper when it sees a resume event.
- **isTemplate = false**: The status item image must not be a template, otherwise macOS recolors the circle to match the menu bar theme.
- **Compile with `-swift-version 5`**: Avoids Swift 6 strict concurrency requirements.
- **Debug logging**: `cc-focus-hook.sh` writes to `/tmp/cc-focus-debug.log`. Remove once stable.

## State Machine

| Event | Status |
|-------|--------|
| `session_start`, `user_prompt`, `pre_tool_use` | GREEN (working) |
| `stop`, `idle_prompt`, `permission_prompt` | RED (needs input) |
| `session_end` | Remove session |

The hook script injects the Claude Code PID (`$PPID`) into each event. Every 30 seconds, the app checks if each session's PID is still alive (`kill -0`) and removes dead sessions. No time-based cleanup.
