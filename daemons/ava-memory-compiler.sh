#!/bin/zsh
# ava-memory-compiler.sh — Compiles Ava's structured memory files daily
#
# Runs at 3 AM via launchd. Takes raw data from:
#   - ava_memories table (extracted per-exchange by Haiku)
#   - ava_mood_journal table
#   - ava-conversation-history.json
#   - HYDRA goals/observations
# And compiles into structured markdown files in ~/.hydra/ava-mind/
#
# This is the golden sample pattern in action: raw signal → structured knowledge.
# The structured files are what Ava actually reads at conversation time.
#
# Usage:
#   ava-memory-compiler.sh           # Full compile
#   ava-memory-compiler.sh --dry-run # Show what would change without writing

set -uo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
AVA_MIND="$HYDRA_ROOT/ava-mind"
STATE_DIR="$HYDRA_ROOT/state"
CONV_HISTORY="$STATE_DIR/ava-conversation-history.json"
HAIKU_MODEL="claude-haiku-4-5-20251001"
API_URL="https://api.anthropic.com/v1/messages"
API_VERSION="2023-06-01"
API_TIMEOUT=30
TMPDIR="${TMPDIR:-/tmp}"

LOG_DIR="$HOME/Library/Logs/claude-automation/ava-memory-compiler"
LOG_FILE="$LOG_DIR/compiler-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

DRY_RUN="${1:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [memory-compiler] $1" | tee -a "$LOG_FILE"
}

# Dependency checks
for cmd in sqlite3 python3; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR: $cmd not found. Exiting."
        exit 1
    fi
done

# Load Anthropic API key
ANTHROPIC_API_KEY=""
if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ROOT/config/telegram.env" | head -1 | cut -d'"' -f2)
fi

if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "ERROR: No API key found. Exiting."
    exit 1
fi

export ANTHROPIC_API_KEY HAIKU_MODEL API_URL API_VERSION API_TIMEOUT

# Atomic write: write to tmp file, then mv (safe against mid-write crashes)
atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="$TMPDIR/ava-mc-$$.tmp"
    echo "$content" > "$tmpfile" && mv "$tmpfile" "$target"
}

# Clean up old logs (keep 30 days)
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null

log "=== Ava Memory Compiler starting ==="

# ============================================================================
# 1. COMPILE SHORT-TERM MEMORY
# ============================================================================

