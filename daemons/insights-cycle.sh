#!/bin/bash
set -euo pipefail

# ============================================================================
# HYDRA Insights Cycle — Recursive Self-Improvement Loop
# Runs on 1st and 15th of every month
#
# Phase 1: Generate insights report from usage data
# Phase 2: Internalize findings — update CLAUDE.md, MEMORY.md, create skills
# Phase 3: Notify Eddie via Telegram with summary
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-insights-cycle"
LOCK_DIR="$HYDRA_ROOT/state/insights-cycle.lock"
LOCK_FILE="$LOCK_DIR/pid"

INSIGHTS_DATA="$HOME/.claude/usage-data"
INSIGHTS_REPORT="$INSIGHTS_DATA/report.html"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
MEMORY_MD="$HOME/.claude/projects/-Users-eddiebelaval-Development/memory/MEMORY.md"

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOGFILE="$LOG_DIR/insights-cycle-${DATE}.log"

mkdir -p "$LOG_DIR"

# --- Logging ---
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"
    echo "[$(date '+%H:%M:%S')] $1"
}

# --- Lock (prevent concurrent runs) ---
if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_FILE"
else
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "ERROR: Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null
    echo $$ > "$LOCK_FILE"
fi
trap "rm -rf '$LOCK_DIR'" EXIT

log "=== Insights Cycle Started ==="
log "Date: $DATE"

# --- Phase 1: Generate Insights Report ---
log "Phase 1: Generating insights report..."

# Run claude headless to generate insights
# The /insights command analyzes usage data and produces report.html
if claude -p "/insights" --allowedTools "Read,Glob,Grep,Bash,Write,WebFetch" \
    > "$LOG_DIR/phase1-output-${DATE}.log" 2>&1; then
    log "Phase 1: Insights report generated successfully"
else
    log "Phase 1: WARNING — Insights generation returned non-zero. Checking if report exists..."
fi

# Verify report was generated or updated
if [ -f "$INSIGHTS_REPORT" ]; then
    REPORT_AGE=$(( $(date +%s) - $(stat -f %m "$INSIGHTS_REPORT") ))
    if [ "$REPORT_AGE" -gt 3600 ]; then
        log "Phase 1: WARNING — Report file exists but is ${REPORT_AGE}s old (>1hr). May be stale."
    else
        log "Phase 1: Report confirmed fresh (${REPORT_AGE}s old)"
    fi
else
    log "Phase 1: ERROR — No report file found at $INSIGHTS_REPORT"
    "$NOTIFY" high "Insights Cycle" "Phase 1 failed: No insights report generated. Check logs at $LOGFILE" 2>/dev/null || true
    exit 1
fi

# --- Phase 2: Internalize Findings ---
log "Phase 2: Internalizing insights..."

# Snapshot current state for diff
CLAUDE_MD_BEFORE=$(md5 -q "$CLAUDE_MD" 2>/dev/null || echo "none")
MEMORY_MD_BEFORE=$(md5 -q "$MEMORY_MD" 2>/dev/null || echo "none")
SKILLS_BEFORE=$(ls -1 "$HOME/.claude/skills/" | wc -l | tr -d ' ')

# Run Claude headless to read the report and internalize
INTERNALIZE_PROMPT="$(cat <<'PROMPT'
You are running as an automated insights internalization job (HYDRA insights-cycle).

Your task:
1. Read the insights report at ~/.claude/usage-data/report.html
2. Read the facets data at ~/.claude/usage-data/facets/ (read all JSON files there)
3. Read the current CLAUDE.md at ~/.claude/CLAUDE.md
4. Read the current MEMORY.md at ~/.claude/projects/-Users-eddiebelaval-Development/memory/MEMORY.md

Then:
A. COMPARE the new friction patterns against the existing "Behavioral Rules" section in CLAUDE.md.
   - If there are NEW friction patterns not already covered by existing rules, ADD them.
   - If an existing rule is no longer relevant (friction count dropped to 0), note it but do NOT remove it yet.
   - If an existing rule needs updating (new data changes the recommendation), UPDATE it.

B. UPDATE MEMORY.md:
   - Update the "Insights Report" section with the new date and findings.
   - Update friction counts with new numbers.
   - Note any new skills created or rules added.

