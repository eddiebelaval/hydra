#!/bin/bash
# life-vision-check.sh - HYDRA Life Triad: Vision Check-In
#
# Runs via launchd every Sunday at 7 PM, but only sends every 2 weeks.
# Reads back key lines from ~/life/HEADING.md (the vision document) and asks:
# "Does this still feel true?"
#
# Eddie's reply updates HEADING.md drift detection.
# Part of the Life Triad system.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

source "$HOME/.hydra/lib/hydra-common.sh"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-life-vision"
LOG_FILE="$LOG_DIR/vision-check.log"
STATE_FILE="$HYDRA_ROOT/state/life-vision-state.json"
VISION_FILE="$HOME/life/HEADING.md"
DATE=$(date +%Y-%m-%d)

# Load Telegram credentials
if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
    source "$HYDRA_ROOT/config/telegram.env"
fi

mkdir -p "$LOG_DIR" "$HYDRA_ROOT/state"

log "=== Vision check-in started ==="

# ============================================================================
# BIWEEKLY GATE — Only send every 2 weeks
# ============================================================================

LAST_SENT=$(read_state "$STATE_FILE" "last_sent")

if [[ -n "$LAST_SENT" ]]; then
    DAYS_SINCE=$(python3 -c "
from datetime import datetime
last = datetime.strptime('$LAST_SENT', '%Y-%m-%d')
now = datetime.strptime('$DATE', '%Y-%m-%d')
print((now - last).days)
" 2>/dev/null || echo "0")

    if [[ "$DAYS_SINCE" -lt 13 ]]; then
        log "Only $DAYS_SINCE days since last vision check (need 14). Skipping."
        echo "Vision check: skipped (only $DAYS_SINCE days since last)"
        exit 0
    fi
fi

log "Biweekly gate passed. Sending vision check-in."

# ============================================================================
# READ VISION HIGHLIGHTS
# ============================================================================

if [[ ! -f "$VISION_FILE" ]]; then
    log "ERROR: $VISION_FILE not found"
    exit 1
fi

VISION_HIGHLIGHTS=$(python3 -c "
import re

with open('$VISION_FILE') as f:
    content = f.read()

sections = []
for section in ['The Architect', 'The Space', 'The Rhythm', 'The People']:
    pattern = rf'## {section}\n\n(.*?)(?=\n---|\n## |\Z)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        text = match.group(1).strip()
        if not text.startswith('*('):
            lines = [l for l in text.split('\n') if l.strip() and not l.startswith('*')][:2]
            if lines:
                sections.append(f'{section}: {lines[0].strip()}')

print('\n'.join(sections))
" 2>/dev/null || echo "Could not read vision file")

# ============================================================================
# BUILD CHECK-IN PROMPT + SEND
# ============================================================================

PROMPT="Vision check-in (biweekly)

Your vision, last written $(date -r "$VISION_FILE" '+%b %d'):

$VISION_HIGHLIGHTS

Does this still feel true? Anything shifted? Anything sharper now?

(Reply naturally — I'll update the doc. Or just say 'still true' and we move on.)"

THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "vision-$(date +%s)")
EXPIRES=$(date -v+24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

CONTEXT_JSON=$(python3 -c "
import json
print(json.dumps({'date': '$DATE', 'type': 'life_vision_check', 'triad': 'vision'}))
" 2>/dev/null || echo "{}")

sqlite3 "$HYDRA_DB" "
    INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'life_vision_check', 'awaiting_input', '$(echo "$CONTEXT_JSON" | sed "s/'/''/g")', '$EXPIRES');
" 2>/dev/null

log "Vision check thread created: $THREAD_ID"

"$NOTIFY" normal "Vision Check" "$PROMPT" "" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

log "Vision check-in sent"

# ============================================================================
# UPDATE STATE
# ============================================================================

update_state "$STATE_FILE" "last_sent=$DATE" "send_count+=1"
log_activity "life_vision_check_sent" "conversation_thread" "$THREAD_ID" "Life Triad: Vision check-in sent to Eddie"

log "=== Vision check-in complete ==="
echo "Vision check: prompt sent, awaiting Eddie's reply"
