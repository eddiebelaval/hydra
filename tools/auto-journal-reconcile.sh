#!/bin/bash
# Auto-journal reconciler. Runs daily at 9am.
#
# Reads ~/.claude/auto-journal/pending.jsonl (the Stop hook's queue), groups
# entries by repo/cwd, and asks Claude (via `claude -p`) to file the day's
# notable items into the right destination — JOURNEY.md / FIELD_NOTES.md /
# the appropriate MEMORY.md feedback file.
#
# Strategy:
#   - Pending queue is the firehose. Most entries are noise.
#   - Claude reads the whole day at once and writes 3-7 distilled lines.
#   - After successful run: archive pending.jsonl to processed/YYYY-MM-DD.jsonl

set -uo pipefail

QUEUE_DIR="$HOME/.claude/auto-journal"
QUEUE_FILE="$QUEUE_DIR/pending.jsonl"
ARCHIVE_DIR="$QUEUE_DIR/processed"
LOG_DIR="$HOME/Library/Logs/auto-journal"
mkdir -p "$ARCHIVE_DIR" "$LOG_DIR"

DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$DATE.log"
PROMPT_FILE="$QUEUE_DIR/.reconcile-prompt.md"
PLAN_FILE="$QUEUE_DIR/.reconcile-plan.json"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG_FILE"; }

if [[ ! -s "$QUEUE_FILE" ]]; then
    log "queue empty"
    exit 0
fi

ENTRY_COUNT=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
log "reconciling $ENTRY_COUNT entries"

# Atomic rotate so the hook can keep writing while we work
WORKING="$QUEUE_DIR/working-$DATE.jsonl"
mv "$QUEUE_FILE" "$WORKING"

# Resolve the claude binary robustly: launchd runs with a minimal PATH that does
# NOT include ~/.local/bin (where the CLI installs), which silently killed this
# job from 2026-05-01 to 2026-06-16. Pin a known location as fallback.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_BIN="$HOME/.local/bin/claude"
fi
if [ -z "$CLAUDE_BIN" ]; then
    log "ERROR: claude CLI missing (PATH=$PATH); restoring queue"
    mv "$WORKING" "$QUEUE_FILE"
    exit 1
fi
log "using claude at $CLAUDE_BIN"

# Build prompt as a separate file (avoids heredoc-quote-shell pitfalls)
cat > "$PROMPT_FILE" <<'PROMPT_END'
You are the auto-journal reconciler. You receive a JSONL feed of "notable
event candidates" captured by a Stop hook from Claude Code sessions over
the last day. Distill them into 3-7 short journal entries and decide where
each one goes.

Rules:
- Most entries are NOISE. The hook captures anything mentioning signal
  keywords (shipped, decided, etc.) but most are casual usage. Drop noise.
- A real event is: a decision made, a system shipped, a pivot, a
  deprecation, an architectural realization, a partnership signal, a named
  lesson, a major bug fixed, an incident, or a stakeholder interaction.
- Group related entries from the same session/repo into ONE line.
- Default destination per repo:
    ~/clawd/projects/dae-v2/         -> {repo}/JOURNEY.md
    ~/Development/Homer/             -> Homer/JOURNEY.md
    ~/Development/mission-control/   -> mission-control/JOURNEY.md
    ~/Development/id8/               -> ~/Development/id8/FIELD_NOTES.md
                                        (NOT JOURNEY.md, that one is literary)
    cross-cutting / portfolio shifts -> ~/Development/id8/FIELD_NOTES.md
    named feedback rules             -> a new feedback memory file under
                                        ~/.claude/projects/-Users-eddiebelaval-Development-id8/memory/
- Each entry: ONE line, dated, past tense, with WHAT and WHY.
  Example:
    - "2026-04-30 — Sidelined v1 deepstack platform. v2 (clawd/dae-v2)
      is the live Kalshi bot. False alarm RED in /dae-health was reading
      v1's stale tables."

Output ONLY a JSON object (no markdown fence, no preamble):
{
  "summary": "one-sentence overview of the day",
  "entries": [
    {"file": "/abs/path.md", "line": "- 2026-MM-DD — ...", "why": "brief"}
  ],
  "dropped_count": N
}

If no real events: {"summary": "no notable events", "entries": [], "dropped_count": N}

JSONL feed follows below.
---
PROMPT_END

# Tier filter: feed high+medium-confidence entries (a real tool fired / file
# path / SHA). Include low-confidence (keyword-only chat) ONLY if the day is
# otherwise thin (<5 substantive entries), so a quiet day still gets journaled
# but a busy day doesn't drown the reconciler in 90% noise. Entries written
# before the confidence field existed (no key) are treated as substantive.
python3 - "$WORKING" >> "$PROMPT_FILE" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    rows.append((e.get("confidence", "high"), line))
substantive = [l for c, l in rows if c != "low"]
low = [l for c, l in rows if c == "low"]
feed = substantive if len(substantive) >= 5 else substantive + low
sys.stderr.write(f"tier-filter: {len(substantive)} substantive, {len(low)} low, feeding {len(feed)}\n")
print("\n".join(feed))
PY

# Run claude -p, write the wrapped JSON response
"$CLAUDE_BIN" -p --model claude-sonnet-5 --output-format json < "$PROMPT_FILE" > "$PLAN_FILE" 2>>"$LOG_FILE"

if [[ ! -s "$PLAN_FILE" ]]; then
    log "ERROR: claude returned empty; restoring queue"
    mv "$WORKING" "$QUEUE_FILE"
    exit 1
