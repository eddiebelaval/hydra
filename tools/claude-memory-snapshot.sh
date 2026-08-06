#!/bin/bash
# Nightly snapshot of the live memory brain into the ~/.claude git repo.
#
# WHY A SNAPSHOT AND NOT A REAL COMMIT: memory/ is mutated continuously by 4-10
# parallel sessions. There is no moment where a hand-authored commit is a
# meaningful unit. A heartbeat is the correct semantic here, the same pattern the
# id8 EOD bot already uses. Meaningful history for a memory store lives in the
# files themselves, not in commit messages.
#
# THE GUARD IS THE POINT: the real risk was never drift, it was a bulk deletion
# landing silently in one commit. On 2026-08-03 a naive `git add -A` would have
# swept 130 apparent deletions. (They turned out to be a retired project scope
# plus archive/ moves, but the job must not need that to be true.) If a run would
# remove more than MAX_DELETIONS files, it HALTS and reports instead of committing.
#
# Never pushes. Shipping stays a human gate.
# Origin: 2026-08-03.

set -euo pipefail

REPO="$HOME/.claude"
SCOPE="projects"
BRANCH="${SNAPSHOT_BRANCH:-main}"
MAX_DELETIONS="${MAX_DELETIONS:-10}"
# SNAPSHOT_PUSH=1 makes this a real cross-machine bridge. Off by default so the
# script is safe to run anywhere; the launchd plist turns it on deliberately.
# This is a PRIVATE backup repo, not a client deliverable -- the human ship gate
# still applies to everything that reaches a client or the public.
STAMP="$(date '+%Y-%m-%d %H:%M')"
ALERT="$REPO/MEMORY-SNAPSHOT-HALTED.md"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Memory snapshot\" sound name \"Basso\"" 2>/dev/null || true
}

cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }

# Assert we are in the repo we think we are (feedback_force_push_scripts_assert_repo_identity).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: $REPO"; exit 1; }
[ -d "$REPO/$SCOPE" ] || { echo "no $SCOPE dir"; exit 1; }

# --- multi-machine: take the other machine's memory FIRST ---------------------
# Two Macs writing one brain. Rebase before committing so our snapshot replays on
# top of theirs instead of forking. autoStash because ~/.claude always has
# unrelated dirty paths (skills/, plugins/) that would otherwise block the rebase.
# On conflict: ABORT and report. A repo left mid-rebase while 4-10 sessions are
# live is worse than a skipped snapshot.
if git remote get-url origin >/dev/null 2>&1; then
  if git fetch origin --quiet 2>/dev/null; then
    if ! git -c rebase.autoStash=true pull --rebase --quiet origin "$BRANCH" 2>/dev/null; then
      git rebase --abort 2>/dev/null || true
      git stash pop --quiet 2>/dev/null || true
      {
        echo "# Memory snapshot HALTED (rebase conflict) - $STAMP"
        echo
        echo "Could not replay local memory on top of origin/$BRANCH. Nothing was"
        echo "committed and the rebase was aborted, so the repo is NOT mid-rebase."
        echo
        echo "This means both machines changed the same memory file. Resolve by hand:"
        echo
        echo '```bash'
        echo "cd $REPO && git pull --rebase origin $BRANCH   # resolve, then:"
        echo "~/.hydra/tools/claude-memory-snapshot.sh"
        echo '```'
        echo
        echo "MEMORY.md is the usual culprit: it is append-heavy and both machines"
        echo "edit it. Keep BOTH sides when merging it; dropping one loses memory."
      } > "$ALERT"
      notify "Rebase conflict. Nothing committed. See MEMORY-SNAPSHOT-HALTED.md"
      echo "$STAMP  HALTED: rebase conflict against origin/$BRANCH"
      exit 3
    fi
  else
    echo "$STAMP  note: fetch failed (offline?); snapshotting locally only"
  fi
fi

# --- index oversize guard ---------------------------------------------------
# MEMORY.md is auto-injected every session and SILENTLY TRUNCATES past ~17.1KB --
# the tail (newest entries) just stops being loaded, with no error anywhere. It
# regressed from 16.6KB to 19.9KB in 48 hours on 2026-08-04..06 purely from
# normal session growth. Detection has to be automatic; nobody notices this.
IDX="$REPO/projects/-Users-eddiebelaval-Development-id8/memory/MEMORY.md"
if [ -f "$IDX" ]; then
  SZ=$(wc -c < "$IDX" | tr -d ' ')
  if [ "$SZ" -gt 17100 ]; then
    notify "MEMORY.md is ${SZ}B (>17100). The tail is being dropped on load."
    echo "$STAMP  WARN: MEMORY.md ${SZ}B exceeds the ~17100B read limit -- tail silently dropped"
  fi
