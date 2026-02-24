#!/bin/bash
# cc-focus-hook.sh - Sends Claude Code hook events to cc-focus menu bar app
# Usage: cc-focus-hook.sh <event_type>
# Receives hook JSON on stdin, injects event_type, sends to Unix socket.

SOCKET="/tmp/cc-focus-501.sock"
EVENT_TYPE="${1:-unknown}"

# Quick-exit if app isn't running (socket doesn't exist)
[ -S "$SOCKET" ] || exit 0

# Read stdin, inject event_type field, send to socket
INPUT=$(cat)
ENRICHED=$(python3 -c "
import json, sys
data = json.loads('''$INPUT''') if '''$INPUT'''.strip() else {}
data['event_type'] = '$EVENT_TYPE'
print(json.dumps(data))
" 2>/dev/null) || exit 0

echo "$ENRICHED" | nc -U "$SOCKET" 2>/dev/null

exit 0
