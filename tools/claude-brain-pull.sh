#!/bin/bash
# Pull the shared brain (~/.claude) from origin. Runs on EVERY machine, including
# the MacBook, so config + memory propagate without anyone remembering to pull.
#
# This is the half of the bridge that replaces what iCloud would have done, minus
# iCloud's failure modes: no partial-read window (checkout is atomic), and a
# collision surfaces as a conflict instead of silent last-write-wins. Memory is a
# mutable multi-writer store -- the same class of object as the SQLite file that
# project_dae_v2_icloud_failover says must never live in iCloud.
#
# Read-only with respect to your work: never commits, never pushes, never resets.
# If it cannot fast-forward cleanly it stops and tells you.
# Origin: 2026-08-04.

set -uo pipefail

REPO="$HOME/.claude"
BRANCH="${SNAPSHOT_BRANCH:-main}"
STAMP="$(date '+%Y-%m-%d %H:%M')"
ALERT="$REPO/BRAIN-PULL-BLOCKED.md"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Brain sync\" sound name \"Basso\"" 2>/dev/null || true
}

cd "$REPO" 2>/dev/null || { echo "$STAMP  cannot cd $REPO"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$STAMP  not a git repo"; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "$STAMP  no origin"; exit 0; }

git fetch origin --quiet 2>/dev/null || { echo "$STAMP  fetch failed (offline?)"; exit 0; }

BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
if [ "$BEHIND" = "0" ]; then
  echo "$STAMP  up to date"
  [ -f "$ALERT" ] && rm -f "$ALERT"
  exit 0
fi

# autoStash: ~/.claude always carries unrelated dirty paths (skills/, plugins/).
# Without it the pull refuses and the machine silently stops syncing.
if git -c rebase.autoStash=true pull --rebase --quiet origin "$BRANCH" 2>/dev/null; then
  echo "$STAMP  pulled $BEHIND commit(s) from origin/$BRANCH"
  [ -f "$ALERT" ] && rm -f "$ALERT"
  exit 0
fi

git rebase --abort 2>/dev/null || true
{
  echo "# Brain pull BLOCKED - $STAMP"
  echo
  echo "This machine is **$BEHIND commit(s) behind** origin/$BRANCH and the rebase"
  echo "did not apply cleanly. Nothing was changed; the rebase was aborted."
  echo
  echo "Until this is resolved THIS MACHINE IS RUNNING ON A STALE BRAIN."
  echo "Memory written here will not reflect what the other machine knows."
  echo
  echo "## Resolve"
  echo
  echo '```bash'
  echo "cd $REPO"
  echo "git status                       # see what collides"
  echo "git pull --rebase origin $BRANCH  # resolve, then continue"
  echo '```'
  echo
  echo "\`MEMORY.md\` is the usual collision: append-heavy, edited on both machines."
  echo "When merging it, KEEP BOTH SIDES. Dropping one silently loses memory, and"
  echo "the index also truncates past ~17KB, so verify size after resolving."
  echo
  echo "Delete this file once resolved; a clean pull removes it automatically."
} > "$ALERT"
notify "Brain pull blocked. This machine is on a stale brain."
echo "$STAMP  BLOCKED: rebase conflict; see $ALERT"
exit 3
