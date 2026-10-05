#!/bin/bash
# STREAM REFRESH: keeps THE STREAM (90Day) current, unattended, and heals it.
#
# Every run (launchd com.id8labs.stream-refresh, every 3h + RunAtLoad):
#   0. LOCK (no overlapping runs) and make sure the dedicated runner worktree exists; if it
#      was removed (it was, 2026-10-05 18:42, cause unknown), rebuild it from origin/main.
#   1. UPDATE the runner to origin/main by HARD RESET, but only after proving the cwd IS the
#      runner (a reset anywhere else would wipe someone's work). It used to `merge --ff-only
#      ... || true`; one stray snapshot commit made that fail silently for six weeks.
#   2. INGEST new transcripts: corpus entries (backfill) AND the call files filed on disk
#      under lexicon/knowledge/90day/corpus (ingest-files).
#   3. RECONCILE duplicate loops, only when something new landed.
#   4. HEAL once a day (skipped while ~/.claude/stream/HEAL_OFF exists); RECOMPUTE every run
#      so loops AGE at the real clock.
#   5. CACHE the digest the SessionStart hook reads.
# Every step's exit status is checked; anything wrong lands in ~/.claude/stream/health.txt,
# which the SessionStart hook prints above the digest. Cost-safe: a run with nothing new and
# heal done today makes no model calls. Undo a heal: `npm run stream -- reopen --healed-since <ISO>`.
# See memory project-the-stream.

set -uo pipefail

LEX="$HOME/Development/.worktrees/lexicon/stream-runner"
MAIN="$HOME/Development/id8/lexicon"          # the operator's checkout: the repo, .env.local
LOG="$HOME/Library/Logs/id8labs-stream-refresh.log"
STATE="$HOME/.claude/stream"
HEALTH="$STATE/health.txt"
HEAL_STAMP="$STATE/.healed-on"
LOCK_STAMP="$STATE/.lockfile-sha"
LOCKDIR="$STATE/.refresh.lock"
mkdir -p "$(dirname "$LOG")" "$STATE"

