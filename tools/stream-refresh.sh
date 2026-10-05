#!/bin/bash
# STREAM REFRESH: keeps THE STREAM (90Day) current, unattended, and heals it.
#
# Every run (launchd com.id8labs.stream-refresh, every 3h + RunAtLoad):
#   1. UPDATE the dedicated runner worktree to origin/main by HARD RESET. It used to
#      `merge --ff-only ... || true`; one stray snapshot commit made that fail silently
#      and the runner ran 2026-08-26 code for six weeks (found 2026-10-05).
#   2. INGEST new transcripts: corpus entries (backfill) AND the call files filed on
#      disk under lexicon/knowledge/90day/corpus (ingest-files). Since 2026-09 calls are
#      filed as files, so backfill alone saw nothing new for a month.
#   3. RECONCILE duplicate loops, only when something new landed (model cost on change).
#   4. HEAL once a day: close aged loops the later record settles (model, ~1 call per
#      thread with aged loops); RECOMPUTE every run so loops AGE at the real clock.
#   5. CACHE the digest the SessionStart hook reads.
# Anything that goes wrong (update failed, an ingest FAILED, a command errored) lands in
# ~/.claude/stream/health.txt, which the SessionStart hook prints above the digest.
# Cost-safe: a run with nothing new and heal already done today makes no model calls.
# See memory project-the-stream.

set -uo pipefail

LEX="$HOME/Development/.worktrees/lexicon/stream-runner"
LOG="$HOME/Library/Logs/id8labs-stream-refresh.log"
STATE="$HOME/.claude/stream"
HEALTH="$STATE/health.txt"
HEAL_STAMP="$STATE/.healed-on"
LOCK_STAMP="$STATE/.lockfile-sha"
mkdir -p "$(dirname "$LOG")" "$STATE"

STAMP="$(date '+%F %T')"
PROBLEMS=()
note() { PROBLEMS+=("$1"); }

cd "$LEX" 2>/dev/null || { echo "[$STAMP] stream-runner worktree missing" >> "$LOG"; echo "[$STAMP] STREAM: runner worktree missing ($LEX)" > "$HEALTH"; exit 0; }

# Put a node on PATH for launchd's bare environment (latest nvm install).
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1)"
[ -n "$NODE_BIN" ] && export PATH="$NODE_BIN:$PATH"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 1. UPDATE. The runner is dedicated: nothing in it is anyone's work, so reset, never merge.
if git fetch origin main --quiet 2>/dev/null; then
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  [ "$AHEAD" != "0" ] && git branch -f "runner-stray-$(date +%Y%m%d%H%M)" HEAD >/dev/null 2>&1  # keep strays, never lose them
  git reset --hard origin/main --quiet 2>/dev/null || note "reset to origin/main failed"
else
  note "git fetch failed; running $(git rev-parse --short HEAD) unchanged"
fi
LOCKSHA="$(shasum -a 256 package-lock.json 2>/dev/null | cut -c1-16)"
if [ -n "$LOCKSHA" ] && [ "$LOCKSHA" != "$(cat "$LOCK_STAMP" 2>/dev/null)" ]; then
  if npm ci --silent >/dev/null 2>&1; then echo "$LOCKSHA" > "$LOCK_STAMP"; else note "npm ci failed"; fi
fi

run() { npm run --silent stream -- "$@" 2>&1 | grep -vE 'dotenv'; }

# 2. INGEST: corpus entries, then files on disk.
BF="$(run backfill)"
IF="$(run ingest-files)"
NEW=$(( $(echo "$BF" | grep -cE '^ingest .* \{') + $(echo "$IF" | grep -cE '^ingest .* \{') ))
FAILS=$(( $(echo "$BF" | grep -c 'FAILED') + $(echo "$IF" | grep -c 'FAILED') ))
[ "$FAILS" -gt 0 ] && note "$FAILS ingest(s) FAILED (see $LOG)"
echo "$IF" | grep -q '^Error\|commands:' && note "ingest-files errored: $(echo "$IF" | grep -m1 -E '^Error|commands:' | cut -c1-120)"
CHANGED="$(echo "$IF" | grep -c 'CHANGED')"
[ "$CHANGED" -gt 0 ] && note "$CHANGED call file(s) re-filed with new text, not re-ingested (run ingest-files by hand)"

# 3. RECONCILE when something new landed.
if [ "$NEW" -gt 0 ]; then RC="$(run reconcile | tail -1)"; else RC='reconcile skipped (nothing new)'; fi

# 4. HEAL once a day; RECOMPUTE every run.
HL='heal skipped (done today)'
if [ "$(cat "$HEAL_STAMP" 2>/dev/null)" != "$(date +%F)" ] || [ "$NEW" -gt 0 ]; then
  HL="$(run heal | tail -1)"
  echo "$HL" | grep -q '"closed"' && date +%F > "$HEAL_STAMP" || note "heal errored: $(echo "$HL" | cut -c1-120)"
fi
RE="$(run recompute | tail -1)"
echo "$RE" | grep -q '"threads"' || note "recompute errored: $(echo "$RE" | cut -c1-120)"

# 5. CACHE.
CA="$(run cache | tail -1)"
echo "$CA" | grep -q '^wrote ' || note "cache write failed: $(echo "$CA" | cut -c1-120)"

echo "[$STAMP] $NEW ingested, $FAILS failed | $RC | $HL | $CA | runner $(git rev-parse --short HEAD 2>/dev/null)" >> "$LOG"
echo "$BF" "$IF" | grep 'FAILED' | sed "s/^/[$STAMP]   /" >> "$LOG"

if [ ${#PROBLEMS[@]} -gt 0 ]; then
  { echo "[$STAMP] STREAM NEEDS A LOOK:"; for p in "${PROBLEMS[@]}"; do echo "  - $p"; done; } > "$HEALTH"
else
  rm -f "$HEALTH"
fi
exit 0
