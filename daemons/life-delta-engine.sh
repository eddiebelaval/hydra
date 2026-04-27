#!/bin/bash
# life-delta-engine.sh — Weekly Life Delta Computation
#
# Fires Sunday 7 PM via launchd. Reads the life triad, computes the delta
# between HEADING (vision) and NOW (reality), scores last week's commitments,
# generates new commitments, writes DELTA.md, and sends a Telegram summary.
#
# This is the accountability layer for Eddie's life. Not annoying. Not a nag.
# Just the truth about where you are vs where you're heading.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/life-delta"
LOG_FILE="$LOG_DIR/delta-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%G-W%V)
LIFE_DIR="$HOME/life"

# Load env
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Life delta engine started ==="

# ============================================================================
# GUARDS
# ============================================================================

SENT_FLAG="$HYDRA_ROOT/state/life-delta-sent-$WEEK.flag"
if [[ -f "$SENT_FLAG" ]]; then
    log "Already computed delta for $WEEK. Exiting."
    exit 0
fi

# ============================================================================
# GATHER CONTEXT
# ============================================================================

log "Gathering life context..."

HEADING=""
[[ -f "$LIFE_DIR/HEADING.md" ]] && HEADING=$(cat "$LIFE_DIR/HEADING.md")

NOW=""
[[ -f "$LIFE_DIR/NOW.md" ]] && NOW=$(cat "$LIFE_DIR/NOW.md")

GOALS=""
[[ -f "$LIFE_DIR/GOALS.md" ]] && GOALS=$(cat "$LIFE_DIR/GOALS.md")

MONEY=""
[[ -f "$LIFE_DIR/MONEY.md" ]] && MONEY=$(head -60 "$LIFE_DIR/MONEY.md")

BODY=""
[[ -f "$LIFE_DIR/BODY.md" ]] && BODY=$(cat "$LIFE_DIR/BODY.md")

PEOPLE=""
[[ -f "$LIFE_DIR/PEOPLE.md" ]] && PEOPLE=$(cat "$LIFE_DIR/PEOPLE.md")

# Last week's commitments
LAST_COMMITMENTS=$(sqlite3 "$HYDRA_DB" "
    SELECT dimension, commitment, score
    FROM life_commitments
    WHERE week = '$WEEK'
    ORDER BY dimension;
" 2>/dev/null || echo "No prior commitments")

# Last 4 weeks of signals for trend
TREND_DATA=$(sqlite3 "$HYDRA_DB" "
    SELECT date, dimension, direction
    FROM life_signals
    WHERE date >= date('$DATE', '-28 days')
    ORDER BY date DESC, dimension;
" 2>/dev/null || echo "No trend data")

# Previous DELTA.md for continuity
PREV_DELTA=""
[[ -f "$LIFE_DIR/DELTA.md" ]] && PREV_DELTA=$(cat "$LIFE_DIR/DELTA.md")

# Subjective question rotation (4-week cycle)
WEEK_NUM=$(date +%V)
ROTATION=$((WEEK_NUM % 4))
case $ROTATION in
    0) SUBJECTIVE_Q="How's your mental state right now? One honest sentence." ;;
    1) SUBJECTIVE_Q="How are things with the people in your life? One honest sentence." ;;
    2) SUBJECTIVE_Q="How's your energy and body feeling? One honest sentence." ;;
    3) SUBJECTIVE_Q="Are you satisfied with the pace of progress? One honest sentence." ;;
esac

# ============================================================================
# COMPUTE DELTA VIA SONNET
# ============================================================================

log "Calling Claude Sonnet for delta computation..."

DELTA_PROMPT="You are the Life Delta Engine for Eddie Belaval. You compute the weekly gap between his HEADING (vision) and NOW (reality).

TODAY: $DATE (Week $WEEK)

HEADING.md (vision):
$HEADING

NOW.md (present reality):
$NOW

GOALS.md:
$GOALS

MONEY.md:
$MONEY

BODY.md:
$BODY

PEOPLE.md:
$PEOPLE

LAST WEEK'S COMMITMENTS AND SCORES:
$LAST_COMMITMENTS

TREND (last 4 weeks of signals):
$TREND_DATA

PREVIOUS DELTA REPORT:
$PREV_DELTA

INSTRUCTIONS:
1. Score each of the 6 dimensions by comparing HEADING to NOW:
   - architect: identity as AI/humanity architect
   - space: homeownership, sovereign space
   - rhythm: self-set pace, contentment, routine
   - financial: revenue, independence, money stops being variable
   - physical: body, health, clean signal
   - connection: people, family, not alone but free

