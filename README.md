# cc-focus

A macOS menu bar indicator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions.

When you're running multiple Claude Code instances, cc-focus gives you a passive, glanceable way to know when any instance needs your attention. No notifications, no sounds — just a colored dot.

- **Red dot**: at least one session is waiting for input (idle or permission prompt)
- **Green dot**: all sessions are actively working
- **No dot**: no sessions running
- **Click**: dropdown showing each session's status and working directory

This app is incredibly minimalistic. There's not even an icon in Applications, it gets set up automatically in launchctl when it gets installed.

There is not an icon by default - it only appears once you have a claude session open. If you close all the Claude sessions, the icon disappears.

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Install with Homebrew (recommended)

```bash
brew install MattFlower/recipes/cc-focus
cc-focus-cli setup                # register Claude Code hooks (one-time)
brew services start cc-focus      # start + auto-launch at login
```

### Uninstall (Homebrew)

```bash
brew services stop cc-focus
cc-focus-cli teardown
brew uninstall cc-focus
```

## Install from source

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

### Uninstall (source)

```bash
bash uninstall.sh
```

Removes the app, launch agent, and hooks from Claude settings.

## How it works

Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) send session events (start, end, prompt, tool use) to a shell script (`cc-focus-hook.sh`), which forwards them over a Unix socket to the menu bar app (`cc-focus.swift`).

```
Claude Code hooks → cc-focus-hook.sh → /tmp/cc-focus-<uid>.sock → cc-focus (menu bar)
```

Sessions whose Claude Code process has exited are automatically cleaned up every 30 seconds.

## Terminal support

Clicking a session in the dropdown switches to its terminal tab/window.

- **iTerm2** and **Terminal.app** work automatically via AppleScript.
- **Kitty** requires enabling remote control. Add these lines to your `kitty.conf`:
  ```
  allow_remote_control socket-only
  listen_on unix:/tmp/kitty-{kitty_pid}
  ```
  Restart Kitty after making changes. If remote control is not configured, cc-focus will show a warning in the menu.

## Development testing

If you have the Homebrew version installed, stop it first and run the dev build directly:

```bash
brew services stop cc-focus
bash build.sh
open cc-focus.app
```

The hooks still work because they write to the same Unix socket regardless of which binary is listening. When done, stop the dev build (Quit from the menu) and restart the brew service:

```bash
brew services start cc-focus
```

## Manual testing

You can send fake events to see the indicator in action:

```bash
# Green dot (session working)
echo '{"event_type":"session_start","session_id":"test1","cwd":"/tmp/test"}' | nc -U /tmp/cc-focus-$(id -u).sock

# Red dot (needs input)
echo '{"event_type":"idle_prompt","session_id":"test1","cwd":"/tmp/test"}' | nc -U /tmp/cc-focus-$(id -u).sock

# Remove session
echo '{"event_type":"session_end","session_id":"test1"}' | nc -U /tmp/cc-focus-$(id -u).sock
```

## License

MIT
