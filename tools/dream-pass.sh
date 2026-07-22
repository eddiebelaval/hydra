#!/bin/bash
# dream-pass.sh — Nightly memory-synthesis "dreaming" pass (ADVISORY ONLY).
#
# Runs daily at 3:00am via launchd (after hydra-reflector 2am, before the
# 9am wake-jobs). Reads the three knowledge layers — FIELD_NOTES timeline,
# the memory/ topic files, the knowledge/ KB index — plus git activity and
# the project-staleness classification, and asks Claude (sonnet, via
# `claude -p`) to surface cross-day, cross-layer findings in 5 lenses:
# contradictions, stale doctrines, merge candidates, memory<->KB gaps, and
# doctrine-vs-reality drift.
#
# It NEVER edits memory/ or FIELD_NOTES. It writes one synthesis report to
# ~/.claude/dream/ and pings the presence commons. Importance-gated: if not
# enough material accreted since the last run, it no-ops without spending an
# LLM pass. Silent when zero findings.
#
# Conventions mirror ~/.hydra/tools/auto-journal-reconcile.sh.

set -uo pipefail

# Tend contract (TEND-CONTRACT.md): self-report on every exit so the Gardener
# reads dream-pass by its own word, not by a launchd exit code.
source "$HOME/.hydra/tools/tend-lib.sh" 2>/dev/null || true
trap 'rc=$?; if [ "$rc" -eq 0 ]; then tend_report dream-pass GREEN "dream pass complete" 24; else tend_report dream-pass RED "exited $rc" 24 "dream pass failed (exit $rc)" "read the dream log; owns its lane"; fi' EXIT

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MODEL="sonnet"                       # nightly cost discipline
ID8="$HOME/Development/id8"
FIELD_NOTES="$ID8/FIELD_NOTES.md"
MEMORY_DIR="$HOME/.claude/projects/-Users-eddiebelaval-Development-id8/memory"
MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
KB_DIR="$ID8/knowledge"
STALENESS_LOG_DIR="$HOME/Library/Logs/claude-automation/project-staleness"

DREAM_DIR="$HOME/.claude/dream"
PROMPT_FILE="$DREAM_DIR/prompt.md"
STATE_FILE="$DREAM_DIR/state.json"
RUNS_LOG="$DREAM_DIR/runs.jsonl"
SAY="$HOME/.claude/presence/say"

LOG_DIR="$HOME/Library/Logs/dream-pass"
DATE=$(date +%Y-%m-%d)
NOW_ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')
LOG_FILE="$LOG_DIR/$DATE.log"

# Importance-gate thresholds (proceed if ANY clears)
GATE_MIN_NEW_MEMORY=1                 # >=1 new/changed memory file
GATE_MIN_FIELDNOTE_LINES=3            # >=3 new FIELD_NOTES lines
GATE_MIN_COMMITS=8                    # >=8 id8 commits since last run

KB_INDEX_CAP=200                      # max KB files to index
FINDING_CAP=12                        # mirrored in prompt; informational here
HOT_MAX=40                            # newest-by-mtime memory files get full bodies; rest indexed
MAX_INPUT_BYTES=520000                # ~130k tokens; hard guard below model ceiling

mkdir -p "$DREAM_DIR" "$LOG_DIR"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG_FILE"; }

# Append one record to the audit log (always, on every path)
runlog() {
    # $1 gate decision, $2 findings count, $3 reason
    printf '{"ts":"%s","gate":"%s","findings":%s,"model":"%s","reason":"%s"}\n' \
        "$NOW_ISO" "$1" "$2" "$MODEL" "$3" >> "$RUNS_LOG"
}

# Persist state for the next run's delta
write_state() {
    local fn_lines
    fn_lines=$(wc -l < "$FIELD_NOTES" 2>/dev/null | tr -d ' ')
    [[ -z "$fn_lines" ]] && fn_lines=0
    printf '{"lastRun":"%s","fieldNotesLines":%s}\n' "$NOW_ISO" "$fn_lines" > "$STATE_FILE"
}

log "=== DREAM pass starting ($DATE) ==="

if ! command -v claude >/dev/null 2>&1; then
    log "ERROR: claude CLI missing; aborting"
    runlog "error" 0 "claude-cli-missing"
    exit 1
fi
if [[ ! -s "$PROMPT_FILE" ]]; then
    log "ERROR: prompt file missing at $PROMPT_FILE; aborting"
    runlog "error" 0 "prompt-missing"
    exit 1
fi

