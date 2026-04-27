#!/bin/bash
# log-rotate.sh - HYDRA Log Rotation
#
# Cleans up old logs, reports, and debug files.
# Scheduled via launchd: daily at 4 AM.
# Updated 2026-04-16: added truncation for active logs (the 654MB incident).

set -euo pipefail

LOG_FILE="$HOME/Library/Logs/claude-automation/hydra-maintenance/log-rotate-$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "Starting log rotation"

# 1. Automation logs older than 30 days
AUTOMATION_DIR="$HOME/Library/Logs/claude-automation"
if [[ -d "$AUTOMATION_DIR" ]]; then
    count=$(find "$AUTOMATION_DIR" -type f -name "*.log" -mtime +30 | wc -l | tr -d ' ')
    find "$AUTOMATION_DIR" -type f -name "*.log" -mtime +30 -delete
    log "Automation logs: deleted $count files older than 30 days"
fi

# 2. Reports older than 30 days
REPORTS_DIR="$HOME/.hydra/reports"
if [[ -d "$REPORTS_DIR" ]]; then
    count=$(find "$REPORTS_DIR" -type f -mtime +30 | wc -l | tr -d ' ')
    find "$REPORTS_DIR" -type f -mtime +30 -delete
    log "Reports: deleted $count files older than 30 days"
fi

# 3. Claude debug logs older than 7 days (high-volume)
DEBUG_DIR="$HOME/.claude/debug"
if [[ -d "$DEBUG_DIR" ]]; then
    count=$(find "$DEBUG_DIR" -type f -mtime +7 | wc -l | tr -d ' ')
    find "$DEBUG_DIR" -type f -mtime +7 -delete
    log "Debug logs: deleted $count files older than 7 days"
fi

# 4. Clean up own old rotation logs (older than 90 days)
MAINT_DIR="$HOME/Library/Logs/claude-automation/hydra-maintenance"
if [[ -d "$MAINT_DIR" ]]; then
    find "$MAINT_DIR" -type f -name "*.log" -mtime +90 -delete
fi

# 5. Truncate oversized active logs (the 654MB incident fix)
# Launchd stderr/stdout pipes grow unbounded — cap at 10MB
MAX_SIZE=$((10 * 1024 * 1024))
KEEP_LINES=2000

truncate_if_large() {
    local logfile="$1"
    [ ! -f "$logfile" ] && return
    local size
    size=$(stat -f%z "$logfile" 2>/dev/null || echo "0")
    if [ "$size" -gt "$MAX_SIZE" ]; then
        local tmp
        tmp=$(mktemp)
        tail -n "$KEEP_LINES" "$logfile" > "$tmp" 2>/dev/null
        mv "$tmp" "$logfile"
        log "Truncated $logfile (was $(( size / 1024 / 1024 ))MB)"
    fi
}

# DeepStack bot (primary offender — httpx polling noise)
truncate_if_large "$HOME/Library/Logs/deepstack/bot-stderr.log"
truncate_if_large "$HOME/Library/Logs/deepstack/bot-stdout.log"

# All HYDRA daemon logs
for logdir in "$HOME/Library/Logs/claude-automation"/*/; do
    [ -d "$logdir" ] || continue
    truncate_if_large "${logdir}launchd-stderr.log"
    truncate_if_large "${logdir}launchd-stdout.log"
done

# Cloudflare error log
truncate_if_large "$HOME/Library/Logs/com.cloudflare.cloudflared.err.log"

log "Log rotation complete"
