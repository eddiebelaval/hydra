#!/bin/bash
# life-spec-check.sh - HYDRA Life Triad: Spec Check-In
#
# Runs every Friday at 6 PM via launchd.
# Asks Eddie: "What changed this week?" to keep NOW.md (the spec document) honest.
# Part of the Life Triad system.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

source "$HOME/.hydra/lib/hydra-common.sh"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-life-spec"
LOG_FILE="$LOG_DIR/spec-check.log"
SPEC_FILE="$HOME/life/NOW.md"
DATE=$(date +%Y-%m-%d)

# Load Telegram credentials
if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
    source "$HYDRA_ROOT/config/telegram.env"
fi

mkdir -p "$LOG_DIR"

log "=== Spec check-in started ==="

# ============================================================================
# READ CURRENT SPEC STATE
# ============================================================================

if [[ ! -f "$SPEC_FILE" ]]; then
    log "ERROR: $SPEC_FILE not found"
    exit 1
fi

LAST_UPDATED=$(grep -m1 'Last updated:' "$SPEC_FILE" | sed 's/.*Last updated: //' | sed 's/\*//' || echo "unknown")
BLANK_SECTIONS=$(grep -c "Blank\|Need the honest answer\|thread to pull" "$SPEC_FILE" 2>/dev/null || echo "0")

# ============================================================================
# BUILD CHECK-IN PROMPT + SEND
# ============================================================================

PROMPT="Weekly spec check (Friday)

Your life SPEC was last updated $LAST_UPDATED.
$BLANK_SECTIONS open threads still need honest answers.

End-of-week gut check: what's different this week vs last?

Pick any that apply:
- Work: shipped something? stalled? pivoted?
- Money: anything change?
- Relationships: any shifts?
- Health/energy: better, worse, same?
- Mental state: one word?

(Short answers are fine. Even 'nothing changed' is data.)"

THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "spec-$(date +%s)")
EXPIRES=$(date -v+18H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

CONTEXT_JSON=$(python3 -c "
import json
print(json.dumps({'date': '$DATE', 'type': 'life_spec_check', 'triad': 'spec'}))
" 2>/dev/null || echo "{}")

sqlite3 "$HYDRA_DB" "
    INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'life_spec_check', 'awaiting_input', '$(echo "$CONTEXT_JSON" | sed "s/'/''/g")', '$EXPIRES');
" 2>/dev/null

log "Spec check thread created: $THREAD_ID"

"$NOTIFY" normal "Spec Check" "$PROMPT" "" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

log "Spec check-in sent"

log_activity "life_spec_check_sent" "conversation_thread" "$THREAD_ID" "Life Triad: Spec check-in sent to Eddie"

log "=== Spec check-in complete ==="
echo "Spec check: prompt sent, awaiting Eddie's reply"
