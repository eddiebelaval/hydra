#!/bin/bash
# hydra-reflector.sh - HYDRA Observational Memory: Reflector Pass
#
# Consolidates observations from the past 7 days into high-level patterns
# via Claude Sonnet. Writes patterns to the reflections table and updates
# the TECHNICAL_BRAIN.md bounded section.
#
# Runs daily at 2 AM via launchd (com.hydra.reflector.plist).
# Before brain-updater (6 AM), so MILO has fresh consolidated context.
#
# Cost: ~$0.01-0.02 per run (~4K input, ~1K output on Sonnet)
#        ~$0.30-0.60/month

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
BRAIN_FILE="$HYDRA_ROOT/TECHNICAL_BRAIN.md"
STATE_FILE="$HYDRA_ROOT/state/reflector-state.json"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-reflector"
LOG_FILE="$LOG_DIR/reflector-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== Reflector started ==="

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

if [[ ! -f "$STATE_FILE" ]]; then
    python3 -c "
import json
state = {
    'last_run': '',
    'total_reflections': 0,
    'total_runs': 0
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
    log "Created new state file"
fi

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

# ============================================================================
# COLLECT OBSERVATIONS (last 7 days)
# ============================================================================

SEVEN_DAYS_AGO=$(python3 -c "from datetime import datetime, timedelta; print((datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d'))")

OBS_DATA=$(sqlite3 "$HYDRA_DB" "
    SELECT date, timestamp, priority, content, source,
           CASE WHEN parent_id IS NOT NULL THEN '  ' ELSE '' END as indent
    FROM observations
    WHERE date >= '$SEVEN_DAYS_AGO'
    ORDER BY date ASC, timestamp ASC;
" 2>/dev/null || echo "")

if [[ -z "$OBS_DATA" ]]; then
    log "No observations in the last 7 days. Skipping."
    update_state "last_run" "$TIMESTAMP"
    echo "No observations to consolidate."
    exit 0
fi

OBS_COUNT=$(echo "$OBS_DATA" | wc -l | tr -d ' ')
log "Found $OBS_COUNT observations from last 7 days"

# Also get existing reflections (to avoid duplicating known patterns)
EXISTING_PATTERNS=$(sqlite3 "$HYDRA_DB" "
    SELECT pattern FROM reflections
    WHERE created_at >= datetime('now', '-14 days')
    ORDER BY created_at DESC
    LIMIT 10;
" 2>/dev/null || echo "")

# ============================================================================
# CONSOLIDATE WITH SONNET
# ============================================================================

API_KEY=""
if [[ -f "$HYDRA_ENV" ]]; then
    API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" | head -1 | cut -d'"' -f2)
fi

if [[ -z "$API_KEY" ]]; then
    log "ERROR: No API key available."
    echo "Error: ANTHROPIC_API_KEY not configured in $HYDRA_ENV"
    exit 1
fi

export REFLECTOR_OBS="$OBS_DATA"
export REFLECTOR_EXISTING="$EXISTING_PATTERNS"
export REFLECTOR_DATE="$DATE"
export REFLECTOR_PERIOD_START="$SEVEN_DAYS_AGO"
export ANTHROPIC_API_KEY="$API_KEY"

REFLECTIONS=$(python3 << 'PYEOF'
import json, urllib.request, sys, os

observations = os.environ.get("REFLECTOR_OBS", "")
existing = os.environ.get("REFLECTOR_EXISTING", "")
date = os.environ.get("REFLECTOR_DATE", "")
period_start = os.environ.get("REFLECTOR_PERIOD_START", "")
api_key = os.environ.get("ANTHROPIC_API_KEY", "")

system_prompt = """You are a strategic advisor analyzing a software creator's work patterns over the past week.

Given structured observations (timestamped, prioritized), identify recurring patterns, emerging trends, and actionable insights.

Rules:
1. Look for: recurring behaviors, time allocation patterns, project momentum shifts, decision patterns, blockers that repeat
2. Consolidate: merge related observations into higher-level patterns
3. Prioritize:
   - CRITICAL: Patterns affecting deadlines, revenue, or strategic direction
   - MODERATE: Workflow patterns, productivity trends, technical debt signals
   - LOW: Minor habits, routine observations
4. Each pattern should be a single clear sentence that could inform a CTO's daily decisions
5. Reference specific dates/events that support each pattern
6. Target: 5-10 patterns (quality over quantity)
7. Do NOT repeat patterns that already exist (listed below)

Output format (plain text, one per line):
[CRITICAL|MODERATE|LOW] Pattern description (supporting: date1 event, date2 event)

Return ONLY the formatted patterns. No headers, no explanation."""

existing_section = ""
if existing.strip():
    existing_section = f"\n\nExisting patterns (do NOT repeat these):\n{existing}"

user_message = f"Consolidate observations from {period_start} to {date}:\n\n{observations}{existing_section}"

data = json.dumps({
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 1200,
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
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "").strip()

        usage = result.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        print(f"TOKENS:{input_tokens}:{output_tokens}", file=sys.stderr)

        if text:
            print(text)
        else:
            print("Empty response from Sonnet", file=sys.stderr)
            sys.exit(1)
except Exception as e:
    print(f"Sonnet error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

SONNET_EXIT=$?
if [[ $SONNET_EXIT -ne 0 ]] || [[ -z "$REFLECTIONS" ]]; then
    log "ERROR: Sonnet consolidation failed (exit=$SONNET_EXIT)"
    "$HYDRA_ROOT/daemons/notify-eddie.sh" normal "Reflector Error" "Sonnet consolidation failed (exit=$SONNET_EXIT). Check reflector log." 2>/dev/null || true
    update_state "last_run" "$TIMESTAMP"
    exit 1
fi

REF_LINES=$(echo "$REFLECTIONS" | wc -l | tr -d ' ')
log "Sonnet produced $REF_LINES reflection lines"

# ============================================================================
# PARSE AND STORE REFLECTIONS IN SQLITE
# ============================================================================

export REFLECTIONS
export HYDRA_DB
export REFLECTOR_PERIOD_START
export REFLECTOR_DATE="$DATE"

STORED_COUNT=$(python3 << 'PYEOF'
import os, re, sqlite3, json

reflections_text = os.environ.get("REFLECTIONS", "")
db_path = os.environ.get("HYDRA_DB", "")
period_start = os.environ.get("REFLECTOR_PERIOD_START", "")
period_end = os.environ.get("REFLECTOR_DATE", "")

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Parse reflection lines
# Format: [PRIORITY] Pattern description (supporting: ...)
pattern = re.compile(r'^\[(CRITICAL|MODERATE|LOW)\]\s+(.+)$')

stored = 0

for line in reflections_text.strip().split('\n'):
    line = line.strip()
    if not line:
        continue

    match = pattern.match(line)
    if not match:
        continue

    priority = match.group(1).lower()
    content = match.group(2).strip()

    # Extract supporting observation references (dates mentioned in parentheses)
    support_match = re.search(r'\(supporting:?\s*(.+?)\)\s*$', content)
    supporting = support_match.group(1) if support_match else None

    # Clean the pattern text (remove the supporting reference)
    if support_match:
        content = content[:support_match.start()].strip()

    cursor.execute("""
        INSERT INTO reflections (period_start, period_end, pattern, supporting_observations, priority)
        VALUES (?, ?, ?, ?, ?)
    """, (period_start, period_end, content, supporting, priority))

    stored += 1

conn.commit()
conn.close()

print(stored)
PYEOF
)

log "Stored $STORED_COUNT reflections in SQLite"

# ============================================================================
# UPDATE BOUNDED SECTION IN TECHNICAL_BRAIN.MD
# ============================================================================

# Build the reflector section content from recent reflections
BRAIN_SECTION=$(python3 << PYEOF
import sqlite3, os
from datetime import datetime, timedelta

db_path = "$HYDRA_DB"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Get reflections from last 14 days (two reflection cycles)
fourteen_days_ago = (datetime.now() - timedelta(days=14)).strftime('%Y-%m-%d')
cursor.execute("""
    SELECT priority, pattern, period_start, period_end
    FROM reflections
    WHERE created_at >= ?
    ORDER BY
        CASE priority WHEN 'critical' THEN 1 WHEN 'moderate' THEN 2 ELSE 3 END,
        created_at DESC
""", (fourteen_days_ago,))

rows = cursor.fetchall()
conn.close()

if not rows:
    print("No patterns consolidated yet. Reflector runs daily at 2 AM.")
else:
    # Group by priority
    by_priority = {'critical': [], 'moderate': [], 'low': []}
    for priority, pattern, ps, pe in rows:
        by_priority[priority].append(pattern)

    lines = []
    for pri in ['critical', 'moderate', 'low']:
        items = by_priority[pri]
        if items:
            label = pri.upper()
            for item in items:
                lines.append(f"- **[{label}]** {item}")

    print("\\n".join(lines))
PYEOF
)

# Now update the bounded section
export BRAIN_FILE
export BRAIN_SECTION
export DATE

python3 << 'PYEOF'
import os, sys, hashlib

brain_path = os.environ["BRAIN_FILE"]
section_content = os.environ["BRAIN_SECTION"]
date = os.environ["DATE"]

with open(brain_path, "r") as f:
    content = f.read()

start_marker = "<!-- REFLECTOR:START -->"
end_marker = "<!-- REFLECTOR:END -->"

if start_marker not in content or end_marker not in content:
    print("ERROR: Reflector markers not found in TECHNICAL_BRAIN.md", file=sys.stderr)
    sys.exit(1)

start_idx = content.index(start_marker)
end_idx = content.index(end_marker) + len(end_marker)

# Checksum safety: verify content after end marker is unchanged
after_content = content[end_idx:]
checksum_before = hashlib.md5(after_content.encode()).hexdigest()

new_section = f"""{start_marker}
## Behavioral Patterns
*Auto-updated: {date} by HYDRA Reflector*

{section_content}
{end_marker}"""

updated = content[:start_idx] + new_section + content[end_idx:]

after_updated = updated[updated.index(end_marker) + len(end_marker):]
checksum_after = hashlib.md5(after_updated.encode()).hexdigest()

if checksum_before != checksum_after:
    print("ERROR: Content after end marker changed! Aborting.", file=sys.stderr)
    sys.exit(1)

with open(brain_path, "w") as f:
    f.write(updated)

print(f"Brain updated: {len(section_content)} chars in reflector section")
PYEOF

BRAIN_EXIT=$?
if [[ $BRAIN_EXIT -eq 0 ]]; then
    log "TECHNICAL_BRAIN.md reflector section updated"
else
    log "ERROR: Failed to update TECHNICAL_BRAIN.md reflector section"
fi

# ============================================================================
# UPDATE STATE
# ============================================================================

update_state "last_run" "$TIMESTAMP"

python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
state['total_reflections'] = state.get('total_reflections', 0) + $STORED_COUNT
state['total_runs'] = state.get('total_runs', 0) + 1
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null

log "Reflector complete: $STORED_COUNT patterns consolidated from $OBS_COUNT observations"
echo "Reflector complete: $STORED_COUNT patterns from $OBS_COUNT observations ($SEVEN_DAYS_AGO to $DATE)"
