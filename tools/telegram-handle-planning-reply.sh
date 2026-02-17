#!/bin/bash
# telegram-handle-planning-reply.sh - Handle Eddie's morning priority reply
#
# Called by telegram-listener.sh when Eddie replies to the morning planner prompt.
# Parses the reply into 3 priorities via Haiku, stores them in daily_priorities,
# then TRIGGERS the daily briefing generation.
#
# Usage: telegram-handle-planning-reply.sh "1. Ship demo 2. Review PR 3. Homer auth" [thread_id]

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-morning-planner"
LOG_FILE="$LOG_DIR/planner.log"
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

log "=== Planning reply handler started ==="
log "Reply: ${REPLY_TEXT:0:100}"

if [[ -z "$REPLY_TEXT" ]]; then
    log "ERROR: Empty reply text"
    exit 1
fi

# ============================================================================
# PARSE PRIORITIES (via Haiku for flexible input understanding)
# ============================================================================

PRIORITIES=""
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY
    export HAIKU_REPLY="$REPLY_TEXT"

    PRIORITIES=$(python3 << 'PYEOF'
import json, urllib.request, os

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
reply = os.environ.get("HAIKU_REPLY", "")

prompt = f"""Parse Eddie's priority reply into exactly 3 priorities. Extract the core task description.

Eddie's reply: "{reply}"

Respond with ONLY a JSON array of exactly 3 strings, each being a concise priority description (under 80 chars).
If fewer than 3 are mentioned, keep what's there and add "[unset]" for missing ones.

Example output: ["Ship parallax demo", "Review Rune PR #1", "Homer auth system"]"""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 150,
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
        # Extract JSON array from response
        import re
        match = re.search(r'\[.*?\]', text, re.DOTALL)
        if match:
            arr = json.loads(match.group())
            # Ensure exactly 3
            while len(arr) < 3:
                arr.append("[unset]")
            print(json.dumps(arr[:3]))
except Exception as e:
    print("[]", file=sys.stderr)
PYEOF
) || PRIORITIES="[]"
fi

# Fallback: simple line-based parsing if Haiku fails
if [[ -z "$PRIORITIES" ]] || [[ "$PRIORITIES" == "[]" ]]; then
    log "Haiku parsing failed, using fallback"
    PRIORITIES=$(python3 -c "
import re, json
text = '''$REPLY_TEXT'''
# Try to split on numbers, commas, or newlines
parts = re.split(r'[0-9]+[\.\)]\s*|,\s*|\n', text)
parts = [p.strip() for p in parts if p.strip()]
while len(parts) < 3:
    parts.append('[unset]')
print(json.dumps(parts[:3]))
" 2>/dev/null || echo '["[parsing failed]", "[unset]", "[unset]"]')
fi

log "Parsed priorities: $PRIORITIES"

# ============================================================================
# STORE IN DATABASE
# ============================================================================

# Clear any existing priorities for today (in case of re-plan)
sqlite3 "$HYDRA_DB" "DELETE FROM daily_priorities WHERE date = '$DATE';" 2>/dev/null

# Insert each priority
python3 << PYEOF
import json, sqlite3, uuid

priorities = json.loads('''$PRIORITIES''')
db = sqlite3.connect("$HYDRA_DB")
cursor = db.cursor()

for i, desc in enumerate(priorities[:3], 1):
    pid = str(uuid.uuid4())
    cursor.execute("""
        INSERT INTO daily_priorities (id, date, priority_number, description, suggested_by)
        VALUES (?, ?, ?, ?, 'eddie')
    """, (pid, "$DATE", i, desc))

db.commit()
db.close()
PYEOF

log "Priorities stored in daily_priorities table"

# ============================================================================
# UPDATE CONVERSATION THREAD STATE
# ============================================================================

if [[ -n "$THREAD_ID" ]]; then
    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads
        SET state = 'completed', updated_at = datetime('now')
        WHERE id = '$THREAD_ID';
    " 2>/dev/null
    log "Thread $THREAD_ID marked completed"
fi

# ============================================================================
# SEND CONFIRMATION
# ============================================================================

CONFIRM_MSG="Locked in:
$(python3 -c "
import json
priorities = json.loads('''$PRIORITIES''')
for i, p in enumerate(priorities[:3], 1):
    print(f'{i}. {p}')
" 2>/dev/null)

Generating your briefing now..."

# Load Telegram credentials for inline send
source "$HYDRA_ROOT/config/telegram.env" 2>/dev/null || true
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Send confirmation via Telegram
JSON_MSG=$(printf '%s' "$CONFIRM_MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
printf 'url = "%s"\n' "${TELEGRAM_API}/sendMessage" | curl --config - -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${JSON_MSG}}" 2>/dev/null | grep -q '"ok":true' || true

log "Confirmation sent"

# ============================================================================
# TRIGGER DAILY BRIEFING
# ============================================================================

log "Triggering daily briefing..."
"$HYDRA_ROOT/daemons/daily-briefing.sh" 2>/dev/null &

# Log activity
ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID', 'priorities_set', 'daily_priorities', '$DATE', 'Eddie set daily priorities via morning planner');
" 2>/dev/null

log "=== Planning reply handler complete ==="
echo "Priorities stored, briefing triggered"
