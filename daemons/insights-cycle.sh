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
MEMORY_MD="$HOME/.claude/projects/-Users-eddiebelaval-Development-id8/memory/MEMORY.md"

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
mkdir -p "$(dirname "$LOCK_DIR")"
if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_FILE"
else
    # The winner writes its PID just AFTER its mkdir. An empty pid file usually means
    # "a run started this instant", not "a run crashed": wait for it before judging.
    OLD_PID=""
    for _ in 1 2 3 4 5 6; do
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        [ -n "$OLD_PID" ] && break
        sleep 0.5
    done
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "ERROR: Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
    if [ -z "$OLD_PID" ] && [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
        log "Lock held (PID not yet written, lock < 5 min old). Exiting."
        exit 0
    fi
    # Steal atomically: only one contender's rename of the stale dir can succeed, so a
    # second reaper can never `rm -rf` the lock the first one just re-took.
    STALE="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$STALE" 2>/dev/null; then
        if [ "$(cat "$STALE/pid" 2>/dev/null || echo "")" != "$OLD_PID" ]; then
            mv "$STALE" "$LOCK_DIR" 2>/dev/null || rm -rf "$STALE"
            log "Lock re-taken by another instance. Exiting."
            exit 0
        fi
        rm -rf "$STALE"
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "Lost the lock race on retry. Exiting."
        exit 0
    fi
    echo $$ > "$LOCK_FILE"
fi
# Tend Contract self-report (~/.hydra/tend/TEND-CONTRACT.md), merged into the
# existing lock-release trap — a second `trap ... EXIT` would silently REPLACE
# this one and leak the lock. Switched to single quotes so $? evaluates at exit
# rather than at trap-definition time; LOCK_DIR is assigned once (line 17), so it
# resolves identically either way. rc is captured BEFORE rm overwrites $?.
# Cadence 360h: this job runs on the 1st and the 15th.
source "$HOME/.hydra/tools/tend-lib.sh" 2>/dev/null || true
trap 'rc=$?; [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"; if [ "$rc" -eq 0 ]; then tend_report insights-cycle GREEN "insights cycle complete" 360; else tend_report insights-cycle RED "exited $rc" 360 "insights cycle failed (exit $rc)" "read the insights-cycle log; owns its lane"; fi' EXIT

# Bill this job to metered API usage instead of Eddie's interactive Claude
# subscription (2026-07-31). Sourced AFTER the tend trap on purpose: the loader
# hard-exits 78 when the Keychain key is missing, and we want that to arrive as
# a RED tend report rather than a silent death. Disables claude.ai connectors —
# fine here, /insights reads local usage data off disk, not Gmail or Slack.
source "$HOME/.claude/id8labs-sub.env"  # 2026-08-17: id8labs SUBSCRIPTION (was metered API via automation.env)

log "=== Insights Cycle Started ==="
log "Date: $DATE"

# --- Phase 1: Generate Insights Report ---
# FIX 2026-11-05 (OPS). Until now Phase 1 ran /insights inside the id8labs config dir that the loader
# above exports, so it analyzed only the id8labs account's sessions (about 2% of Eddie's activity) and
# wrote its report THERE, while the check below looked at ~/.claude/usage-data/report.html, found the
# old Oct 15 file, only warned, and Phase 2 internalized that stale report (Nov 1 cycle: "unchanged").
# Now: /insights runs in a fresh config dir whose projects/ and usage-data/ point at the MAIN account's
# data, with NO stored login in it, so the only credential it can use is the id8labs token (billing
# stays off Eddie's personal subscription, same pattern as ~/.hydra/bin/id8-token). The report path
# /insights prints is then verified to sit in the main usage-data folder and to be written during this
# run; anything else stops the cycle with an alert BEFORE Phase 2 can read a stale report.
log "Phase 1: Generating insights report over the main account's sessions..."

phase1_fail() {
    log "Phase 1: ERROR — $1"
    "$NOTIFY" high "Insights Cycle" "Phase 1 failed: $1. Nothing was internalized. Log: $LOGFILE" 2>/dev/null || true
    exit 1
}

[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || phase1_fail "no id8labs token from id8labs-sub.env, refusing to bill the personal account"
[ -d "$HOME/.claude/projects" ] || phase1_fail "main account sessions folder missing: $HOME/.claude/projects"
mkdir -p "$INSIGHTS_DATA"
P1_DIR="$(mktemp -d "${TMPDIR:-/tmp}/insights-p1.XXXXXX")"
ln -s "$HOME/.claude/projects" "$P1_DIR/projects"
ln -s "$INSIGHTS_DATA" "$P1_DIR/usage-data"
P1_START=$(date +%s)
P1_OUT="$LOG_DIR/phase1-output-${DATE}.log"
if CLAUDE_CONFIG_DIR="$P1_DIR" claude -p --model "$("$HOME/.hydra/bin/hydra-llm" model mid --lane sub)" "/insights" \
    --allowedTools "Read,Glob,Grep,Bash,Write,WebFetch" > "$P1_OUT" 2>&1; then
    log "Phase 1: /insights exited 0"
else
    log "Phase 1: WARNING — /insights returned non-zero; verifying its report anyway"
fi
rm -f "$P1_DIR/projects" "$P1_DIR/usage-data"
rm -rf "$P1_DIR"

# The report /insights says it wrote, mapped back from the temp dir to the real usage-data folder.
# "|| true": no match must reach phase1_fail below, not kill the run silently under pipefail.
P1_REPORT=$(grep -o 'file://[^ ]*report[^ ]*\.html' "$P1_OUT" | tail -n 1 | sed 's|^file://||' || true)
[ -n "$P1_REPORT" ] || phase1_fail "/insights printed no report path (see $P1_OUT)"
# Map by the temp dir's own name: TMPDIR on macOS ends in "/", so the printed path can carry "//".
P1_NAME="$(basename "$P1_DIR")"
case "$P1_REPORT" in
    */"$P1_NAME"/usage-data/*) P1_REPORT="$INSIGHTS_DATA/${P1_REPORT##*/"$P1_NAME"/usage-data/}" ;;
esac
case "$P1_REPORT" in
    "$INSIGHTS_DATA"/*) ;;
    *) phase1_fail "report written outside the main usage-data folder: $P1_REPORT" ;;
esac
[ -f "$P1_REPORT" ] || phase1_fail "report path does not exist: $P1_REPORT"
[ "$(stat -f %m "$P1_REPORT")" -ge "$P1_START" ] || phase1_fail "report is older than this run (stale): $P1_REPORT"
INSIGHTS_REPORT="$P1_REPORT"
log "Phase 1: Report verified fresh: $INSIGHTS_REPORT"
if [ "${PHASE1_ONLY:-0}" = "1" ]; then
    log "PHASE1_ONLY=1: stopping before internalization"
    exit 0
fi

# --- Phase 2: Internalize Findings ---
log "Phase 2: Internalizing insights..."

# Snapshot current state for diff
CLAUDE_MD_BEFORE=$(md5 -q "$CLAUDE_MD" 2>/dev/null || echo "none")
MEMORY_MD_BEFORE=$(md5 -q "$MEMORY_MD" 2>/dev/null || echo "none")
SKILLS_BEFORE=$(ls -1 "$HOME/.claude/skills/" | wc -l | tr -d ' ')

# Run Claude headless to read the report and internalize
# WARNING: NO APOSTROPHES IN THIS HEREDOC BODY. macOS ships bash 3.2, and 3.2
# mis-parses a quoted heredoc nested inside $( ) inside " " — a single apostrophe
# in the body makes the WHOLE FILE a syntax error, so the job dies before its
# first line runs. That is exactly what happened here: a "don't" on the line
# below silently bricked this job (found 2026-07-31). Write "do not".
INTERNALIZE_PROMPT="$(cat <<'PROMPT'
You are running as an automated insights internalization job (HYDRA insights-cycle).

Your task:
1. Read the insights report at ~/.claude/usage-data/report.html
2. Read the facets data at ~/.claude/usage-data/facets/ (read all JSON files there)
3. Read the current CLAUDE.md at ~/.claude/CLAUDE.md
4. Read the current MEMORY.md at ~/.claude/projects/-Users-eddiebelaval-Development-id8/memory/MEMORY.md

Then:
A. COMPARE the new friction patterns against the existing "Behavioral Rules" section in CLAUDE.md.
   - If there are NEW friction patterns not already covered by existing rules, ADD them.
   - If an existing rule is no longer relevant (friction count dropped to 0), note it but do NOT remove it yet.
   - If an existing rule needs updating (new data changes the recommendation), UPDATE it.

B. UPDATE MEMORY.md:
   - Update the "Insights Report" section with the new date and findings.
   - Update friction counts with new numbers.
   - Note any new skills created or rules added.

C. CHECK if the report suggests new skills/workflows that do not exist yet.
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

# Point Phase 2 at the report Phase 1 just verified (the heredoc above names the usual path).
INTERNALIZE_PROMPT="$INTERNALIZE_PROMPT

This cycle's verified report is at $INSIGHTS_REPORT (fresh this run). Read that file for step 1."

if claude -p --model "$("$HOME/.hydra/bin/hydra-llm" model mid --lane sub)" "$INTERNALIZE_PROMPT" \
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
