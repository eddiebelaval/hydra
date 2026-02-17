#!/bin/bash
# telegram-handle-review-reply.sh - Handle Eddie's evening review reply
#
# Called by telegram-listener.sh when Eddie replies to the evening review prompt.
# Parses the reply to update priority statuses in daily_priorities table.
# This data feeds into tomorrow's morning planner suggestions.
#
# Usage: telegram-handle-review-reply.sh "1 done, 2 pushed, 3 started" [thread_id]

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-evening-review"
LOG_FILE="$LOG_DIR/review.log"
DATE=$(date +%Y-%m-%d)

# Load API key
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

REPLY_TEXT="${1:-}"
THREAD_ID="${2:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Review reply handler started ==="
log "Reply: ${REPLY_TEXT:0:100}"

if [[ -z "$REPLY_TEXT" ]]; then
    log "ERROR: Empty reply text"
    exit 1
fi

# ============================================================================
# PARSE STATUS UPDATES (via Haiku)
# ============================================================================

# Get current priorities for context
CURRENT_PRIORITIES=$(sqlite3 "$HYDRA_DB" "
    SELECT priority_number, description FROM daily_priorities
    WHERE date = '$DATE' ORDER BY priority_number;
" 2>/dev/null || echo "")

UPDATES=""
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY
    export HAIKU_REPLY="$REPLY_TEXT"
    export HAIKU_PRIORITIES="$CURRENT_PRIORITIES"

    UPDATES=$(python3 << 'PYEOF'
import json, urllib.request, os

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
reply = os.environ.get("HAIKU_REPLY", "")
priorities = os.environ.get("HAIKU_PRIORITIES", "")

prompt = f"""Parse Eddie's evening review reply into status updates for his 3 daily priorities.

Current priorities:
{priorities}

Eddie's reply: "{reply}"

Valid statuses: done, pushed, dropped, in_progress

Respond with ONLY a JSON array of 3 objects: [{{"number": 1, "status": "done", "notes": "optional note"}}, ...]
If a priority isn't mentioned, keep it as "pending" with no notes."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 200,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        }
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        import re
        match = re.search(r'\[.*?\]', text, re.DOTALL)
        if match:
            print(match.group())
except Exception as e:
    print("[]", file=sys.stderr)
PYEOF
) || UPDATES="[]"
fi

if [[ -z "$UPDATES" ]] || [[ "$UPDATES" == "[]" ]]; then
    log "Parsing failed, marking all as reviewed"
    UPDATES='[{"number": 1, "status": "pending", "notes": "'"$REPLY_TEXT"'"}, {"number": 2, "status": "pending", "notes": ""}, {"number": 3, "status": "pending", "notes": ""}]'
fi

log "Parsed updates: $UPDATES"

# ============================================================================
# UPDATE DATABASE
# ============================================================================

python3 << PYEOF
import json, sqlite3

updates = json.loads('''$UPDATES''')
db = sqlite3.connect("$HYDRA_DB")
cursor = db.cursor()

for u in updates:
    num = u.get("number", 0)
    status = u.get("status", "pending")
    notes = u.get("notes", "")

    # Validate status
    if status not in ("done", "pushed", "dropped", "in_progress", "pending"):
        status = "pending"

    cursor.execute("""
        UPDATE daily_priorities
        SET status = ?, notes = ?
        WHERE date = ? AND priority_number = ?
    """, (status, notes, "$DATE", num))

db.commit()
db.close()
PYEOF

log "Priority statuses updated"

# ============================================================================
# UPDATE CONVERSATION THREAD
# ============================================================================

if [[ -n "$THREAD_ID" ]]; then
    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads
        SET state = 'completed', updated_at = datetime('now')
        WHERE id = '$THREAD_ID';
    " 2>/dev/null
fi

# ============================================================================
# SEND CONFIRMATION
# ============================================================================

# Get updated priorities
UPDATED=$(sqlite3 "$HYDRA_DB" "
    SELECT priority_number || '. ' || description || ' -> ' || UPPER(status)
    FROM daily_priorities WHERE date = '$DATE'
    ORDER BY priority_number;
" 2>/dev/null || echo "Updated.")

CONFIRM_MSG="Got it! Updated:
$UPDATED

This'll feed into tomorrow's suggestions. Good night!"

# Send confirmation
source "$HYDRA_ROOT/config/telegram.env" 2>/dev/null || true
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
JSON_MSG=$(printf '%s' "$CONFIRM_MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
printf 'url = "%s"\n' "${TELEGRAM_API}/sendMessage" | curl --config - -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${JSON_MSG}}" 2>/dev/null | grep -q '"ok":true' || true

log "Confirmation sent"

# Log activity
ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID', 'evening_review_completed', 'daily_priorities', '$DATE', 'Eddie completed evening review');
" 2>/dev/null

log "=== Review reply handler complete ==="
echo "Evening review processed"
