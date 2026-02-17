#!/bin/bash
# hydra-observer.sh - HYDRA Observational Memory: Observer Pass
#
# Collects raw events from multiple HYDRA data streams, compresses them
# via Claude Haiku into structured observations, and stores in SQLite.
#
# Data sources:
#   1. Event buffer (Telegram messages, dispatches, responses)
#   2. Git commits (repos tracked by brain-updater)
#   3. Today's briefing
#   4. Activities table (non-heartbeat entries)
#
# Runs every 15 minutes via launchd (com.hydra.observer.plist).
# Cost: ~$0.001 per run (~2K input tokens, ~500 output tokens on Haiku)

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
STATE_FILE="$HYDRA_ROOT/state/observer-state.json"
EVENT_BUFFER="$HYDRA_ROOT/state/event-buffer.log"
OBSERVATIONS_MD="$HYDRA_ROOT/memory/observations.md"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-observer"
LOG_FILE="$LOG_DIR/observer-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Repos to scan (same list as brain-updater, pipe-delimited for Bash 3 compat)
REPO_LIST=(
    "Homer|$HOME/Development/Homer"
    "Parallax|$HOME/Development/id8/products/parallax"
    "Pause|$HOME/Development/id8/products/pause"
    "ID8Composer|$HOME/Development/id8/id8composer-rebuild"
    "id8Labs Site|$HOME/Development/id8/id8labs"
    "Kalshi Bot|$HOME/clawd/projects/kalshi-trading"
)

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$OBSERVATIONS_MD")"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== Observer started ==="

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

if [[ ! -f "$STATE_FILE" ]]; then
    python3 -c "
import json
state = {
    'last_run': '',
    'last_git_shas': {},
    'total_observations': 0,
    'total_runs': 0
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
    log "Created new state file"
fi

get_state() {
    local key="$1"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
print(state.get('$key', ''))
" 2>/dev/null || echo ""
}

get_git_sha() {
    local repo_name="$1"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
print(state.get('last_git_shas', {}).get('$repo_name', ''))
" 2>/dev/null || echo ""
}

update_state() {
    local key="$1"
    local value="$2"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
state['$key'] = '$value'
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
}

save_git_sha() {
    local repo_name="$1"
    local sha="$2"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
if 'last_git_shas' not in state:
    state['last_git_shas'] = {}
state['last_git_shas']['$repo_name'] = '$sha'
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
}

# ============================================================================
# COLLECT EVENTS
# ============================================================================

ALL_EVENTS=""

# --- Source 1: Event Buffer (Telegram messages + dispatches) ---
# Atomic rotate: rename buffer so new writes go to a fresh file while we read the old one.
# This eliminates the race window between read and truncate.

BUFFER_PROCESSING="${EVENT_BUFFER}.processing"

if [[ -f "$EVENT_BUFFER" ]] && [[ -s "$EVENT_BUFFER" ]]; then
    mv "$EVENT_BUFFER" "$BUFFER_PROCESSING" 2>/dev/null
    if [[ -f "$BUFFER_PROCESSING" ]]; then
        BUFFER_LINES=$(wc -l < "$BUFFER_PROCESSING" | tr -d ' ')
        BUFFER_CONTENT=$(cat "$BUFFER_PROCESSING")

        # Sanitize: cap individual lines at 500 chars, strip prompt injection patterns
        BUFFER_CONTENT=$(echo "$BUFFER_CONTENT" | while IFS= read -r line; do
            # Truncate long lines
            echo "${line:0:500}"
        done | grep -iv -E 'ignore.*(all|previous|above).*(instruct|prompt)|forget.*(instruct|prompt)|system.?prompt|you are now|disregard' || true)

        if [[ -n "$BUFFER_CONTENT" ]]; then
            BUFFER_LINES=$(echo "$BUFFER_CONTENT" | wc -l | tr -d ' ')
            ALL_EVENTS+="## Telegram Activity ($BUFFER_LINES events)
$BUFFER_CONTENT

"
        fi
        rm -f "$BUFFER_PROCESSING"
        log "Read $BUFFER_LINES events from buffer (atomic rotate)"
    fi
else
    log "Event buffer empty or missing"
fi

# --- Source 2: Git Commits (since last observer run) ---

GIT_EVENTS=""
for repo_entry in "${REPO_LIST[@]}"; do
    repo_name="${repo_entry%%|*}"
    repo_path="${repo_entry##*|}"

    if [[ ! -d "$repo_path/.git" ]]; then
        continue
    fi

    current_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -z "$current_sha" ]]; then
        continue
    fi

    last_sha=$(get_git_sha "$repo_name")
    if [[ "$current_sha" == "$last_sha" ]]; then
        continue
    fi

    # Get commits since last observation (max 10, last 6 hours)
    commits=$(git -C "$repo_path" log --oneline --since="6 hours ago" --max-count=10 2>/dev/null || echo "")
    if [[ -n "$commits" ]]; then
        commit_count=$(echo "$commits" | wc -l | tr -d ' ')
        GIT_EVENTS+="$repo_name ($commit_count commits):
