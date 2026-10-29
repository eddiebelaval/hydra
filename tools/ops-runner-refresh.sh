#!/bin/bash
# OPS RUNNER REFRESH: keeps the pinned ops runner on origin/main so merged fixes go live.
#
# Synapse (sweep, health, drain hooks) and the Kev gatekeeper run from a dedicated detached
# worktree, never the shared workbench (a branch switch there changed live code; the 10/26
# Lexicon lesson). Pinned also means frozen: a fix merged to main did not run until someone
# moved the runner. Modelled on stream-refresh.sh, the Lexicon runner refresh.
#
# Every run (launchd com.id8labs.ops-runner-refresh, every 30 min + RunAtLoad):
#   0. LOCK; rebuild the runner from origin/main if it is gone (and keep it pinned).
#   1. PROVE the cwd IS the runner (not a symlink, detached, this repo, no uncommitted edits).
#      GATE: if main changed tools/synapse or tools/kev-ondemand, run their tests on main's
#      commit in a throwaway checkout; red holds the runner. Then HARD RESET to origin/main.
#      Never merge. Commits found on the runner go to a runner-stray-* branch first.
#   2. RESTART the Kev gatekeeper when its code changed (it is the one long-running process;
#      sweep, health and the hooks start fresh each run). A changed launchd plist is flagged,
#      not reinstalled: installing a job stays a reviewed step.
# Problems land in $HEALTH (removed when clean) and the log.

set -uo pipefail

RUN="$HOME/Development/.worktrees/id8/ops-runner"
MAIN="$HOME/Development/id8"
STATE="$HOME/Library/Application Support/id8/ops-runner"
LOG="$HOME/Library/Logs/id8labs-ops-runner-refresh.log"
HEALTH="$STATE/HEALTH.txt"
LOCKDIR="$STATE/.refresh.lock"
KEEP="$HOME/.claude/tools/janitor-keep"
KEV_JOB="gui/$(id -u)/com.id8labs.keystone.founder.model"
PLISTS="tools/kev-ondemand/com.id8labs.keystone.founder.model.plist tools/synapse/com.id8labs.synapse-health.plist tools/synapse/com.id8labs.synapse-sweep.plist"
mkdir -p "$STATE" "$(dirname "$LOG")"

