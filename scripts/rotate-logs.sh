#!/bin/bash
# rotate-logs.sh — Prevent launchd stderr logs from ballooning
# Runs daily via launchd. Truncates logs over 10MB, keeping tail.

set -euo pipefail

MAX_SIZE=$((10 * 1024 * 1024))  # 10MB
KEEP_LINES=2000

rotate_if_large() {
    local logfile="$1"
    if [ ! -f "$logfile" ]; then return; fi

    local size
    size=$(stat -f%z "$logfile" 2>/dev/null || echo "0")

    if [ "$size" -gt "$MAX_SIZE" ]; then
        local tmp
        tmp=$(mktemp)
        tail -n "$KEEP_LINES" "$logfile" > "$tmp" 2>/dev/null
        mv "$tmp" "$logfile"
        echo "$(date '+%Y-%m-%d %H:%M:%S') Rotated $logfile (was ${size} bytes)"
    fi
}

# DeepStack bot logs (the 654MB offender)
rotate_if_large "$HOME/Library/Logs/deepstack/bot-stderr.log"
rotate_if_large "$HOME/Library/Logs/deepstack/bot-stdout.log"

# HYDRA daemon logs
for log in "$HOME/Library/Logs/claude-automation"/*/launchd-stderr.log; do
    rotate_if_large "$log"
done
for log in "$HOME/Library/Logs/claude-automation"/*/launchd-stdout.log; do
    rotate_if_large "$log"
done

# Cloudflare error log
rotate_if_large "$HOME/Library/Logs/com.cloudflare.cloudflared.err.log"