2. For each dimension, assign a direction:
   - converging (gap closing)
   - flat (no movement)
   - diverging (gap widening)

3. Score last week's commitments if any exist (done/partial/missed based on observable evidence in the files).

4. Generate 3-5 NEW commitments for this week. Each must be:
   - Specific and time-bound
   - Tied to the dimension with the widest gap
   - Achievable in one week
   - Not busy work

5. Compute overall net status: CONVERGING if majority converging, DIVERGING if any critical dimension (financial) is diverging, FLAT otherwise.

Return ONLY a JSON object:
{
  \"net_status\": \"CONVERGING\" | \"FLAT\" | \"DIVERGING\",
  \"dimensions\": {
    \"architect\": { \"direction\": \"converging|flat|diverging\", \"summary\": \"1 sentence\" },
    \"space\": { \"direction\": \"...\", \"summary\": \"...\" },
    \"rhythm\": { \"direction\": \"...\", \"summary\": \"...\" },
    \"financial\": { \"direction\": \"...\", \"summary\": \"...\" },
    \"physical\": { \"direction\": \"...\", \"summary\": \"...\" },
    \"connection\": { \"direction\": \"...\", \"summary\": \"...\" }
  },
  \"scored_commitments\": [
    { \"commitment\": \"...\", \"score\": \"done|partial|missed|pending\", \"reason\": \"...\" }
  ],
  \"new_commitments\": [
    { \"dimension\": \"...\", \"commitment\": \"...\" }
  ],
  \"trend_note\": \"1 sentence about trajectory compared to last week\"
}"

DELTA_RESPONSE=$(python3 << PYEOF
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY")
if not api_key:
    for env_file in [
        os.path.expanduser("~/.hydra/config/telegram.env"),
        os.path.expanduser("~/.env"),
    ]:
        if os.path.exists(env_file):
            with open(env_file) as f:
                for line in f:
                    if line.startswith("ANTHROPIC_API_KEY="):
                        api_key = line.strip().split("=", 1)[1].strip('"').strip("'")
                        break
        if api_key:
            break

if not api_key:
    print(json.dumps({"error": "No ANTHROPIC_API_KEY found"}))
    sys.exit(1)

prompt = """$DELTA_PROMPT"""

data = json.dumps({
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1000,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=data,
    headers={
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01"
    }
)

try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read())
        text = result["content"][0]["text"].strip()
        if text.startswith("\`\`\`"):
            text = text.split("\n", 1)[1].rsplit("\`\`\`", 1)[0].strip()
        parsed = json.loads(text)
        print(json.dumps(parsed))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)
PYEOF
)

log "Sonnet response received"