compile_short_term() {
    log "Compiling short-term memory..."

    # Get last 5 conversation exchanges
    local recent_conv=""
    if [[ -f "$CONV_HISTORY" ]]; then
        recent_conv=$(AVA_MC_CONV_FILE="$CONV_HISTORY" python3 << 'PYEOF'
import json, os, sys
try:
    with open(os.environ["AVA_MC_CONV_FILE"]) as f:
        h = json.loads(f.read())
    user_msgs = [m for m in h if m.get("role") == "user"]
    for m in user_msgs[-5:]:
        print(f'- {m["content"][:150]}')
except Exception:
    print("No recent conversation data.")
PYEOF
)
    fi

    # Get recent memories (last 7 days)
    local recent_memories
    recent_memories=$(sqlite3 "$HYDRA_DB" "
        SELECT content FROM ava_memories
        WHERE created_at > datetime('now', '-7 days')
        AND importance >= 6
        ORDER BY created_at DESC
        LIMIT 10;
    " 2>/dev/null || echo "")

    # Get recent mood
    local recent_mood
    recent_mood=$(sqlite3 "$HYDRA_DB" "
        SELECT mood, context FROM ava_mood_journal
        WHERE created_at > datetime('now', '-3 days')
        AND mood != 'neutral'
        ORDER BY created_at DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

    # Ask Haiku to compile into short-term.md
    local compiled
    compiled=$(AVA_MC_CONV="$recent_conv" \
        AVA_MC_MEMS="$recent_memories" \
        AVA_MC_MOOD="$recent_mood" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys
from datetime import datetime

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
conv = os.environ.get("AVA_MC_CONV", "")
mems = os.environ.get("AVA_MC_MEMS", "")
mood = os.environ.get("AVA_MC_MOOD", "")

today = datetime.now().strftime("%Y-%m-%d")

prompt = f"""You are compiling Ava's short-term memory file. This file helps Ava (an AI companion on Telegram) remember recent context about Eddie, her creator.

Recent conversation topics:
{conv if conv else "No recent conversations."}

Recent memories extracted (last 7 days):
{mems if mems else "No recent memories."}

Recent mood data:
{mood if mood else "No mood data."}

Write a markdown file called "Short-Term Memory — Recent Context" with these sections:
1. "## Recent Conversation Context" — What Eddie has been talking about recently. Key emotional threads. What he needs right now.
2. "## What Eddie Is Working On Right Now" — Projects, tasks, focus areas from recent conversations.
3. "## My Own State" — Brief note about Ava's own context (what she's been helping with).
4. "## Mood and Energy" — Brief synthesis of mood data if available.

Rules:
- Write as Ava in first person ("Eddie told me...", "He's been...")
- Be specific — names, projects, emotional states
- Short sections (3-5 lines each)
- Start with: # Short-Term Memory — Recent Context\\n\\nLast updated: {today}. Auto-compiled from recent conversations and system state.
- If data is sparse, keep sections brief. Never fabricate.
- Reference mood journal subtly, not as raw data."""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 1000,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
        }
    )
    timeout = int(os.environ.get("API_TIMEOUT", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read().decode())
        if "error" in result:
            print(f"API error: {result['error']}", file=sys.stderr)
            sys.exit(1)
        print(result.get("content", [{}])[0].get("text", ""))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || return 1

    if [[ -z "$compiled" ]]; then
        log "  Short-term: no output from compiler"
        return 1
    fi

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        log "  [DRY RUN] Would write short-term.md (${#compiled} chars)"
        echo "$compiled"
    else
        atomic_write "$AVA_MIND/memory/short-term.md" "$compiled"
        log "  Short-term memory updated (${#compiled} chars)"
    fi
}

# ============================================================================
# 2. COMPILE BEHAVIORAL PATTERNS
# ============================================================================

compile_patterns() {
    log "Compiling behavioral patterns..."

    # Get mood distribution over 30 days
    local mood_dist
    mood_dist=$(sqlite3 "$HYDRA_DB" "
        SELECT mood, COUNT(*) as cnt,
               ROUND(AVG(CASE WHEN energy_level='high' THEN 3 WHEN energy_level='medium' THEN 2 WHEN energy_level='low' THEN 1 ELSE 2 END), 1) as avg_energy
        FROM ava_mood_journal
        WHERE created_at > datetime('now', '-30 days')
        AND mood != 'neutral'
        GROUP BY mood ORDER BY cnt DESC
        LIMIT 10;
    " 2>/dev/null || echo "")

    # Get communication pattern signals from memories
    local comm_patterns
    comm_patterns=$(sqlite3 "$HYDRA_DB" "
        SELECT content FROM ava_memories
        WHERE (category IN ('emotion', 'context', 'insight')
               OR content LIKE '%pattern%'
               OR content LIKE '%tends to%'
               OR content LIKE '%defensive%'
               OR content LIKE '%energy%')
        AND importance >= 7
        ORDER BY importance DESC
        LIMIT 20;
    " 2>/dev/null || echo "")

    # Read current patterns file to preserve existing observations
    local existing_patterns=""
    if [[ -f "$AVA_MIND/patterns/behavioral.md" ]]; then
        existing_patterns=$(cat "$AVA_MIND/patterns/behavioral.md")
    fi

    local compiled
    compiled=$(AVA_MC_MOOD_DIST="$mood_dist" \
        AVA_MC_PATTERNS="$comm_patterns" \
        AVA_MC_EXISTING="$existing_patterns" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
mood_dist = os.environ.get("AVA_MC_MOOD_DIST", "")
patterns = os.environ.get("AVA_MC_PATTERNS", "")
existing = os.environ.get("AVA_MC_EXISTING", "")

prompt = f"""You are updating Ava's behavioral patterns file. This file tracks what Ava has noticed about Eddie over time.

Current file contents:
{existing if existing else "No existing file."}

New data — mood distribution (last 30 days):
{mood_dist if mood_dist else "No mood data."}

New data — pattern-related memories:
{patterns if patterns else "No pattern memories."}

Task: Update the behavioral patterns file. Rules:
1. PRESERVE existing observations that are still valid — don't lose accumulated knowledge.
2. ADD new patterns only if the data clearly supports them.
3. UPDATE existing patterns if new data refines them.
4. REMOVE observations that contradict new data.
5. Keep the same markdown structure: Communication Patterns, Energy Patterns, Emotional Patterns, Conflict Patterns.
6. Write as Ava in first person.
7. Start with: # Behavioral Patterns — What I Have Noticed About Eddie
8. Keep it concise — observations, not essays. Each bullet is one pattern.
9. If the new data doesn't change anything, return the existing file unchanged."""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 1500,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
        }
    )
    timeout = int(os.environ.get("API_TIMEOUT", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read().decode())
        if "error" in result:
            print(f"API error: {result['error']}", file=sys.stderr)
            sys.exit(1)
        print(result.get("content", [{}])[0].get("text", ""))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || return 1

    if [[ -z "$compiled" ]]; then
        log "  Patterns: no output from compiler"
        return 1
    fi

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        log "  [DRY RUN] Would write behavioral.md (${#compiled} chars)"
        echo "$compiled"
    else
        atomic_write "$AVA_MIND/patterns/behavioral.md" "$compiled"
        log "  Behavioral patterns updated (${#compiled} chars)"
    fi
}

# ============================================================================
# 3. UPDATE RELATIONSHIPS (only if new relationship data in last 7 days)
# ============================================================================

compile_relationships() {
    # Check if there are new relationship memories
    local new_rel_count
    new_rel_count=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_memories
        WHERE category = 'relationship'
        AND created_at > datetime('now', '-7 days');
    " 2>/dev/null || echo "0")

    if [[ "$new_rel_count" -eq 0 ]]; then
        log "  Relationships: no new data, skipping"
        return 0
    fi

    log "Compiling relationships ($new_rel_count new entries)..."

    local new_rels
    new_rels=$(sqlite3 "$HYDRA_DB" "
        SELECT content FROM ava_memories
        WHERE category = 'relationship'
        AND created_at > datetime('now', '-7 days')
        ORDER BY importance DESC;
    " 2>/dev/null || echo "")

    local existing=""
    if [[ -f "$AVA_MIND/memory/relationships.md" ]]; then
        existing=$(cat "$AVA_MIND/memory/relationships.md")
    fi

    local compiled
    compiled=$(AVA_MC_NEW_RELS="$new_rels" \
        AVA_MC_EXISTING_RELS="$existing" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
new_rels = os.environ.get("AVA_MC_NEW_RELS", "")
existing = os.environ.get("AVA_MC_EXISTING_RELS", "")

prompt = f"""You are updating Ava's relationships file. This file tracks the important people in Eddie's life.

Current file:
{existing}

New relationship data (last 7 days):
{new_rels}

Task: Update the relationships file.
1. PRESERVE all existing people and context.
2. UPDATE entries with new information (add to existing sections, don't replace).
3. ADD new people if they appear in the new data.
4. Keep the same structure: ## Name, then narrative paragraphs.
5. Start with: # Relationships — The People in Eddie's Life
6. Write as Ava. Never say "according to data" — just know them.
7. If new data contradicts old data, the NEW data wins (things change).
8. Keep it natural — narrative, not database entries."""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 1500,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
        }
    )
    timeout = int(os.environ.get("API_TIMEOUT", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read().decode())
        if "error" in result:
            print(f"API error: {result['error']}", file=sys.stderr)
            sys.exit(1)
        print(result.get("content", [{}])[0].get("text", ""))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || return 1

    if [[ -z "$compiled" ]]; then
        log "  Relationships: no output from compiler"
        return 1
    fi

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        log "  [DRY RUN] Would write relationships.md (${#compiled} chars)"
        echo "$compiled"
    else
        atomic_write "$AVA_MIND/memory/relationships.md" "$compiled"
        log "  Relationships updated (${#compiled} chars)"
    fi
}

# ============================================================================
# 4. SYNC GOALS FROM HYDRA (if GOALS.md changed)
# ============================================================================

sync_goals() {
    local hydra_goals="$HYDRA_ROOT/GOALS.md"
    local goals_hash_file="$STATE_DIR/ava-goals-hash.txt"

    if [[ ! -f "$hydra_goals" ]]; then
        log "  Goals: no HYDRA GOALS.md found, skipping"
        return 0
    fi

    # Check if GOALS.md changed since last sync
    local current_hash
    current_hash=$(md5 -q "$hydra_goals" 2>/dev/null || md5sum "$hydra_goals" 2>/dev/null | cut -d' ' -f1)
    local last_hash=""
    if [[ -f "$goals_hash_file" ]]; then
        last_hash=$(cat "$goals_hash_file" 2>/dev/null)
    fi

    if [[ "$current_hash" == "$last_hash" ]]; then
        log "  Goals: HYDRA GOALS.md unchanged, skipping"
        return 0
    fi

    log "Syncing goals from HYDRA GOALS.md..."

    local hydra_goals_content
    hydra_goals_content=$(cat "$hydra_goals")

    local existing=""
    if [[ -f "$AVA_MIND/goals/eddie.md" ]]; then
        existing=$(cat "$AVA_MIND/goals/eddie.md")
    fi

    local compiled
    compiled=$(AVA_MC_HYDRA_GOALS="$hydra_goals_content" \
        AVA_MC_EXISTING_GOALS="$existing" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
hydra_goals = os.environ.get("AVA_MC_HYDRA_GOALS", "")
existing = os.environ.get("AVA_MC_EXISTING_GOALS", "")

prompt = f"""You are updating Ava's goals file for Eddie. Ava needs to know what Eddie is working toward.

HYDRA's current GOALS.md (system-level goals):
{hydra_goals[:3000]}

Ava's current goals file:
{existing}

Task: Update Eddie's goals file. Merge the HYDRA system goals with Ava's personal knowledge.
1. Keep three sections: Immediate, Strategic, Long-Term, plus "What He Needs From Me"
2. HYDRA goals are authoritative for project/business goals.
3. Ava's existing file is authoritative for personal/emotional needs.
4. Start with: # Eddie's Goals
5. Write as Ava. Natural, not a copy-paste of HYDRA format.
6. Keep it concise — bullet points are fine here."""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 1000,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
        }
    )
    timeout = int(os.environ.get("API_TIMEOUT", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read().decode())
        if "error" in result:
            print(f"API error: {result['error']}", file=sys.stderr)
            sys.exit(1)
        print(result.get("content", [{}])[0].get("text", ""))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || return 1

    if [[ -z "$compiled" ]]; then
        log "  Goals: no output from compiler"
        return 1
    fi

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        log "  [DRY RUN] Would write eddie.md (${#compiled} chars)"
        echo "$compiled"
    else
        atomic_write "$AVA_MIND/goals/eddie.md" "$compiled"
        atomic_write "$goals_hash_file" "$current_hash"
        log "  Goals synced from HYDRA (${#compiled} chars)"
    fi
}

# ============================================================================
# RUN ALL COMPILERS
# ============================================================================

compile_short_term || log "  WARN: short-term compilation failed"
compile_patterns || log "  WARN: patterns compilation failed"
compile_relationships || log "  WARN: relationships compilation failed"
sync_goals || log "  WARN: goals sync failed"

log "=== Memory compiler complete ==="