# ---------------------------------------------------------------------------
# Importance gate
# ---------------------------------------------------------------------------
LAST_RUN=""
PREV_FN_LINES=0
if [[ -s "$STATE_FILE" ]]; then
    LAST_RUN=$(jq -r '.lastRun // ""' "$STATE_FILE" 2>/dev/null)
    PREV_FN_LINES=$(jq -r '.fieldNotesLines // 0' "$STATE_FILE" 2>/dev/null)
fi

PROCEED=0
GATE_REASON=""
if [[ -z "$LAST_RUN" ]]; then
    PROCEED=1
    GATE_REASON="first-run"
else
    NEW_MEMORY=$(find "$MEMORY_DIR" -name '*.md' -newermt "$LAST_RUN" 2>/dev/null | wc -l | tr -d ' ')
    [[ -z "$NEW_MEMORY" ]] && NEW_MEMORY=0

    CUR_FN_LINES=$(wc -l < "$FIELD_NOTES" 2>/dev/null | tr -d ' ')
    [[ -z "$CUR_FN_LINES" ]] && CUR_FN_LINES=0
    FN_DELTA=$(( CUR_FN_LINES - PREV_FN_LINES ))
    [[ $FN_DELTA -lt 0 ]] && FN_DELTA=0

    COMMITS=$(git -C "$ID8" log --oneline --since="$LAST_RUN" 2>/dev/null | wc -l | tr -d ' ')
    [[ -z "$COMMITS" ]] && COMMITS=0

    log "gate deltas: new_memory=$NEW_MEMORY fieldnote_lines=$FN_DELTA commits=$COMMITS"

    if [[ $NEW_MEMORY -ge $GATE_MIN_NEW_MEMORY ]]; then
        PROCEED=1; GATE_REASON="new_memory=$NEW_MEMORY"
    elif [[ $FN_DELTA -ge $GATE_MIN_FIELDNOTE_LINES ]]; then
        PROCEED=1; GATE_REASON="fieldnote_lines=$FN_DELTA"
    elif [[ $COMMITS -ge $GATE_MIN_COMMITS ]]; then
        PROCEED=1; GATE_REASON="commits=$COMMITS"
    else
        GATE_REASON="below-threshold(mem=$NEW_MEMORY,fn=$FN_DELTA,commits=$COMMITS)"
    fi
fi

if [[ $PROCEED -eq 0 ]]; then
    log "no-op: $GATE_REASON"
    runlog "noop" 0 "$GATE_REASON"
    write_state
    exit 0
fi
log "proceeding: $GATE_REASON"

# ---------------------------------------------------------------------------
# Assemble context
# ---------------------------------------------------------------------------
INPUT="$DREAM_DIR/.input-$DATE.md"
OUT_JSON="$DREAM_DIR/.out-$DATE.json"