STAMP="$(date '+%F %T')"
PROBLEMS=()
note() { PROBLEMS+=("$1"); }
finish() {
  if [ ${#PROBLEMS[@]} -gt 0 ]; then
    { echo "[$STAMP] STREAM NEEDS A LOOK:"; for p in "${PROBLEMS[@]}"; do echo "  - $p"; done; } > "$HEALTH"
  else
    rm -f "$HEALTH"
  fi
  rmdir "$LOCKDIR" 2>/dev/null
  exit 0
}

# 0. LOCK: a run older than 2h is a crashed one; take its lock over.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rmdir "$LOCKDIR" 2>/dev/null; mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else echo "[$STAMP] another refresh is running; skipped" >> "$LOG"; exit 0; fi
fi

# Put a node on PATH for launchd's bare environment (latest nvm install).
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1)"
[ -n "$NODE_BIN" ] && export PATH="$NODE_BIN:$PATH"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 0b. The runner exists, or is rebuilt (detached at origin/main; it is nobody's branch).
if [ ! -e "$LEX/.git" ]; then
  if [ -e "$LEX" ]; then note "runner path $LEX exists but is not a worktree; left alone"; finish; fi
  git -C "$MAIN" worktree prune 2>/dev/null
  if git -C "$MAIN" fetch origin main --quiet 2>/dev/null && git -C "$MAIN" worktree add --detach "$LEX" origin/main --quiet 2>/dev/null; then
    ln -sf "$MAIN/.env.local" "$LEX/.env.local"
    rm -f "$LOCK_STAMP"   # force npm ci below
    echo "[$STAMP] runner worktree was missing; rebuilt at $(git -C "$LEX" rev-parse --short HEAD)" >> "$LOG"
  else
    note "runner worktree missing and could not be rebuilt ($LEX)"; finish
  fi
fi
cd "$LEX" || { note "cannot cd to runner $LEX"; finish; }

# Proof the cwd IS the dedicated runner before anything resets. Each check closes a way a hard
# reset could land on someone's work (poll f49e992 L6 reproduced the first two in a sandbox):
#   a symlink to the operator's checkout, a worktree with a branch checked out, a worktree of
#   some other repo, a non-worktree dir resolving to an enclosing repo, or uncommitted edits.
refuse() { note "runner $LEX: $1; refusing to reset"; finish; }
[ -L "$LEX" ] && refuse "is a symlink"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo none)"
[ "$(cd "$TOP" 2>/dev/null && pwd -P)" = "$(pwd -P)" ] || refuse "resolves to git top-level $TOP, not itself"
git symbolic-ref -q HEAD >/dev/null && refuse "has branch $(git symbolic-ref --short -q HEAD) checked out (the runner is always detached)"
COMMON="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
[ "$COMMON" = "$(cd "$MAIN/.git" 2>/dev/null && pwd -P)" ] || refuse "belongs to $COMMON, not $MAIN"
[ -z "$(git status --porcelain 2>/dev/null)" ] || refuse "has uncommitted changes"

# 1. UPDATE. The runner is dedicated: reset, never merge. Strays are kept on a branch.
if git fetch origin main --quiet 2>/dev/null; then
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  [ "$AHEAD" != "0" ] && git branch -f "runner-stray-$(date +%Y%m%d%H%M)" HEAD >/dev/null 2>&1
  git reset --hard origin/main --quiet 2>/dev/null || note "reset to origin/main failed"
else
  note "git fetch failed; running $(git rev-parse --short HEAD) unchanged"
fi
[ -e .env.local ] || ln -sf "$MAIN/.env.local" .env.local
LOCKSHA="$(shasum -a 256 package-lock.json 2>/dev/null | cut -c1-16)"
if [ ! -d node_modules ] || { [ -n "$LOCKSHA" ] && [ "$LOCKSHA" != "$(cat "$LOCK_STAMP" 2>/dev/null)" ]; }; then
  if npm ci --silent >/dev/null 2>&1; then echo "$LOCKSHA" > "$LOCK_STAMP"; else note "npm ci failed"; fi
fi

# run <cmd...>: runs the Stream CLI, leaves its output in OUT, notes a nonzero exit.
OUT=""
run() {
  local raw rc
  raw="$(npm run --silent stream -- "$@" 2>&1)"; rc=$?
  OUT="$(echo "$raw" | grep -vE 'dotenv')"
  [ $rc -ne 0 ] && note "stream $1 exited $rc: $(echo "$OUT" | tail -1 | cut -c1-120)"
  return 0
}

# 2. INGEST: corpus entries, then files on disk.
run backfill; BF="$OUT"
run ingest-files; IF="$OUT"
NEW=$(( $(echo "$BF" | grep -cE '^ingest .* \{') + $(echo "$IF" | grep -cE '^ingest .* \{') ))
FAILS=$(( $(echo "$BF" | grep -c 'FAILED') + $(echo "$IF" | grep -c 'FAILED') ))
[ "$FAILS" -gt 0 ] && note "$FAILS ingest(s) FAILED (see $LOG)"
CHANGED="$(echo "$IF" | grep -c 'CHANGED')"
[ "$CHANGED" -gt 0 ] && note "$CHANGED call file(s) re-filed with new text, not re-ingested (run ingest-files by hand)"

# 3. RECONCILE when something new landed.
RC='reconcile skipped (nothing new)'
if [ "$NEW" -gt 0 ]; then run reconcile; RC="$(echo "$OUT" | tail -1)"; fi

# 4. HEAL once a day (or when new calls landed); RECOMPUTE every run.
HL='heal skipped (done today)'
if [ "$(cat "$HEAL_STAMP" 2>/dev/null)" != "$(date +%F)" ] || [ "$NEW" -gt 0 ]; then
  run heal; HL="$(echo "$OUT" | tail -1)"
  if echo "$HL" | grep -q '"closed"'; then date +%F > "$HEAL_STAMP"; else note "heal gave no result: $(echo "$HL" | cut -c1-120)"; fi
fi
run recompute

# 5. CACHE.
run cache; CA="$(echo "$OUT" | tail -1)"

echo "[$STAMP] $NEW ingested, $FAILS failed | $RC | $HL | $CA | runner $(git rev-parse --short HEAD 2>/dev/null)" >> "$LOG"
echo "$BF" "$IF" | grep 'FAILED' | sed "s/^/[$STAMP]   /" >> "$LOG"
finish
