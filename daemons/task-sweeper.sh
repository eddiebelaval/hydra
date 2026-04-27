#!/bin/bash
# task-sweeper.sh - HYDRA Task Expiry Sweeper
#
# Runs daily at 5:55 AM via launchd (before brain-updater at 6:00 AM).
# Cancels tasks that have exceeded their TTL.
# Tasks with ttl_hours = NULL never expire (long-lived goals).
#
# Rules:
#   1. If ttl_hours is set and task age > ttl_hours: cancel it
#   2. If status is 'pending' and age > 7 days and no ttl_hours: warn in log
#   3. If status is 'in_progress' and age > 14 days: warn in log
#
# This prevents daily/ephemeral tasks from piling up forever.

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-task-sweeper"
LOG_FILE="$LOG_DIR/task-sweeper.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "--- Task sweeper starting ---"

# 1. Cancel tasks that exceeded their TTL
EXPIRED=$(sqlite3 "$HYDRA_DB" "
    SELECT id, title, ttl_hours,
           ROUND((julianday('now') - julianday(created_at)) * 24, 1) as age_hours
    FROM tasks
    WHERE ttl_hours IS NOT NULL
      AND status NOT IN ('completed', 'cancelled')
      AND (julianday('now') - julianday(created_at)) * 24 > ttl_hours;
" 2>/dev/null || echo "")

if [[ -n "$EXPIRED" ]]; then
    CANCELLED_COUNT=$(sqlite3 "$HYDRA_DB" "
        UPDATE tasks
        SET status = 'cancelled',
            metadata = json_set(COALESCE(metadata, '{}'), '$.cancelled_reason', 'ttl_expired')
        WHERE ttl_hours IS NOT NULL
          AND status NOT IN ('completed', 'cancelled')
          AND (julianday('now') - julianday(created_at)) * 24 > ttl_hours;
        SELECT changes();
    " 2>/dev/null || echo "0")
    log "Cancelled $CANCELLED_COUNT expired tasks"
    echo "$EXPIRED" | while IFS='|' read -r id title ttl age; do
        log "  Expired: '$title' (ttl=${ttl}h, age=${age}h)"
    done
else
    log "No expired tasks found"
fi

# 2. Warn about stale pending tasks (no TTL, older than 7 days)
STALE_PENDING=$(sqlite3 "$HYDRA_DB" "
    SELECT title,
           ROUND(julianday('now') - julianday(created_at), 0) as age_days
    FROM tasks
    WHERE ttl_hours IS NULL
      AND status = 'pending'
      AND (julianday('now') - julianday(created_at)) > 7;
" 2>/dev/null || echo "")

if [[ -n "$STALE_PENDING" ]]; then
    log "WARNING: Stale pending tasks (>7 days, no TTL):"
    echo "$STALE_PENDING" | while IFS='|' read -r title age; do
        log "  '$title' (${age} days old)"
    done
fi

# 3. Warn about long-running in_progress tasks (>14 days)
STALE_WIP=$(sqlite3 "$HYDRA_DB" "
    SELECT title,
           ROUND(julianday('now') - julianday(created_at), 0) as age_days
    FROM tasks
    WHERE status = 'in_progress'
      AND (julianday('now') - julianday(created_at)) > 14;
" 2>/dev/null || echo "")

if [[ -n "$STALE_WIP" ]]; then
    log "WARNING: Long-running in_progress tasks (>14 days):"
    echo "$STALE_WIP" | while IFS='|' read -r title age; do
        log "  '$title' (${age} days old)"
    done
fi

log "--- Task sweeper complete ---"
