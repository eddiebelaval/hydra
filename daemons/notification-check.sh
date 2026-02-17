#!/bin/bash
# notification-check.sh - Check and report pending HYDRA notifications
# Runs every 5 minutes via launchd
# Logs: ~/Library/Logs/claude-automation/hydra-notifications/
#
# This daemon:
# 1. Checks for undelivered urgent notifications
# 2. Sends macOS notification for urgent items
# 3. Logs notification stats
# 4. Cleans up old delivered notifications (>7 days)

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
LOGS_DIR="$HOME/Library/Logs/claude-automation/hydra-notifications"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOGS_DIR/check-$DATE.log"

mkdir -p "$LOGS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check database exists
if [[ ! -f "$HYDRA_DB" ]]; then
    log "ERROR: HYDRA database not found"
    exit 1
fi

log "Notification check started"

# ============================================================================
# STEP 1: Check for urgent undelivered notifications
# ============================================================================

URGENT_COUNT=$(sqlite3 "$HYDRA_DB" "
    SELECT COUNT(*) FROM notifications
    WHERE delivered = 0 AND priority = 'urgent';
" 2>/dev/null || echo "0")

NORMAL_COUNT=$(sqlite3 "$HYDRA_DB" "
    SELECT COUNT(*) FROM notifications
    WHERE delivered = 0 AND priority = 'normal';
" 2>/dev/null || echo "0")

TOTAL_PENDING=$((URGENT_COUNT + NORMAL_COUNT))

log "Pending notifications: $TOTAL_PENDING (urgent: $URGENT_COUNT, normal: $NORMAL_COUNT)"

# ============================================================================
# STEP 2: Send macOS notification for urgent items
# ============================================================================

if [[ "$URGENT_COUNT" -gt 0 ]] && command -v terminal-notifier &> /dev/null; then
    # Get first urgent notification details
    URGENT_PREVIEW=$(sqlite3 "$HYDRA_DB" "
        SELECT target_agent || ': ' || content_preview
        FROM notifications
        WHERE delivered = 0 AND priority = 'urgent'
        ORDER BY created_at
        LIMIT 1;
    " 2>/dev/null || echo "Urgent notification pending")

    terminal-notifier -title "HYDRA: $URGENT_COUNT Urgent" \
        -message "$URGENT_PREVIEW" \
        -sound default \
        -group "hydra-urgent" 2>/dev/null || true

    log "macOS notification sent for urgent items"
fi

# ============================================================================
# STEP 3: Log notification summary by agent
# ============================================================================

log "Notifications by agent:"
sqlite3 "$HYDRA_DB" "
    SELECT target_agent, COUNT(*) as count
    FROM notifications
    WHERE delivered = 0
    GROUP BY target_agent;
" 2>/dev/null | while read line; do
    log "  $line"
done

# ============================================================================
# STEP 4: Cleanup old delivered notifications (>7 days)
# ============================================================================

DELETED=$(sqlite3 "$HYDRA_DB" "
    DELETE FROM notifications
    WHERE delivered = 1
    AND delivered_at < datetime('now', '-7 days');
    SELECT changes();
" 2>/dev/null || echo "0")

if [[ "$DELETED" -gt 0 ]]; then
    log "Cleaned up $DELETED old notifications"
fi

# ============================================================================
# STEP 5: Cleanup old activities (>30 days)
# ============================================================================

DELETED_ACTIVITIES=$(sqlite3 "$HYDRA_DB" "
    DELETE FROM activities
    WHERE created_at < datetime('now', '-30 days');
    SELECT changes();
" 2>/dev/null || echo "0")

if [[ "$DELETED_ACTIVITIES" -gt 0 ]]; then
    log "Cleaned up $DELETED_ACTIVITIES old activities"
fi

# ============================================================================
# STEP 6: Telegram listener health check
# ============================================================================
# Verify the telegram listener is running and not in a conflict state.

CONFLICT_FILE="$HOME/.hydra/state/telegram-conflict.txt"
LISTENER_LOCK="$HOME/.hydra/state/telegram-listener.lockdir/pid"

if [[ -f "$CONFLICT_FILE" ]]; then
    CONFLICT_MSG=$(cat "$CONFLICT_FILE" 2>/dev/null)
    log "WARNING: Telegram conflict detected: $CONFLICT_MSG"
    osascript -e 'display notification "Telegram bot conflict still active. Check ~/.hydra/state/telegram-conflict.txt" with title "HYDRA: Telegram Health" sound name "Basso"' 2>/dev/null || true
elif [[ -f "$LISTENER_LOCK" ]]; then
    LISTENER_PID=$(cat "$LISTENER_LOCK" 2>/dev/null)
    if [[ -n "$LISTENER_PID" ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
        log "Telegram listener healthy (PID $LISTENER_PID)"
    else
        log "WARNING: Telegram listener lock stale (PID $LISTENER_PID not running)"
    fi
else
    log "WARNING: Telegram listener not running (no lock found)"
fi

log "Notification check complete"

# Output summary for launchd log
echo "HYDRA Notifications: $TOTAL_PENDING pending (urgent: $URGENT_COUNT)"
