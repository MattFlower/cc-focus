#!/bin/bash
# cc-focus-hook.sh - Sends Claude Code hook events to cc-focus menu bar app
# Usage: cc-focus-hook.sh <event_type>
# Receives hook JSON on stdin, injects event_type, sends to Unix socket.

SOCKET="/tmp/cc-focus-$(id -u).sock"
EVENT_TYPE="${1:-unknown}"

# Debug log (remove once verified working)
LOG="/tmp/cc-focus-debug.log"
LOG_MAX_BYTES=524288  # 512 KB

# Rotate debug log if it exceeds the size limit
if [ -f "$LOG" ]; then
    LOG_SIZE=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$LOG_MAX_BYTES" ]; then
        tail -c "$LOG_MAX_BYTES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
    fi
fi

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