$commits

"
        log "Git: $repo_name has $commit_count recent commits"
    fi

    save_git_sha "$repo_name" "$current_sha"
done

if [[ -n "$GIT_EVENTS" ]]; then
    ALL_EVENTS+="## Git Activity
$GIT_EVENTS
"
fi

# --- Source 3: Today's Briefing (if not yet observed) ---

BRIEFING_FILE="$HYDRA_ROOT/briefings/briefing-${DATE}.md"
LAST_BRIEFING_DATE=$(get_state "last_briefing_observed")

if [[ -f "$BRIEFING_FILE" ]] && [[ "$LAST_BRIEFING_DATE" != "$DATE" ]]; then
    BRIEFING_CONTENT=$(cat "$BRIEFING_FILE")
    ALL_EVENTS+="## Daily Briefing ($DATE)
$BRIEFING_CONTENT

"
    update_state "last_briefing_observed" "$DATE"
    log "Included today's briefing"
fi

# --- Source 4: Activities Table (non-heartbeat, since last run) ---

LAST_RUN=$(get_state "last_run")
if [[ -z "$LAST_RUN" ]]; then
    LAST_RUN="$DATE 00:00:00"
fi

ACTIVITIES=$(sqlite3 "$HYDRA_DB" "
    SELECT created_at, activity_type, description
    FROM activities
    WHERE activity_type != 'heartbeat'
      AND created_at > '$LAST_RUN'
    ORDER BY created_at DESC
    LIMIT 20;
" 2>/dev/null || echo "")

if [[ -n "$ACTIVITIES" ]]; then
    ACTIVITY_COUNT=$(echo "$ACTIVITIES" | wc -l | tr -d ' ')
    ALL_EVENTS+="## System Activities ($ACTIVITY_COUNT entries since last run)
$ACTIVITIES
"
    log "Included $ACTIVITY_COUNT non-heartbeat activities"
fi

# ============================================================================
# CHECK IF THERE'S ANYTHING TO OBSERVE
# ============================================================================

if [[ -z "$ALL_EVENTS" ]]; then
    log "No events to observe. Skipping Haiku call."
    update_state "last_run" "$TIMESTAMP"
    echo "No events to observe."
    exit 0
fi

EVENT_LENGTH=${#ALL_EVENTS}
log "Total event data: $EVENT_LENGTH chars"

# ============================================================================
# COMPRESS WITH HAIKU
# ============================================================================

# Load API key
API_KEY=""
if [[ -f "$HYDRA_ENV" ]]; then
    API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" | head -1 | cut -d'"' -f2)
fi

if [[ -z "$API_KEY" ]]; then
    log "ERROR: No API key available. Cannot compress events."
    echo "Error: ANTHROPIC_API_KEY not configured in $HYDRA_ENV"
    exit 1
fi

export OBSERVER_EVENTS="$ALL_EVENTS"
export OBSERVER_DATE="$DATE"
export ANTHROPIC_API_KEY="$API_KEY"

OBSERVATIONS=$(python3 << 'PYEOF'
import json, urllib.request, sys, os

events = os.environ.get("OBSERVER_EVENTS", "")
date = os.environ.get("OBSERVER_DATE", "")
api_key = os.environ.get("ANTHROPIC_API_KEY", "")

system_prompt = """You are a meticulous observer of a software creator's daily work and decisions.

Compress raw events into a structured observation log.

Rules:
1. Extract: decisions made, milestones reached, blockers hit, patterns noticed
2. Prioritize:
   - CRITICAL: Strategic decisions, deadlines, blockers, shipped features
   - MODERATE: Questions asked, partial progress, technical considerations
   - LOW: Routine updates, completed minor tasks, informational
3. Format: One line per observation, timestamped HH:MM
4. Be specific: preserve names, numbers, file paths, technical details
5. Skip: duplicate info, routine heartbeats with no change, empty updates
6. Target: 5-15 observations per run (not more)
7. Sub-observations: indent with 2 spaces for supporting details of the above line

Output format (plain text, one per line):
YYYY-MM-DD HH:MM [CRITICAL|MODERATE|LOW] observation text
  YYYY-MM-DD HH:MM [PRIORITY] sub-observation (indented = child of above)

Return ONLY the formatted observations. No headers, no explanation."""

user_message = f"Compress these events from {date}:\n\n{events}"

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 800,
    "system": system_prompt,
    "messages": [{"role": "user", "content": user_message}]
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
    with urllib.request.urlopen(req, timeout=20) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "").strip()

        # Log token usage for cost tracking
        usage = result.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        print(f"TOKENS:{input_tokens}:{output_tokens}", file=sys.stderr)

        if text:
            print(text)
        else:
            print("", file=sys.stderr)
            sys.exit(1)
except Exception as e:
    print(f"Haiku error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

HAIKU_EXIT=$?
if [[ $HAIKU_EXIT -ne 0 ]] || [[ -z "$OBSERVATIONS" ]]; then
    log "ERROR: Haiku compression failed (exit=$HAIKU_EXIT)"
    "$HYDRA_ROOT/daemons/notify-eddie.sh" normal "Observer Error" "Haiku compression failed (exit=$HAIKU_EXIT). Check observer log." 2>/dev/null || true
    update_state "last_run" "$TIMESTAMP"
    exit 1
fi

OBS_LINES=$(echo "$OBSERVATIONS" | wc -l | tr -d ' ')
log "Haiku produced $OBS_LINES observation lines"

# ============================================================================
# PARSE AND STORE OBSERVATIONS IN SQLITE
# ============================================================================

export OBSERVATIONS
export HYDRA_DB

STORED_COUNT=$(python3 << 'PYEOF'
import os, re, sqlite3, sys

observations_text = os.environ.get("OBSERVATIONS", "")
db_path = os.environ.get("HYDRA_DB", "")

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Parse observation lines
# Format: YYYY-MM-DD HH:MM [PRIORITY] text
# Indented lines (2+ spaces) are children of the previous non-indented line
pattern = re.compile(r'^(\s*?)(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+\[(CRITICAL|MODERATE|LOW)\]\s+(.+)$')

parent_id = None
stored = 0

for line in observations_text.strip().split('\n'):
    line = line.rstrip()
    if not line:
        continue

    match = pattern.match(line)
    if not match:
        continue

    indent = match.group(1)
    date = match.group(2)
    time = match.group(3)
    priority = match.group(4).lower()
    content = match.group(5).strip()
    timestamp = f"{date} {time}"

    # Determine source from content keywords
    source = 'system'
    content_lower = content.lower()
    if any(w in content_lower for w in ['telegram', 'message', 'asked', 'eddie said']):
        source = 'telegram'
    elif any(w in content_lower for w in ['commit', 'git', 'pushed', 'merged', 'pr ', 'pull request']):
        source = 'git'
    elif any(w in content_lower for w in ['briefing', 'morning', 'focus score']):
        source = 'briefing'
    elif any(w in content_lower for w in ['heartbeat', 'agent', 'milo', 'forge', 'scout', 'pulse']):
        source = 'heartbeat'

    is_child = len(indent) >= 2

    cursor.execute("""
        INSERT INTO observations (date, timestamp, priority, content, parent_id, source)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (date, timestamp, priority, content, parent_id if is_child else None, source))

    if not is_child:
        parent_id = cursor.lastrowid

    stored += 1

conn.commit()
conn.close()

print(stored)
PYEOF
)

log "Stored $STORED_COUNT observations in SQLite"

# ============================================================================
# RENDER PLAINTEXT OBSERVATIONS.MD
# ============================================================================

# Render the last 3 days of observations for human readability + MILO injection
python3 << PYEOF
import sqlite3, os, sys
from datetime import datetime, timedelta

db_path = "$HYDRA_DB"
output_path = "$OBSERVATIONS_MD"

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Get observations from last 3 days
three_days_ago = (datetime.now() - timedelta(days=3)).strftime('%Y-%m-%d')
cursor.execute("""
    SELECT id, date, timestamp, priority, content, parent_id, source
    FROM observations
    WHERE date >= ?
    ORDER BY date DESC, timestamp DESC
""", (three_days_ago,))

rows = cursor.fetchall()
conn.close()

if not rows:
    with open(output_path, 'w') as f:
        f.write("# HYDRA Observations\\n\\nNo observations in the last 3 days.\\n")
    sys.exit(0)

# Group by date
by_date = {}
for row in rows:
    obs_id, date, ts, priority, content, parent_id, source = row
    if date not in by_date:
        by_date[date] = []
    by_date[date].append({
        'id': obs_id, 'timestamp': ts, 'priority': priority.upper(),
        'content': content, 'parent_id': parent_id, 'source': source
    })

lines = ["# HYDRA Observations", f"*Last updated: {datetime.now().strftime('%Y-%m-%d %H:%M')}*", ""]

for date in sorted(by_date.keys(), reverse=True):
    lines.append(f"## {date}")
    lines.append("")
    for obs in by_date[date]:
        indent = "  " if obs['parent_id'] else ""
        lines.append(f"{indent}{obs['timestamp']} [{obs['priority']}] {obs['content']}")
    lines.append("")

with open(output_path, 'w') as f:
    f.write("\\n".join(lines))

print(f"Rendered {len(rows)} observations to {output_path}")
PYEOF

# ============================================================================
# UPDATE STATE
# ============================================================================

update_state "last_run" "$TIMESTAMP"

# Increment counters
python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
state['total_observations'] = state.get('total_observations', 0) + $STORED_COUNT
state['total_runs'] = state.get('total_runs', 0) + 1
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null

log "Observer complete: $STORED_COUNT observations stored"
echo "Observer complete: $STORED_COUNT observations from $EVENT_LENGTH chars of events"