fi

git add -A "$SCOPE" 2>/dev/null || true

if git diff --cached --quiet -- "$SCOPE"; then
  echo "$STAMP  no memory changes"
  # Still push if the rebase pulled in commits we have not shared yet.
  if [ "${SNAPSHOT_PUSH:-0}" = "1" ] && [ -n "$(git log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
    git push --quiet origin "$BRANCH" 2>/dev/null && echo "$STAMP  pushed pending commits"
  fi
  exit 0
fi

# Renames are moves (e.g. into memory/archive/), not losses. Count true deletions only.
DELETED=$(git diff --cached --name-status -- "$SCOPE" | awk '$1=="D"' | wc -l | tr -d ' ')

if [ "$DELETED" -gt "$MAX_DELETIONS" ]; then
  {
    echo "# Memory snapshot HALTED - $STAMP"
    echo
    echo "This run would delete **$DELETED** memory files (threshold: $MAX_DELETIONS)."
    echo "Nothing was committed. The staged set has been reset; your working tree is untouched."
    echo
    echo "A large deletion is either a deliberate consolidation or a real loss, and this"
    echo "job cannot tell the difference. Look before letting it through."
    echo
    echo "## What it wanted to delete"
    echo
    echo '```'
    git diff --cached --name-status -- "$SCOPE" | awk '$1=="D"{print $2}' | sed 's|.*/memory/||'
    echo '```'
    echo
    echo "## Triage"
    echo
    echo "1. Which project scope? Only \`-Users-eddiebelaval-Development-id8\` is the live"
    echo "   brain. Other scopes are retired and their deletions are expected."
    echo "2. Moved to \`memory/archive/\`? Then it is a rename, not a loss. archive/ is"
    echo "   tracked as of 2026-08-03, so real moves show as R, not D."
    echo "3. Renamed/consolidated? Look for a successor slug covering the same ground."
    echo "4. Still unexplained? Recover it:"
    echo '   ```'
    echo "   git checkout HEAD -- <path>"
    echo '   ```'
    echo "   Or search Layer 0: \`mempalace search '<topic>'\`"
    echo
    echo "## Once satisfied"
    echo
    echo '```bash'
    echo "cd $REPO && MAX_DELETIONS=999 ~/.hydra/tools/claude-memory-snapshot.sh"
    echo '```'
    echo
    echo "Delete this file when resolved; the next clean run will not recreate it."
  } > "$ALERT"
  git reset -q -- "$SCOPE" 2>/dev/null || true
  notify "HALTED: $DELETED deletions exceed threshold. Nothing committed."
  echo "$STAMP  HALTED: $DELETED deletions > $MAX_DELETIONS. See $ALERT"
  exit 2
fi

A=$(git diff --cached --name-status -- "$SCOPE" | awk '$1=="A"' | wc -l | tr -d ' ')
M=$(git diff --cached --name-status -- "$SCOPE" | awk '$1=="M"' | wc -l | tr -d ' ')
R=$(git diff --cached --name-status -- "$SCOPE" | awk '$1 ~ /^R/' | wc -l | tr -d ' ')

git commit -q -m "chore(memory): snapshot $STAMP" \
  -m "Automated heartbeat of the live memory brain. ${A} added, ${M} modified, ${R} moved, ${DELETED} removed." \
  -m "Not pushed; shipping stays a human gate."

[ -f "$ALERT" ] && rm -f "$ALERT"
echo "$STAMP  committed: ${A}A ${M}M ${R}R ${DELETED}D"

# Publish so the other machine can pull it. Non-fatal: a failed push just means
# the next run carries both snapshots up.
if [ "${SNAPSHOT_PUSH:-0}" = "1" ]; then
  if git push --quiet origin "$BRANCH" 2>/dev/null; then
    echo "$STAMP  pushed to origin/$BRANCH"
  else
    echo "$STAMP  push failed (offline or rejected); will retry next run"
  fi
fi
