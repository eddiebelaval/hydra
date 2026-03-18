#!/bin/bash
# evening-review.sh - HYDRA Evening Review
#
# Runs daily at 8:00 PM via launchd.
# Sends Eddie a "how'd it go?" check-in with today's priorities listed.
# Eddie's reply is processed by telegram-handle-review-reply.sh
# which updates priority statuses and feeds into tomorrow's suggestions.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-evening-review"
LOG_FILE="$LOG_DIR/review.log"
DATE=$(date +%Y-%m-%d)

# Load credentials
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Evening review started ==="

# ============================================================================
# GATHER TODAY'S PRIORITIES
# ============================================================================

TODAYS_PRIORITIES=$(sqlite3 "$HYDRA_DB" "
    SELECT priority_number || '. ' || description || ' [' || status || ']'
    FROM daily_priorities WHERE date = '$DATE'
    ORDER BY priority_number;
" 2>/dev/null || echo "")

if [[ -z "$TODAYS_PRIORITIES" ]]; then
    log "No priorities set today, skipping evening review"
    echo "Evening review: no priorities set today, skipping"
    exit 0
fi

# ============================================================================
# GATHER TODAY'S GIT ACTIVITY
# ============================================================================

# Shared repo config (single source of truth)
source "$HOME/.hydra/config/repos.sh"

TODAYS_COMMITS=""
COMMIT_CACHE=$(mktemp -d)
trap 'rm -rf "$COMMIT_CACHE"' EXIT

for repo_entry in "${HYDRA_REPOS[@]}"; do
    parse_repo "$repo_entry"
    if [[ -d "$REPO_PATH/.git" ]]; then
        commits=$(git -C "$REPO_PATH" log --oneline --since="today" --max-count=10 2>/dev/null || echo "")
        if [[ -n "$commits" ]]; then
            commit_count=$(echo "$commits" | wc -l | tr -d ' ')
            TODAYS_COMMITS+="$REPO_NAME ($commit_count):
$(echo "$commits" | sed 's/^/  /')

"
            # Cache for MC signal push (avoids double scan)
            echo "$commit_count" > "$COMMIT_CACHE/$REPO_NAME.count"
            echo "$commits" | head -1 | cut -c9- > "$COMMIT_CACHE/$REPO_NAME.latest"
        fi
    fi
done

log "Today's git activity: $(echo "$TODAYS_COMMITS" | wc -l | tr -d ' ') lines"

# ============================================================================
# BUILD REVIEW PROMPT
# ============================================================================

PROMPT="Evening check-in!

Your 3 for today were:
$TODAYS_PRIORITIES
"

if [[ -n "$TODAYS_COMMITS" ]]; then
    PROMPT+="
What shipped today:
$TODAYS_COMMITS"
fi

PROMPT+="How'd it go? (Reply with status for each: done, pushed, dropped, or a note)

Example: \"1 done, 2 pushed to tomorrow, 3 started but need more time\""

# ============================================================================
# CREATE CONVERSATION THREAD
# ============================================================================

THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "review-$(date +%s)")

# Expire after 3 hours (until 11 PM)
EXPIRES=$(date -v+3H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+3 hours' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

CONTEXT_JSON=$(python3 -c "
import json
print(json.dumps({'date': '$DATE', 'type': 'evening_review'}))
" 2>/dev/null || echo "{}")

sqlite3 "$HYDRA_DB" "
    INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'evening_review', 'awaiting_input', '$(echo "$CONTEXT_JSON" | sed "s/'/''/g")', '$EXPIRES');
" 2>/dev/null

log "Evening review thread created: $THREAD_ID"

# ============================================================================
# SEND VIA TELEGRAM
# ============================================================================

"$NOTIFY" normal "Evening Review" "$PROMPT" "" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

log "Evening review prompt sent"

# ============================================================================
# PUSH DAILY SUMMARY TO MISSION CONTROL (uses cached commit data)
# ============================================================================

if [[ -n "$TODAYS_COMMITS" ]]; then
    log "Pushing daily summary to Mission Control..."
    push_mc_signals observation 48 "Daily:" "today" "$COMMIT_CACHE"
    log "Mission Control daily signals complete"
fi

# Log activity
ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID', 'evening_review_sent', 'conversation_thread', '$THREAD_ID', 'Evening review prompt sent to Eddie');
" 2>/dev/null

log "=== Evening review complete ==="
echo "Evening review: prompt sent, awaiting Eddie's reply"
