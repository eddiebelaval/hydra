#!/bin/bash
# telegram-handle-gym-proof.sh - HYDRA Gym Checkpoint Handler
#
# Called by telegram-listener.sh when Eddie replies to a gym_checkpoint
# conversation thread. Accepts any reply (photo or text) as proof.
#
# Actions:
#   1. Mark gym checkpoint as cleared in wellness state
#   2. Close the conversation thread
#   3. Send acknowledgment + breakfast reminder
#   4. Trigger morning-planner.sh (priorities unlock)
#
# Usage: telegram-handle-gym-proof.sh "<reply_text>" "<thread_id>"
#   reply_text can be empty (photo-only reply)

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
STATE_FILE="$HYDRA_ROOT/state/wellness-state.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-wellness"
LOG_FILE="$LOG_DIR/wellness.log"

REPLY_TEXT="${1:-}"
THREAD_ID="${2:-}"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [gym-handler] $1" >> "$LOG_FILE"
}

log "Gym proof received: text='${REPLY_TEXT:0:50}' thread=$THREAD_ID"

# ============================================================================
# 1. UPDATE WELLNESS STATE
# ============================================================================

python3 << PYEOF
import json
from datetime import datetime

state_file = "$STATE_FILE"
try:
    state = json.load(open(state_file))
except:
    state = {"date": datetime.now().strftime("%Y-%m-%d"), "sent": []}

state["phase"] = "gym_cleared"
state["gym_cleared_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

with open(state_file, "w") as f:
    json.dump(state, f)
PYEOF

log "Wellness state updated: phase=gym_cleared"

# ============================================================================
# 2. CLOSE CONVERSATION THREAD
# ============================================================================

if [[ -n "$THREAD_ID" ]]; then
    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads
        SET state = 'completed'
        WHERE id = '$THREAD_ID';
    " 2>/dev/null || true
    log "Thread $THREAD_ID closed"
fi

# ============================================================================
# 3. SEND ACKNOWLEDGMENT
# ============================================================================

"$NOTIFY" urgent "Gym Cleared" "Good. Now eat breakfast.

Your priorities are on the way." "" 2>/dev/null || true

log "Acknowledgment sent"

# ============================================================================
# 4. TRIGGER MORNING PLANNER
# ============================================================================

# Small delay to let the ack arrive first
sleep 3

log "Triggering morning planner..."
"$HYDRA_ROOT/daemons/morning-planner.sh" 2>/dev/null &

# Log activity
ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "gym-$(date +%s)")
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID', 'gym_completed', 'system', 'wellness', 'Eddie completed gym checkpoint');
" 2>/dev/null || true

log "Gym checkpoint handler complete"
