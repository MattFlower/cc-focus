# cc-focus

A macOS menu bar indicator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions.

When you're running multiple Claude Code instances, cc-focus gives you a passive, glanceable way to know when any instance needs your attention. No notifications, no sounds — just a colored dot.

- **Red dot**: at least one session is waiting for input (idle or permission prompt)
- **Green dot**: all sessions are actively working
- **No dot**: no sessions running
- **Click**: dropdown showing each session's status and working directory

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Install

```bash
git clone https://github.com/mflower/cc-focus.git
cd cc-focus
bash install.sh
```

This will:
1. Build the app from source
2. Install to `~/Applications/cc-focus.app`
3. Add hooks to `~/.claude/settings.json` (existing hooks are preserved)
4. Set up a launch agent so it starts at login
5. Launch the app

## Uninstall

```bash
bash uninstall.sh
```

Removes the app, launch agent, and hooks from Claude settings.

## How it works

Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) send session events (start, end, prompt, tool use) to a shell script (`cc-focus-hook.sh`), which forwards them over a Unix socket to the menu bar app (`cc-focus.swift`).

```
Claude Code hooks → cc-focus-hook.sh → /tmp/cc-focus-501.sock → cc-focus.app (menu bar)
```

Sessions with no activity for 3 minutes are automatically cleaned up (handles crashed instances).

## Manual testing

You can send fake events to see the indicator in action:

```bash
# Green dot (session working)
echo '{"event_type":"session_start","session_id":"test1","cwd":"/tmp/test"}' | nc -U /tmp/cc-focus-501.sock

# Red dot (needs input)
echo '{"event_type":"idle_prompt","session_id":"test1","cwd":"/tmp/test"}' | nc -U /tmp/cc-focus-501.sock

# Remove session
echo '{"event_type":"session_end","session_id":"test1"}' | nc -U /tmp/cc-focus-501.sock
```

## License

MIT