# Check for error
ERROR_CHECK=$(echo "$DELTA_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "parse_error")
if [[ -n "$ERROR_CHECK" ]] && [[ "$ERROR_CHECK" != "" ]]; then
    log "ERROR from Sonnet: $ERROR_CHECK"
    "$NOTIFY" "urgent" "Life Delta" "Delta computation failed: $ERROR_CHECK" 2>/dev/null || true
    exit 1
fi

# ============================================================================
# WRITE DELTA.md
# ============================================================================

log "Writing DELTA.md..."

# Extract fields
NET_STATUS=$(echo "$DELTA_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['net_status'])")
TREND_NOTE=$(echo "$DELTA_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('trend_note',''))")

# Generate DELTA.md via Python for clean formatting
python3 << PYEOF
import json, sys
from datetime import datetime, timedelta

data = json.loads('''$DELTA_RESPONSE''')
today = "$DATE"
week = "$WEEK"

# Week range
from datetime import date
d = date.fromisoformat(today)
start = d - timedelta(days=d.weekday())
end = start + timedelta(days=6)

arrows = {"converging": "-->", "flat": "---", "diverging": "<--"}
labels = {"converging": "CONVERGING", "flat": "FLAT", "diverging": "DIVERGING"}

lines = []
lines.append("# Delta Report")
lines.append(f"*Week of {start.strftime('%b %d')}-{end.strftime('%b %d, %Y')}. Gap between HEADING (vision) and NOW (reality).*")
lines.append(f"*Computed: {today}*")
lines.append("")
lines.append("---")
lines.append("")
lines.append(f"## Net Status: {data['net_status']}")
lines.append("")
if data.get("trend_note"):
    lines.append(f"{data['trend_note']}")
    lines.append("")
lines.append("---")
lines.append("")
lines.append("## Dimensions")
lines.append("")

dim_names = {"architect": "Architect Identity", "space": "Sovereign Space", "rhythm": "Self-Set Rhythm",
             "financial": "Financial Freedom", "physical": "Physical Machine", "connection": "Connection"}

for key in ["architect", "space", "rhythm", "financial", "physical", "connection"]:
    dim = data["dimensions"][key]
    arrow = arrows.get(dim["direction"], "---")
    label = labels.get(dim["direction"], "FLAT")
    lines.append(f"### {dim_names[key]}: {arrow} {label}")
    lines.append(dim["summary"])
    lines.append("")

lines.append("---")
lines.append("")
lines.append("## This Week's Actions (close the gap)")
lines.append("")
for i, c in enumerate(data.get("new_commitments", []), 1):
    lines.append(f"{i}. **{c['dimension'].title()}:** {c['commitment']}")
lines.append("")

lines.append("---")
lines.append("")
lines.append("## Last Week's Score")
lines.append("")
scored = data.get("scored_commitments", [])
if scored:
    total = len(scored)
    done = sum(1 for s in scored if s["score"] == "done")
    for s in scored:
        check = "x" if s["score"] == "done" else ("~" if s["score"] == "partial" else " ")
        lines.append(f"- [{check}] {s['commitment']} -- {s['score'].upper()}")
    lines.append(f"\nScore: {done}/{total}")
else:
    lines.append("*Baseline week. No prior commitments to score.*")
lines.append("")

lines.append("---")
lines.append("")
lines.append("## Trend")
lines.append("")
lines.append(f"{week}: {data['net_status']}")
lines.append("")

lines.append("---")
lines.append("")
lines.append("*The delta between HEADING and NOW is the roadmap. This report makes it visible. Git history tracks whether the gap is closing or widening over time.*")

with open("$LIFE_DIR/DELTA.md", "w") as f:
    f.write("\n".join(lines) + "\n")

print("DELTA.md written")
PYEOF

log "DELTA.md written"

# ============================================================================
# UPDATE DATABASE
# ============================================================================

log "Updating database..."

# Insert signals for each dimension
python3 << PYEOF
import json, sqlite3, uuid

data = json.loads('''$DELTA_RESPONSE''')
db = sqlite3.connect("$HYDRA_DB")

for dim, info in data["dimensions"].items():
    db.execute(
        "INSERT INTO life_signals (id, date, dimension, direction, signal_type, note) VALUES (?, ?, ?, ?, 'computed', ?)",
        (uuid.uuid4().hex, "$DATE", dim, info["direction"], info["summary"])
    )

# Score last week's commitments
for sc in data.get("scored_commitments", []):
    db.execute(
        "UPDATE life_commitments SET score = ?, scored_at = datetime('now'), updated_at = datetime('now') WHERE week = ? AND commitment LIKE ?",
        (sc["score"], "$WEEK", f"%{sc['commitment'][:40]}%")
    )

# Next week
from datetime import date, timedelta
next_week_date = date.fromisoformat("$DATE") + timedelta(days=7)
next_week = next_week_date.strftime("%G-W%V")

# Insert new commitments for next week
for c in data.get("new_commitments", []):
    db.execute(
        "INSERT INTO life_commitments (id, week, dimension, commitment, source) VALUES (?, ?, ?, ?, 'delta_engine')",
        (uuid.uuid4().hex, next_week, c["dimension"], c["commitment"])
    )

db.commit()
db.close()
print("Database updated")
PYEOF

log "Database updated"

# ============================================================================
# SEND TELEGRAM SUMMARY
# ============================================================================

log "Sending Telegram summary..."

# Build summary
SUMMARY="Life Delta -- Week $WEEK

Net: $NET_STATUS"

# Add dimension summaries
for DIM in architect space rhythm financial physical connection; do
    DIR=$(echo "$DELTA_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['dimensions']['$DIM']['direction'])")
    case "$DIR" in
        converging) ARROW="-->" ;;
        diverging) ARROW="<--" ;;
        *) ARROW="---" ;;
    esac
    SUMMARY+="
$ARROW $DIM"
done

SUMMARY+="

$SUBJECTIVE_Q"

"$NOTIFY" "info" "Life Delta" "$SUMMARY" 2>/dev/null || true

# Mark as sent
touch "$SENT_FLAG"

log "=== Life delta engine complete ==="
