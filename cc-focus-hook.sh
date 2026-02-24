#!/bin/bash
# cc-focus-hook.sh - Sends Claude Code hook events to cc-focus menu bar app
# Usage: cc-focus-hook.sh <event_type>
# Receives hook JSON on stdin, injects event_type, sends to Unix socket.

SOCKET="/tmp/cc-focus-501.sock"
EVENT_TYPE="${1:-unknown}"

# Debug log (remove once verified working)
LOG="/tmp/cc-focus-debug.log"

# Quick-exit if app isn't running (socket doesn't exist)
[ -S "$SOCKET" ] || { echo "$(date +%H:%M:%S) $EVENT_TYPE - socket missing" >> "$LOG"; exit 0; }

# Read stdin, inject event_type field, send to socket
ENRICHED=$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except:
    data = {}
data['event_type'] = sys.argv[1]
data['pid'] = int(sys.argv[2])
print(json.dumps(data))
" "$EVENT_TYPE" "$PPID" 2>/dev/null)

echo "$(date +%H:%M:%S) $EVENT_TYPE -> $ENRICHED" >> "$LOG"
echo "$ENRICHED" | nc -U "$SOCKET" 2>/dev/null

exit 0
