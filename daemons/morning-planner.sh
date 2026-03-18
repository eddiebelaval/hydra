#!/bin/bash
# morning-planner.sh - HYDRA Interactive Morning Planner
#
# Runs daily at 8:00 AM via launchd (BEFORE the briefing).
# Generates AI-suggested priorities based on yesterday's activity,
# goals, and stale tasks, then sends a Telegram prompt asking Eddie
# for his top 3 priorities.
#
# The briefing is held until Eddie replies (or 8:40 AM fallback).
#
# Pipeline:
#   6:00 AM  Brain Updater (git activity)
#   6:05 AM  Goals Updater (bounded sections)
#   8:00 AM  Morning Planner -> Telegram prompt [THIS SCRIPT]
#            [Eddie replies] -> telegram-handle-planning-reply.sh
#                            -> triggers daily-briefing.sh
#   8:40 AM  Fallback: briefing generates anyway if no reply

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
GOALS_FILE="$HYDRA_ROOT/GOALS.md"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-morning-planner"
LOG_FILE="$LOG_DIR/planner.log"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)

# Load API key
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Shared repo config (single source of truth)
source "$HOME/.hydra/config/repos.sh"

log "=== Morning planner started ==="

# ============================================================================
# DUPLICATE PREVENTION + GYM GATE
# ============================================================================

WELLNESS_STATE="$HYDRA_ROOT/state/wellness-state.json"
PLANNER_SENT_FILE="$HYDRA_ROOT/state/planner-sent-$DATE.flag"

# Skip if already sent today (prevents double-send from clock + gym handler)
if [[ -f "$PLANNER_SENT_FILE" ]]; then
    log "Already sent today (flag file exists). Skipping."
    exit 0
fi

