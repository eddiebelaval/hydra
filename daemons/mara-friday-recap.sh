#!/bin/bash
# mara-friday-recap.sh — MARA Friday Performance Recap
#
# Fires Friday 4 PM via launchd. Queries the week's posting activity from
# hydra.db, updates STATUS.md + OKRs.md + metrics.md, sends Telegram summary.
# This closes the weekly loop: Monday war room -> autonomous posting -> Friday recap.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/mara-recap"
LOG_FILE="$LOG_DIR/recap-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%G-W%V)

DISTRO="$HOME/Development/id8/products/parallax/workspace/distro"
STATUS_FILE="$DISTRO/STATUS.md"
OKRS_FILE="$DISTRO/OKRs.md"
METRICS_FILE="$DISTRO/metrics.md"
EXEC_LOG="$DISTRO/execution-log.md"

HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== MARA Friday recap started ==="

# Duplicate prevention
SENT_FLAG="$HYDRA_ROOT/state/mara-recap-sent-$WEEK.flag"
if [[ -f "$SENT_FLAG" ]]; then
    log "Already sent recap for $WEEK. Exiting."
    exit 0
fi

# Only run on Friday
DOW=$(date +%u)
if [[ "$DOW" -ne 5 ]]; then
    log "Not Friday (day $DOW). Exiting."
    exit 0
fi

# ============================================================================
# QUERY THIS WEEK'S DATA
# ============================================================================

log "Querying week's posting data..."

# Posts this week
POSTS_TOTAL=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days');" 2>/dev/null || echo "0")
POSTS_SUCCESS=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days') AND status = 'posted';" 2>/dev/null || echo "0")
POSTS_FAILED=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days') AND status = 'failed';" 2>/dev/null || echo "0")
POSTS_SKIPPED=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days') AND status = 'skipped';" 2>/dev/null || echo "0")

# Platform breakdown
X_POSTS=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days') AND platform = 'x' AND status = 'posted';" 2>/dev/null || echo "0")
LI_POSTS=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM mara_posts WHERE date >= date('now', 'weekday 1', '-7 days') AND platform = 'linkedin' AND status = 'posted';" 2>/dev/null || echo "0")

# Content pipeline status
READY_COUNT=0
READY_DIR="$DISTRO/ready-to-post"
if [[ -d "$READY_DIR" ]]; then
    READY_COUNT=$(ls "$READY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
fi

ARCHIVE_COUNT=0
ARCHIVE_DIR="$READY_DIR/archive"
if [[ -d "$ARCHIVE_DIR" ]]; then
    ARCHIVE_COUNT=$(ls "$ARCHIVE_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
fi

# Post details
POST_LIST=$(sqlite3 "$HYDRA_DB" "
    SELECT date, platform, content_file, status
    FROM mara_posts
    WHERE date >= date('now', 'weekday 1', '-7 days')
    ORDER BY date;
" 2>/dev/null || echo "")

log "Posts: $POSTS_TOTAL total, $POSTS_SUCCESS success, $POSTS_FAILED failed, $POSTS_SKIPPED skipped"

# ============================================================================
# BUILD RECAP
# ============================================================================

RECAP="MARA Weekly Recap -- $WEEK

Posts: $POSTS_SUCCESS posted / $POSTS_TOTAL attempted
X: $X_POSTS | LinkedIn: $LI_POSTS
Failed: $POSTS_FAILED | Skipped: $POSTS_SKIPPED

Pipeline: $READY_COUNT ready | $ARCHIVE_COUNT archived"

if [[ -n "$POST_LIST" ]]; then
    RECAP+="

Activity:"
    while IFS='|' read -r pdate pplatform pfile pstatus; do
        RECAP+="
  $pdate $pplatform $pstatus: $pfile"
    done <<< "$POST_LIST"
fi

# Decision gates
if [[ "$POSTS_SUCCESS" -eq 0 ]]; then
    RECAP+="

ALERT: Zero posts this week. Content pipeline stalled."
fi

if [[ "$READY_COUNT" -lt 3 ]]; then
    RECAP+="

WARNING: Only $READY_COUNT pieces in pipeline. Need fresh content for next week."
fi

# ============================================================================
# UPDATE STATUS FILES
# ============================================================================

log "Updating status files..."

# Update metrics.md if it exists
if [[ -f "$METRICS_FILE" ]]; then
    # Append weekly summary
    echo "" >> "$METRICS_FILE"
    echo "### $WEEK Recap" >> "$METRICS_FILE"
    echo "- Posts: $POSTS_SUCCESS/$POSTS_TOTAL (X: $X_POSTS, LinkedIn: $LI_POSTS)" >> "$METRICS_FILE"
    echo "- Pipeline: $READY_COUNT ready, $ARCHIVE_COUNT archived" >> "$METRICS_FILE"
    echo "- Failed: $POSTS_FAILED, Skipped: $POSTS_SKIPPED" >> "$METRICS_FILE"
    log "Updated metrics.md"
fi

# ============================================================================
# SEND TELEGRAM
# ============================================================================

log "Sending recap..."

"$NOTIFY" "info" "MARA Recap" "$RECAP" 2>/dev/null || true

touch "$SENT_FLAG"
log "=== MARA Friday recap complete ==="
