#!/bin/bash
# life-midweek-pulse.sh — Wednesday Mid-Week Accountability Pulse
#
# Fires Wednesday 6 PM via launchd. Lightweight check:
# reads this week's commitments, auto-scores what's observable,
# sends a short Telegram pulse. Eddie can reply or ignore.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/life-pulse"
LOG_FILE="$LOG_DIR/pulse-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%G-W%V)

HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Life mid-week pulse started ==="

# Duplicate prevention
SENT_FLAG="$HYDRA_ROOT/state/life-pulse-sent-$WEEK.flag"
if [[ -f "$SENT_FLAG" ]]; then
    log "Already sent pulse for $WEEK. Exiting."
    exit 0
fi

# Only run on Wednesday
DOW=$(date +%u)
if [[ "$DOW" -ne 3 ]]; then
    log "Not Wednesday (day $DOW). Exiting."
    exit 0
fi

# Get this week's commitments
COMMITMENTS=$(sqlite3 "$HYDRA_DB" "
    SELECT dimension, commitment, score
    FROM life_commitments
    WHERE week = '$WEEK'
    ORDER BY dimension;
" 2>/dev/null)

if [[ -z "$COMMITMENTS" ]]; then
    log "No commitments for $WEEK. Exiting."
    exit 0
fi

# Count stats
TOTAL=$(echo "$COMMITMENTS" | wc -l | tr -d ' ')
DONE=$(echo "$COMMITMENTS" | grep -c '|done$' || true)
PARTIAL=$(echo "$COMMITMENTS" | grep -c '|partial$' || true)
PENDING=$(echo "$COMMITMENTS" | grep -c '|pending$' || true)

# Auto-score observable commitments
# Check gym (BODY.md updated this week?)
BODY_UPDATED=$(stat -f %Sm -t %Y-%m-%d ~/life/BODY.md 2>/dev/null || echo "unknown")

# Check git activity (code shipped?)
GIT_COMMITS_WEEK=0
for repo in ~/Development/Homer ~/Development/id8/products/parallax ~/Development/id8/products/rune; do
    if [[ -d "$repo/.git" ]]; then
        COUNT=$(cd "$repo" && git log --oneline --since="last monday" 2>/dev/null | wc -l | tr -d ' ')
        GIT_COMMITS_WEEK=$((GIT_COMMITS_WEEK + COUNT))
    fi
done

# Check MARA posting (execution log entries this week?)
POSTS_THIS_WEEK=0
EXEC_LOG="$HOME/Development/id8/products/parallax/workspace/distro/execution-log.md"
if [[ -f "$EXEC_LOG" ]]; then
    POSTS_THIS_WEEK=$(grep -c "| $DATE\|| $(date -v-1d +%Y-%m-%d)\|| $(date -v-2d +%Y-%m-%d)" "$EXEC_LOG" 2>/dev/null || true)
fi

# Build the pulse message
PULSE="Mid-week pulse -- $WEEK

Commitments: $DONE done / $TOTAL total"

while IFS='|' read -r dim commitment score; do
    case "$score" in
        done) ICON="[done]" ;;
        partial) ICON="[partial]" ;;
        pending) ICON="[pending]" ;;
        missed) ICON="[missed]" ;;
        *) ICON="[?]" ;;
    esac
    PULSE+="
$ICON $dim: $commitment"
done <<< "$COMMITMENTS"

PULSE+="

Observable: $GIT_COMMITS_WEEK commits, $POSTS_THIS_WEEK posts, BODY.md updated $BODY_UPDATED

Anything to flag?"

log "Sending pulse: $DONE/$TOTAL done"

"$NOTIFY" "info" "Life Pulse" "$PULSE" 2>/dev/null || true

touch "$SENT_FLAG"
log "=== Life mid-week pulse complete ==="