# Check gym phase — if pre_gym and before 11 AM, send reminder instead
GYM_PHASE=$(python3 -c "
import json
try:
    state = json.load(open('$WELLNESS_STATE'))
    if state.get('date') == '$DATE':
        print(state.get('phase', 'pre_gym'))
    else:
        print('unknown')
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

NOW_H=$(date +%-H)
if [[ "$GYM_PHASE" == "pre_gym" ]] && [[ "$NOW_H" -lt 11 ]]; then
    log "Gym not cleared yet (phase=$GYM_PHASE, hour=$NOW_H). Sending reminder."
    "$NOTIFY" normal "Waiting for Gym" "Your priorities are ready — but gym first.

Reply to the gym checkpoint message when you're done." "" 2>/dev/null || true
    exit 0
fi

# ============================================================================
# GATHER CONTEXT FOR SUGGESTIONS
# ============================================================================

# Yesterday's priority outcomes
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "")
YESTERDAY_PRIORITIES=""
if [[ -n "$YESTERDAY" ]]; then
    YESTERDAY_PRIORITIES=$(sqlite3 "$HYDRA_DB" "
        SELECT priority_number || '. ' || description || ' [' || status || ']'
        FROM daily_priorities
        WHERE date = '$YESTERDAY'
        ORDER BY priority_number;
    " 2>/dev/null || echo "")
fi

# Recent observations (last 2 days)
RECENT_OBS=$(sqlite3 "$HYDRA_DB" "
    SELECT content FROM observations
    WHERE date >= date('now', '-2 days')
    ORDER BY timestamp DESC
    LIMIT 10;
" 2>/dev/null || echo "")

# Goals excerpt (Q1 primary goals only, keep it compact)
GOALS_EXCERPT=""
if [[ -f "$GOALS_FILE" ]]; then
    GOALS_EXCERPT=$(sed -n '/### Primary/,/### Secondary/{
        /### Secondary/d
        p
    }' "$GOALS_FILE" 2>/dev/null || echo "")
fi

# Stale tasks (pending for 3+ days)
STALE_TASKS=$(sqlite3 "$HYDRA_DB" "
    SELECT title FROM tasks
    WHERE status = 'pending'
    AND created_at < datetime('now', '-3 days')
    ORDER BY priority, created_at
    LIMIT 5;
" 2>/dev/null || echo "")

# High priority active tasks
ACTIVE_HIGH=$(sqlite3 "$HYDRA_DB" "
    SELECT COALESCE(assigned_to, 'unassigned') || ': ' || title
    FROM tasks
    WHERE status IN ('pending', 'in_progress')
    AND priority <= 2
    LIMIT 5;
" 2>/dev/null || echo "")

# Agent board posts (last 24h — what agents discovered overnight)
BOARD_POSTS=$(sqlite3 "$HYDRA_DB" "
    SELECT channel || ': ' || message
    FROM agent_board
    WHERE created_at >= datetime('now', '-24 hours')
    AND parent_id IS NULL
    ORDER BY created_at DESC
    LIMIT 8;
" 2>/dev/null || echo "")

# Recent git activity from brain-updater (runs at 6 AM, before this)
BRAIN_FILE="$HYDRA_ROOT/TECHNICAL_BRAIN.md"
GIT_ACTIVITY=""
if [[ -f "$BRAIN_FILE" ]]; then
    GIT_ACTIVITY=$(sed -n '/<!-- BRAIN-UPDATER:START -->/,/<!-- BRAIN-UPDATER:END -->/{
        /<!-- BRAIN-UPDATER/d
        /^## Recent Git Activity/d
        /^\*Auto-updated/d
        p
    }' "$BRAIN_FILE" 2>/dev/null || echo "")
    GIT_ACTIVITY=$(echo "$GIT_ACTIVITY" | sed '1{/^$/d;}')
fi

# Mission Control signals (active alerts, observations -- MC_CLI from repos.sh)
MC_SIGNALS=""
if [[ -x "$MC_CLI" ]]; then
    MC_SIGNALS=$("$MC_CLI" signals --pretty 2>/dev/null || echo "")
fi

log "Context gathered: yesterday_priorities=$(echo "$YESTERDAY_PRIORITIES" | wc -l | tr -d ' ') obs=$(echo "$RECENT_OBS" | wc -l | tr -d ' ') board=$(echo "$BOARD_POSTS" | wc -l | tr -d ' ') git_activity=$(echo "$GIT_ACTIVITY" | wc -l | tr -d ' ') mc_signals=$(echo "$MC_SIGNALS" | wc -l | tr -d ' ')"

# ============================================================================
# GENERATE AI SUGGESTIONS (Claude Haiku)
# ============================================================================

SUGGESTIONS=""
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY
    export HAIKU_YESTERDAY_PRIORITIES="$YESTERDAY_PRIORITIES"
    export HAIKU_RECENT_OBS="$RECENT_OBS"
    export HAIKU_GOALS="$GOALS_EXCERPT"
    export HAIKU_STALE="$STALE_TASKS"
    export HAIKU_ACTIVE="$ACTIVE_HIGH"
    export HAIKU_BOARD="$BOARD_POSTS"
    export HAIKU_GIT="$GIT_ACTIVITY"
    export HAIKU_MC="$MC_SIGNALS"
    export HAIKU_DAY="$DAY_NAME"

    SUGGESTIONS=$(python3 << 'PYEOF'
import json, urllib.request, os

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
yesterday = os.environ.get("HAIKU_YESTERDAY_PRIORITIES", "none")
observations = os.environ.get("HAIKU_RECENT_OBS", "none")
goals = os.environ.get("HAIKU_GOALS", "none")
stale = os.environ.get("HAIKU_STALE", "none")
active = os.environ.get("HAIKU_ACTIVE", "none")
board = os.environ.get("HAIKU_BOARD", "none")
git_activity = os.environ.get("HAIKU_GIT", "none")
mc_signals = os.environ.get("HAIKU_MC", "none")
day = os.environ.get("HAIKU_DAY", "today")

prompt = f"""You are HYDRA, Eddie Belaval's AI co-founder system. It's {day} morning.

Based on the context below, suggest 3 priorities for Eddie today. Be specific and actionable.
Use co-founder voice — direct, slightly opinionated, referencing real project context.
If something was pushed or dropped yesterday, nudge about it. If a goal is being neglected, call it out.
Reference the actual git activity — what shipped recently matters for deciding what's next.

YESTERDAY'S PRIORITIES:
{yesterday if yesterday else "No priorities set yesterday."}

RECENT GIT ACTIVITY (last 7 days):
{git_activity if git_activity else "No recent git activity."}

RECENT OBSERVATIONS:
{observations if observations else "No recent observations."}

Q1 GOALS:
{goals if goals else "No goals loaded."}

STALE TASKS (pending 3+ days):
{stale if stale else "None"}

HIGH PRIORITY ACTIVE:
{active if active else "None"}

AGENT BOARD (what agents discovered overnight):
{board if board else "No overnight agent activity."}

MISSION CONTROL SIGNALS (active alerts/observations across portfolio):
{mc_signals if mc_signals else "No active MC signals."}

Respond with exactly 3 numbered suggestions, one per line. Keep each under 60 chars. No preamble."""

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
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        if text:
            print(text.strip())
except Exception as e:
    print(f"(suggestions unavailable: {e})", file=sys.stderr)
PYEOF
) || SUGGESTIONS=""

    log "Haiku suggestions: $(echo "$SUGGESTIONS" | head -1)"
fi

# ============================================================================
# BUILD TELEGRAM PROMPT
# ============================================================================

PROMPT="Morning, Eddie. Happy $DAY_NAME.

Walk the dog. Gym. Breakfast. Then open the terminal.

Once you're back, here's the picture:

"

# Show yesterday's outcome if available
if [[ -n "$YESTERDAY_PRIORITIES" ]]; then
    PROMPT+="Yesterday's priorities:
$YESTERDAY_PRIORITIES

"
fi

# Show AI suggestions
if [[ -n "$SUGGESTIONS" ]]; then
    PROMPT+="Based on your goals + recent activity, I'd suggest:
$SUGGESTIONS

"
fi

PROMPT+="What are your top 3 today? (Reply to this message)"

# ============================================================================
# CREATE CONVERSATION THREAD
# ============================================================================

THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "planner-$(date +%s)")

# Expire at 8:40 AM (40 min window)
EXPIRES=$(date -v+40M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+40 minutes' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

# Store suggestions as context for the reply handler
CONTEXT_JSON=$(python3 -c "
import json
suggestions = '''$SUGGESTIONS'''
print(json.dumps({'date': '$DATE', 'suggestions': suggestions, 'day': '$DAY_NAME'}))
" 2>/dev/null || echo "{}")

sqlite3 "$HYDRA_DB" "
    INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'morning_planner', 'awaiting_input', '$(echo "$CONTEXT_JSON" | sed "s/'/''/g")', '$EXPIRES');
" 2>/dev/null

log "Conversation thread created: $THREAD_ID (expires: $EXPIRES)"

# ============================================================================
# SEND VIA TELEGRAM (with entity tracking for reply routing)
# ============================================================================

"$NOTIFY" urgent "Morning Planner" "$PROMPT" "" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

log "Morning prompt sent via Telegram"

# ============================================================================
# LOG ACTIVITY
# ============================================================================

ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID', 'morning_planner_sent', 'conversation_thread', '$THREAD_ID', 'Morning planner prompt sent to Eddie');
" 2>/dev/null

# Mark as sent today (duplicate prevention)
touch "$PLANNER_SENT_FILE"

# Clean up flag files older than 7 days
find "$HYDRA_ROOT/state" -name "planner-sent-*.flag" -mtime +7 -delete 2>/dev/null || true

log "=== Morning planner complete ==="
echo "Morning planner: prompt sent, awaiting Eddie's reply"
