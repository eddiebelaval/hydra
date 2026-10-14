#!/bin/bash
# journey-append.sh - Append session notes to JOURNEY.md
#
# Usage:
#   journey-append.sh "Session summary text"
#   journey-append.sh --polish "raw note text to refine"
#
# Inserts a new ### YYYY-MM-DD - Session Note entry before the
# "## What's Next" section in JOURNEY.md. With --polish, uses
# Claude Haiku to refine the note into JOURNEY.md's narrative tone.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

JOURNEY_FILE="$HOME/.hydra/JOURNEY.md"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-brain-updater"
LOG_FILE="$LOG_DIR/journey-append.log"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

POLISH=false
NOTE_TEXT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --polish)
            POLISH=true
            shift
            ;;
        *)
            NOTE_TEXT="$1"
            shift
            ;;
    esac
done

if [[ -z "$NOTE_TEXT" ]]; then
    echo "Usage: journey-append.sh [--polish] \"Session summary text\""
    echo ""
    echo "Options:"
    echo "  --polish   Use Claude Haiku to refine into JOURNEY.md narrative tone"
    exit 1
fi

if [[ ! -f "$JOURNEY_FILE" ]]; then
    echo "ERROR: JOURNEY.md not found at $JOURNEY_FILE"
    exit 1
fi

log "Starting journey append (polish=$POLISH)"
log "Raw note: ${NOTE_TEXT:0:100}..."

# ============================================================================
# POLISH WITH HAIKU (optional)
# ============================================================================

polish_with_haiku() {
    local raw_text="$1"

    export HAIKU_RAW_TEXT="$raw_text"
    export HYDRA_ROOT="${HYDRA_ROOT:-$HOME/.hydra}"

    local polished=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.join(os.environ["HYDRA_ROOT"], "lib"))
from hydra_llm import complete

raw_text = os.environ.get("HAIKU_RAW_TEXT", "")

system_prompt = """You are editing a living document called JOURNEY.md that tells the story of Eddie Belaval building id8Labs. The document uses third-person narrative with a reflective, specific tone.

Take the user's raw session note and refine it into 2-4 sentences that fit JOURNEY.md's style:
- Third person ("Eddie shipped..." not "I shipped...")
- Specific details (project names, features, tools)
- Reflective but concise
- No bullet points, just prose paragraphs

Return ONLY the refined text, no explanation or quotes."""

# Gateway call (docs/LLM-GATEWAY.md). Any failure or skip keeps the raw text.
try:
    print(complete("journey-append", raw_text, system=system_prompt,
                   task="write", tier="small", max_tokens=300, timeout=60) or raw_text)
except Exception as e:
    print(raw_text)
    print(f"LLM unavailable, keeping raw text: {e}", file=sys.stderr)
PYEOF
)

    if [[ -n "$polished" ]]; then
        echo "$polished"
    else
        log "Polish returned empty, using raw text"
        echo "$raw_text"
    fi
}

FINAL_TEXT="$NOTE_TEXT"
if [[ "$POLISH" == "true" ]]; then
    log "Polishing with Haiku..."
    FINAL_TEXT=$(polish_with_haiku "$NOTE_TEXT")
    log "Polished: ${FINAL_TEXT:0:100}..."
fi

# ============================================================================
# INSERT INTO JOURNEY.MD
# ============================================================================

# Build the new entry block
NEW_ENTRY="### ${DATE} - Session Note

${FINAL_TEXT}
"

export JOURNEY_FILE
export NEW_ENTRY

python3 << 'PYEOF'
import os, sys

journey_path = os.environ["JOURNEY_FILE"]
new_entry = os.environ["NEW_ENTRY"]

with open(journey_path, "r") as f:
    content = f.read()

# Primary insertion point: before "## What's Next"
marker = "## What's Next"
if marker in content:
    idx = content.index(marker)
    # Insert new entry with separating newlines
    updated = content[:idx] + new_entry + "\n" + content[idx:]
else:
    # Fallback: before the closing italics line
    fallback = "*This document is alive"
    if fallback in content:
        idx = content.index(fallback)
        updated = content[:idx] + new_entry + "\n" + content[idx:]
    else:
        # Last resort: append to end
        updated = content + "\n" + new_entry

with open(journey_path, "w") as f:
    f.write(updated)

print(f"Inserted entry before '{marker}'" if marker in content else "Inserted entry (fallback)")
PYEOF

log "Entry appended to JOURNEY.md"
echo "Journey entry added for $DATE"