STAMP="$(date '+%F %T')"
PROBLEMS=()
note() { PROBLEMS+=("$1"); }
finish() {
  if [ ${#PROBLEMS[@]} -gt 0 ]; then
    { echo "[$STAMP] OPS RUNNER NEEDS A LOOK:"; for p in "${PROBLEMS[@]}"; do echo "  - $p"; done; } > "$HEALTH"
    for p in "${PROBLEMS[@]}"; do echo "[$STAMP] PROBLEM: $p" >> "$LOG"; done
  else
    rm -f "$HEALTH"
  fi
  rmdir "$LOCKDIR" 2>/dev/null
  exit 0
}

# 0. LOCK: a lock older than 30 min belongs to a crashed run; take it over.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else echo "[$STAMP] another refresh is running; skipped" >> "$LOG"; exit 0; fi
fi

# 0b. The runner exists, or is rebuilt (detached at origin/main; it is nobody's branch).
if [ ! -e "$RUN/.git" ]; then
  if [ -e "$RUN" ]; then note "runner path $RUN exists but is not a worktree; left alone"; finish; fi
  git -C "$MAIN" worktree prune 2>/dev/null
  if git -C "$MAIN" fetch origin main --quiet 2>/dev/null && git -C "$MAIN" worktree add --detach "$RUN" origin/main --quiet 2>/dev/null; then
    [ -x "$KEEP" ] && "$KEEP" add "$RUN" >/dev/null 2>&1
    echo "[$STAMP] runner worktree was missing; rebuilt at $(git -C "$RUN" rev-parse --short HEAD)" >> "$LOG"
  else
    note "runner worktree missing and could not be rebuilt ($RUN)"; finish
  fi
fi
cd "$RUN" || { note "cannot cd to runner $RUN"; finish; }

# 1. Proof the cwd IS the dedicated runner before anything resets (stream-refresh's checks).
refuse() { note "runner $RUN: $1; refusing to reset"; finish; }
[ -L "$RUN" ] && refuse "is a symlink"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo none)"
[ "$(cd "$TOP" 2>/dev/null && pwd -P)" = "$(pwd -P)" ] || refuse "resolves to git top-level $TOP, not itself"
git symbolic-ref -q HEAD >/dev/null && refuse "has branch $(git symbolic-ref --short -q HEAD) checked out (the runner is always detached)"
COMMON="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
[ "$COMMON" = "$(cd "$MAIN/.git" 2>/dev/null && pwd -P)" ] || refuse "belongs to $COMMON, not $MAIN"
[ -z "$(git status --porcelain 2>/dev/null)" ] || refuse "has uncommitted changes"

OLD="$(git rev-parse HEAD 2>/dev/null)"
if git fetch origin main --quiet 2>/dev/null; then
  # GATE: a merge to main is a release here (the drain hook runs on every prompt in every
  # session). When main changes the ops tools, their tests must pass on main's exact commit,
  # in a throwaway checkout, before the runner moves. Red holds the runner where it is.
  TARGET="$(git rev-parse origin/main 2>/dev/null)"
  if [ "$TARGET" != "$OLD" ] && [ -n "$(git diff --name-only "$OLD" "$TARGET" -- tools/synapse tools/kev-ondemand 2>/dev/null)" ]; then
    GATE="$(mktemp -d "${TMPDIR:-/tmp}/ops-runner-gate.XXXXXX")"
    git -C "$MAIN" worktree add --detach --force "$GATE" "$TARGET" --quiet 2>/dev/null || note "could not check out $TARGET to test it"
    (cd "$GATE/tools" 2>/dev/null && /usr/bin/python3 -m pytest synapse kev-ondemand -q -p no:cacheprovider > "$STATE/gate-tests.log" 2>&1)
    RC=$?
    git -C "$MAIN" worktree remove --force "$GATE" 2>/dev/null; rm -rf "$GATE"
    # pytest exit 5 = no tests collected (nothing to fail)
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 5 ]; then
      if grep -q "No module named pytest" "$STATE/gate-tests.log" 2>/dev/null; then
        note "could not run the gate on main $(git rev-parse --short "$TARGET"): pytest missing for /usr/bin/python3; runner held at $(git rev-parse --short "$OLD")"
      else
        note "main $(git rev-parse --short "$TARGET") fails the Synapse/Kev tests (exit $RC, $STATE/gate-tests.log); runner held at $(git rev-parse --short "$OLD"). Fix or revert on main."
      fi
      finish
    fi
  fi
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  [ "$AHEAD" != "0" ] && git branch -f "runner-stray-$(date +%Y%m%d%H%M)" HEAD >/dev/null 2>&1
  git reset --hard origin/main --quiet 2>/dev/null || note "reset to origin/main failed"
else
  note "git fetch failed; running $(git rev-parse --short HEAD) unchanged"
fi
NEW="$(git rev-parse HEAD 2>/dev/null)"

# 2. What the move changed.
if [ "$OLD" != "$NEW" ]; then
  CHANGED="$(git diff --name-only "$OLD" "$NEW" -- tools/kev-ondemand tools/synapse 2>/dev/null)"
  if printf '%s\n' "$CHANGED" | grep -q '^tools/kev-ondemand/kev_ondemand.py$'; then
    if launchctl kickstart -k "$KEV_JOB" 2>/dev/null; then
      echo "[$STAMP] kev gatekeeper restarted on new code" >> "$LOG"
    else
      note "kev gatekeeper code changed but the restart failed ($KEV_JOB)"
    fi
  fi
  for pl in $PLISTS; do
    installed="$HOME/Library/LaunchAgents/$(basename "$pl")"
    if printf '%s\n' "$CHANGED" | grep -qx "$pl" && ! cmp -s "$pl" "$installed"; then
      note "$pl changed on main and differs from $installed; review and reinstall it"
    fi
  done
  echo "[$STAMP] runner $(git rev-parse --short "$OLD") -> $(git rev-parse --short "$NEW") ($(printf '%s\n' "$CHANGED" | grep -c . ) ops files changed)" >> "$LOG"
else
  echo "[$STAMP] runner at $(git rev-parse --short HEAD), already current" >> "$LOG"
fi
finish