fi

# Extract the inner plan JSON from claude's wrapper, then file each entry
python3 - "$PLAN_FILE" "$LOG_FILE" <<'PY'
import json, os, re, sys
plan_path, log_path = sys.argv[1], sys.argv[2]

with open(plan_path) as f:
    raw = f.read()

# claude -p --output-format json wraps the result; unwrap it
try:
    outer = json.loads(raw)
    inner_str = outer.get("result") or raw
except Exception:
    inner_str = raw

m = re.search(r"\{.*\}", inner_str, re.DOTALL)
if not m:
    with open(log_path, "a") as lf:
        lf.write("ERROR: no JSON object in claude response\n")
        lf.write(raw[:2000] + "\n")
    sys.exit(1)

try:
    plan = json.loads(m.group(0))
except Exception as e:
    with open(log_path, "a") as lf:
        lf.write(f"ERROR: plan JSON unparseable: {e}\n")
    sys.exit(1)

with open(log_path, "a") as lf:
    lf.write(f"summary: {plan.get('summary','')}\n")
    lf.write(f"dropped_count: {plan.get('dropped_count',0)}\n")
    entries = plan.get("entries", [])
    lf.write(f"entries to file: {len(entries)}\n")
    filed = 0
    MEMORY_DIR = os.path.realpath(os.path.expanduser(
        "~/.claude/projects/-Users-eddiebelaval-Development-id8/memory"))

    # FIELD_NOTES belongs on main, not on whatever branch the primary worktree
    # happens to be parked on. Filed 2026-07-28: the portfolio journal had NEVER
    # been committed to main -- 832 lines of history were stranded on
    # feature/cma-pilots, because nightly-eod.sh commits to the CURRENT branch by
    # design (correct for a WIP safety net) and the primary worktree had sat on a
    # game-prototype branch for weeks. Delete that branch and the record goes too.
    #
    # Remapped HERE rather than in the routing prompt so a wrong model-emitted
    # path still lands correctly. Falls back to the original path if the main
    # worktree is ever removed, so this can never drop an entry on the floor.
    PRIMARY_FN = os.path.realpath(os.path.expanduser("~/Development/id8/FIELD_NOTES.md"))
    MAIN_WT_FN = os.path.expanduser(
        "~/Development/.worktrees/id8/id8pedia-live/FIELD_NOTES.md")

    for e in entries:
        path = os.path.expanduser(e.get("file", ""))
        if path and os.path.realpath(path) == PRIMARY_FN and os.path.exists(MAIN_WT_FN):
            path = MAIN_WT_FN
            lf.write(f"  remap -> main worktree (FIELD_NOTES lives on main)\n")
        line = e.get("line", "").rstrip()
        why = e.get("why", "")
        if not path or not line:
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        in_memory = os.path.realpath(os.path.dirname(path)) == MEMORY_DIR
        if in_memory and not os.path.exists(path):
            # Memory files get real frontmatter, NEVER the Field Notes template.
            # (2026-07-14 fix: raw journal-format files in memory/ are invisible
            # to the recurrence detector -- unsigned lessons are unconscious.)
            import re as _re
            slug = os.path.splitext(os.path.basename(path))[0]
            prefix = slug.split("_")[0]
            mtype = prefix if prefix in ("feedback", "project", "reference", "user") else "project"
            sig_m = _re.search(r"[Ss]ignatures?:\s*(.+)$", line)
            sigs = [s.strip().rstrip(".") for s in sig_m.group(1).split(",")] if sig_m else []
            desc = (why or line).replace("\n", " ").strip()[:150]
            fm = ["---", f"name: {slug}", f"description: {desc}", "metadata:", f"  type: {mtype}"]
            if sigs:
                fm.append("  signatures:")
                fm += [f'    - "{s}"' for s in sigs]
            fm.append("---")
            with open(path, "w") as nf:
                nf.write("\n".join(fm) + "\n\n")
        elif not os.path.exists(path):
            with open(path, "w") as nf:
                nf.write("# Field Notes\n\n_Auto-curated by the reconciler. One line per notable event._\n\n")
        with open(path, "a") as af:
            af.write(line + "\n")
            if in_memory and why:
                af.write(f"\n**Why:** {why}\n")
        filed += 1
        lf.write(f"  filed -> {path}: {line[:120]}\n")
        if why:
            lf.write(f"    why: {why}\n")
    lf.write(f"FILED_TOTAL: {filed}\n")
PY

PY_EXIT=$?
if [[ $PY_EXIT -ne 0 ]]; then
    log "ERROR: filing failed; restoring queue"
    mv "$WORKING" "$QUEUE_FILE"
    exit 1
fi

mv "$WORKING" "$ARCHIVE_DIR/$DATE.jsonl"
rm -f "$PROMPT_FILE" "$PLAN_FILE"
log "done. archived to $ARCHIVE_DIR/$DATE.jsonl"

FILED_COUNT=$(grep -c '  filed -> ' "$LOG_FILE" 2>/dev/null | head -1 | tr -d ' \n')
FILED_COUNT="${FILED_COUNT:-0}"
if [[ "$FILED_COUNT" =~ ^[0-9]+$ ]] && [[ "$FILED_COUNT" -gt 0 ]]; then
    NOTIF_MSG="$FILED_COUNT entries filed"
    osascript <<NOTIF_END
display notification "$NOTIF_MSG" with title "Auto-journal" sound name "Glass"
NOTIF_END
fi

exit 0
