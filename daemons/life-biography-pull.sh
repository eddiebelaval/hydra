#!/bin/bash
# life-biography-pull.sh - HYDRA Life Triad: Biography Story Pull
#
# Runs first Saturday of each month at 3 PM via launchd.
# Picks a random gap from STORY.md (the biography document) and asks Eddie to tell the story.
# The beer conversation. Decompression, not work.
# Part of the Life Triad system.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

source "$HOME/.hydra/lib/hydra-common.sh"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-life-biography"
LOG_FILE="$LOG_DIR/biography-pull.log"
STATE_FILE="$HYDRA_ROOT/state/life-biography-state.json"
BIO_FILE="$HOME/life/STORY.md"
DATE=$(date +%Y-%m-%d)
DAY_OF_MONTH=$(date +%d)

# Load Telegram credentials
if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
    source "$HYDRA_ROOT/config/telegram.env"
fi

mkdir -p "$LOG_DIR" "$HYDRA_ROOT/state"

log "=== Biography pull started ==="

# ============================================================================
# FIRST-SATURDAY GATE — Only fire first Saturday of the month
# ============================================================================

DAY_OF_WEEK=$(date +%u)  # 6 = Saturday

if [[ "$DAY_OF_WEEK" != "6" ]]; then
    log "Not Saturday ($DAY_OF_WEEK). Skipping."
    exit 0
fi

if [[ "$DAY_OF_MONTH" -gt 7 ]]; then
    log "Past first week (day $DAY_OF_MONTH). Skipping."
    exit 0
fi

# Check if already sent this month
CURRENT_MONTH=$(date +%Y-%m)
LAST_MONTH=$(read_state "$STATE_FILE" "last_month")

if [[ "$LAST_MONTH" == "$CURRENT_MONTH" ]]; then
    log "Already sent this month ($CURRENT_MONTH). Skipping."
    echo "Biography pull: already sent this month"
    exit 0
fi

log "First-Saturday gate passed. Pulling a story thread."

# ============================================================================
# PICK A RANDOM GAP FROM BIOGRAPHY
# ============================================================================

if [[ ! -f "$BIO_FILE" ]]; then
    log "ERROR: $BIO_FILE not found"
    exit 1
fi

GAP_THREAD=$(python3 -c "
import re, random

with open('$BIO_FILE') as f:
    content = f.read()

gaps_match = re.search(r'## Gaps\n.*?\n((?:- \*\*.*?\n)+)', content, re.DOTALL)
if gaps_match:
    gaps = re.findall(r'- \*\*(.*?)\.\*\*\s*(.*?)$', gaps_match.group(1), re.MULTILINE)
    if gaps:
        title, description = random.choice(gaps)
        print(f'{title}|||{description}')
    else:
        print('|||No gaps found')
else:
    print('|||No gaps section found')
" 2>/dev/null || echo "|||Could not read biography")

GAP_TITLE=$(echo "$GAP_THREAD" | cut -d'|' -f1)
GAP_DESC=$(echo "$GAP_THREAD" | cut -d'|' -f4)

if [[ -z "$GAP_TITLE" ]]; then
    log "No gaps left in biography. All stories told."
    echo "Biography pull: no gaps remaining"
    exit 0
fi

log "Selected gap: $GAP_TITLE"

# ============================================================================
# BUILD THE BEER PROMPT + SEND
# ============================================================================

OPENER=$(python3 -c "
import random
openers = [
    'Work is done. Grab a drink.',
    'Saturday afternoon. No agenda.',
    'Decompression time.',
    'The sprint is over. Take a breath.',
    'No code today. Just talking.'
]
print(random.choice(openers))
" 2>/dev/null || echo "Saturday afternoon.")

PROMPT="$OPENER

I've got a gap in your biography:

\"$GAP_TITLE\" -- $GAP_DESC

Tell me the story. No structure needed. Just talk.

(This goes into BIOGRAPHY.md next time we're in a session together.)"

THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "bio-$(date +%s)")
EXPIRES=$(date -v+48H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

CONTEXT_JSON=$(python3 -c "
import json
print(json.dumps({
    'date': '$DATE',
    'type': 'life_biography_pull',
    'triad': 'biography',
    'gap_title': '''$GAP_TITLE''',
    'gap_desc': '''$GAP_DESC'''
}))
" 2>/dev/null || echo "{}")

sqlite3 "$HYDRA_DB" "
    INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'life_biography_pull', 'awaiting_input', '$(echo "$CONTEXT_JSON" | sed "s/'/''/g")', '$EXPIRES');
" 2>/dev/null

log "Biography pull thread created: $THREAD_ID"

"$NOTIFY" normal "Biography Pull" "$PROMPT" "" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

log "Biography pull sent: $GAP_TITLE"

# ============================================================================
# UPDATE STATE (custom — includes history array)
# ============================================================================

python3 -c "
import json
state = {
    'last_month': '$CURRENT_MONTH',
    'last_date': '$DATE',
    'last_gap': '$GAP_TITLE',
    'pull_count': 1
}
try:
    with open('$STATE_FILE') as f:
        old = json.load(f)
    state['pull_count'] = old.get('pull_count', 0) + 1
    state['history'] = old.get('history', [])
    state['history'].append({'date': '$DATE', 'gap': '$GAP_TITLE'})
except (IOError, json.JSONDecodeError):
    state['history'] = [{'date': '$DATE', 'gap': '$GAP_TITLE'}]
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null

log_activity "life_biography_pull_sent" "conversation_thread" "$THREAD_ID" "Life Triad: Biography pull sent - $GAP_TITLE"

log "=== Biography pull complete ==="
echo "Biography pull: '$GAP_TITLE' sent, awaiting Eddie's story"