C. CHECK if the report suggests new skills/workflows that don't exist yet.
   - If so, create them in ~/.claude/skills/{name}/skill.md following existing patterns.
   - Only create skills for SPECIFIC, ACTIONABLE workflows — not vague suggestions.

D. UPDATE the session-log.md with an entry for this automated insights cycle.

E. OUTPUT a plain-text summary (no markdown) of exactly what changed:
   - Rules added/modified/unchanged count
   - Skills created (if any)
   - Top 3 friction patterns from this cycle
   - Comparison to previous cycle if data exists

Be precise. Do not add rules that duplicate existing ones. Do not create skills that overlap with existing ones.
PROMPT
)"

if claude -p "$INTERNALIZE_PROMPT" \
    --allowedTools "Read,Glob,Grep,Write,Edit,Bash" \
    > "$LOG_DIR/phase2-output-${DATE}.log" 2>&1; then
    log "Phase 2: Internalization completed successfully"
else
    log "Phase 2: WARNING — Internalization returned non-zero. Check phase2 log."
fi

# --- Measure what changed ---
CLAUDE_MD_AFTER=$(md5 -q "$CLAUDE_MD" 2>/dev/null || echo "none")
MEMORY_MD_AFTER=$(md5 -q "$MEMORY_MD" 2>/dev/null || echo "none")
SKILLS_AFTER=$(ls -1 "$HOME/.claude/skills/" | wc -l | tr -d ' ')

CLAUDE_MD_CHANGED="unchanged"
MEMORY_MD_CHANGED="unchanged"
SKILLS_CREATED=0

if [ "$CLAUDE_MD_BEFORE" != "$CLAUDE_MD_AFTER" ]; then
    CLAUDE_MD_CHANGED="updated"
fi
if [ "$MEMORY_MD_BEFORE" != "$MEMORY_MD_AFTER" ]; then
    MEMORY_MD_CHANGED="updated"
fi
SKILLS_CREATED=$(( SKILLS_AFTER - SKILLS_BEFORE ))

log "Phase 2 results:"
log "  CLAUDE.md: $CLAUDE_MD_CHANGED"
log "  MEMORY.md: $MEMORY_MD_CHANGED"
log "  New skills: $SKILLS_CREATED"

# --- Phase 3: Notify Eddie ---
log "Phase 3: Sending notification..."

# Extract the phase 2 summary (last 20 lines of output, trimmed)
SUMMARY=$(tail -20 "$LOG_DIR/phase2-output-${DATE}.log" 2>/dev/null | head -15 || echo "Check logs for details")

NOTIFICATION="Insights Cycle Complete ($DATE)

CLAUDE.md: $CLAUDE_MD_CHANGED
MEMORY.md: $MEMORY_MD_CHANGED
New skills: $SKILLS_CREATED

$SUMMARY

Full report: file://$INSIGHTS_REPORT
Logs: $LOGFILE"

# Create conversation thread for reply tracking
THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "insights-${DATE}")
EXPIRES=$(date -v+24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

sqlite3 "$HYDRA_DB" "
    INSERT OR IGNORE INTO conversation_threads (id, thread_type, state, context_data, expires_at)
    VALUES ('$THREAD_ID', 'insights_cycle', 'awaiting_input', '{\"date\":\"$DATE\"}', '$EXPIRES');
" 2>/dev/null || true

"$NOTIFY" normal "Insights Cycle" "$NOTIFICATION" "$INSIGHTS_REPORT" \
    --entity-type conversation_thread --entity-id "$THREAD_ID" 2>/dev/null || true

# Log activity to HYDRA database
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (activity_type, entity_type, entity_id, description, timestamp)
    VALUES ('insights_cycle', 'system', 'insights-$DATE',
            'Bi-monthly insights cycle: CLAUDE.md=$CLAUDE_MD_CHANGED, MEMORY.md=$MEMORY_MD_CHANGED, new_skills=$SKILLS_CREATED',
            '$TIMESTAMP');
" 2>/dev/null || true

log "=== Insights Cycle Complete ==="
log "Duration: ${SECONDS}s"