{
    cat "$PROMPT_FILE"
    echo
    echo "=== CONTEXT HEADER ==="
    echo "Current date: $DATE"
    echo

    echo "=== FIELD_NOTES (trailing 60 days) ==="
    if [[ -s "$FIELD_NOTES" ]]; then cat "$FIELD_NOTES"; else echo "(missing)"; fi
    echo

    echo "=== MEMORY INDEX (MEMORY.md) ==="
    if [[ -s "$MEMORY_INDEX" ]]; then cat "$MEMORY_INDEX"; else echo "(missing)"; fi
    echo

    # Tiered: the HOT_MAX most-recently-modified files get full bodies — that
    # is where new contradictions/drift live. The rest get filename+description
    # only (their gist is already in MEMORY.md). Newest-by-mtime (not a date
    # cutoff) bounds size deterministically even after a bulk memory reorg
    # touches every file. memory/ filenames are kebab-case (no spaces), so the
    # ls -t line-list is safe.
    ALL_SORTED=$(ls -t "$MEMORY_DIR"/*.md 2>/dev/null | grep -v '/MEMORY\.md$')
    HOT_LIST=$(printf '%s\n' "$ALL_SORTED" | head -n "$HOT_MAX")
    COLD_LIST=$(printf '%s\n' "$ALL_SORTED" | tail -n +"$((HOT_MAX + 1))")

    echo "=== MEMORY TOPIC FILES — HOT (newest $HOT_MAX by mtime, full) ==="
    hot_n=0
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        echo "--- $(basename "$f") ---"
        cat "$f"
        echo
        hot_n=$((hot_n + 1))
    done <<< "$HOT_LIST"
    echo "(hot files: $hot_n)"
    echo

    echo "=== MEMORY TOPIC FILES — COLD (index only: name + description) ==="
    cold_n=0
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        desc=$(grep -m1 '^description:' "$f" 2>/dev/null | sed 's/^description:[[:space:]]*//')
        echo "$(basename "$f") — ${desc:-(no description)}"
        cold_n=$((cold_n + 1))
    done <<< "$COLD_LIST"
    echo "(cold files: $cold_n)"
    echo

    echo "=== KB INDEX (knowledge/) ==="
    if [[ -d "$KB_DIR" ]]; then
        kb_count=0
        while IFS= read -r kf; do
            [[ -z "$kf" ]] && continue
            title=$(grep -m1 '^# ' "$kf" 2>/dev/null | sed 's/^# //')
            rel=${kf#"$ID8"/}
            echo "$rel — ${title:-(untitled)}"
            kb_count=$((kb_count+1))
            [[ $kb_count -ge $KB_INDEX_CAP ]] && break
        done < <(find "$KB_DIR" -name '*.md' 2>/dev/null)
        echo "(KB files indexed: $kb_count; cap $KB_INDEX_CAP)"
    else
        echo "(missing)"
    fi
    echo

    echo "=== GIT ACTIVITY (id8, 7d) ==="
    git -C "$ID8" log --oneline --since="7 days ago" 2>/dev/null | head -50 || echo "(none)"
    echo

    echo "=== PROJECT STALENESS (repo classification) ==="
    latest_report=$(ls -t "$STALENESS_LOG_DIR"/report-*.md 2>/dev/null | head -1)
    if [[ -n "$latest_report" && -s "$latest_report" ]]; then
        cat "$latest_report"
    else
        echo "(no staleness report found)"
    fi
} > "$INPUT"

INPUT_BYTES=$(wc -c < "$INPUT" | tr -d ' ')
log "assembled context: $INPUT_BYTES bytes -> $INPUT"
if [[ "$INPUT_BYTES" -gt "$MAX_INPUT_BYTES" ]]; then
    log "ERROR: context $INPUT_BYTES exceeds MAX_INPUT_BYTES $MAX_INPUT_BYTES — refusing to invoke (tune HOT_DAYS/KB_INDEX_CAP)"
    runlog "error" 0 "context-too-large-$INPUT_BYTES"
    write_state
    mv -f "$INPUT" "$DREAM_DIR/.last-oversized-input.md" 2>/dev/null
    exit 1
fi

# ---------------------------------------------------------------------------
# Invoke Claude
# ---------------------------------------------------------------------------
claude -p --model "$MODEL" --output-format json < "$INPUT" > "$OUT_JSON" 2>>"$LOG_FILE"
CLAUDE_RC=$?
if [[ $CLAUDE_RC -ne 0 || ! -s "$OUT_JSON" ]]; then
    log "ERROR: claude failed (rc=$CLAUDE_RC) or empty output"
    runlog "error" 0 "claude-rc-$CLAUDE_RC"
    write_state
    exit 1
fi

RESULT=$(jq -r '.result // empty' "$OUT_JSON" 2>/dev/null)
if [[ -z "$RESULT" ]]; then
    log "ERROR: could not extract .result from claude output"
    runlog "error" 0 "no-result-field"
    write_state
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse findings count + write synthesis
# ---------------------------------------------------------------------------
FIRST_LINE=$(printf '%s\n' "$RESULT" | head -1)
N=$(printf '%s' "$FIRST_LINE" | sed -n 's/^FINDINGS:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[[ -z "$N" ]] && N=0

if [[ "$N" -eq 0 ]]; then
    log "0 findings — silent"
    runlog "proceed" 0 "$GATE_REASON"
    write_state
    mv -f "$OUT_JSON" "$DREAM_DIR/.last-out.json" 2>/dev/null
    rm -f "$INPUT"
    exit 0
fi

SYNTH_FILE="$DREAM_DIR/synthesis-$DATE.md"
# Strip the FINDINGS: sentinel line + any leading blank lines, keep the body.
# (awk 'NF{f=1}f' = skip leading blanks, then print the rest — BSD/GNU portable.)
printf '%s\n' "$RESULT" | tail -n +2 | awk 'NF{f=1} f' > "$SYNTH_FILE"
log "wrote $N findings -> $SYNTH_FILE"
runlog "proceed" "$N" "$GATE_REASON"
write_state

# ---------------------------------------------------------------------------
# Surface via presence commons
# ---------------------------------------------------------------------------
if [[ -x "$SAY" ]]; then
    "$SAY" "DREAM: $N findings ready for review" \
        -m thinking -a 1 -f dream \
        -s "$SYNTH_FILE" >> "$LOG_FILE" 2>&1 || log "presence say failed (non-fatal)"
else
    log "presence say not found at $SAY (skipped)"
fi

mv -f "$OUT_JSON" "$DREAM_DIR/.last-out.json" 2>/dev/null
rm -f "$INPUT"
log "=== DREAM pass complete: $N findings ==="
exit 0
