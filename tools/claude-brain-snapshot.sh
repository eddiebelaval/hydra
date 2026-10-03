#!/bin/bash
# Nightly full snapshot of ~/.claude (the exocortex) to the private backup repo.
#
# The memory snapshot (claude-memory-snapshot.sh, 01:43) covers projects/ only.
# Everything else that makes this Claude Eddie's -- CLAUDE.md, skills/, agents/,
# hooks/, commands/, mentor/, settings -- drifted from 2026-08-23 to 2026-09-06
# with 361 dirty paths and no off-site copy. This job commits the rest and owns
# the push.
#
# THE PUSH IS VERIFIED, NOT ASSUMED. Over those same two weeks the memory job
# logged "pushed to origin/main" every night while GitHub sat at Aug 23: the repo
# was parked on a hackathon branch, so `git push origin main` pushed a stale main
# and exited 0. This job fast-forwards main to HEAD when main is an ancestor,
# pushes, re-fetches, and compares refs. It refuses to claim success otherwise.
#
# Same deletion guard as the memory job with a wider threshold (skills and plugin
# caches churn). Never `git checkout`: parallel sessions may be live in the repo.
# Origin: 2026-09-06, the "how do I preserve you off this machine" session.

set -uo pipefail

REPO="$HOME/.claude"
BRANCH="${SNAPSHOT_BRANCH:-main}"
MAX_DELETIONS="${MAX_DELETIONS:-60}"
STAMP="$(date '+%Y-%m-%d %H:%M')"
ALERT="$REPO/BRAIN-SNAPSHOT-HALTED.md"
STATE="$HOME/.hydra/state/brain-snapshot.json"

log() { echo "$STAMP  $*"; }
notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Brain snapshot\" sound name \"Basso\"" 2>/dev/null || true
}
write_state() {
  mkdir -p "$(dirname "$STATE")"
  printf '{"at":"%s","status":"%s","note":"%s"}\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$2" > "$STATE"
}
fail() {
  log "FAILED: $1"
  notify "$1"
  write_state red "$1"
  exit "${2:-1}"
}

# --- canary: prove the gate can go red and green -------------------------------
# (feedback-pipe-to-tee-swallows-the-exit-code: every gate ships a canary)
case "${1:-}" in
  --canary)
    if [ "${2:-}" = "red" ]; then log "canary red"; exit 42; fi
    log "canary green"; exit 0 ;;
esac

cd "$REPO" || fail "cannot cd $REPO"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a git repo: $REPO"
[ -f "$REPO/CLAUDE.md" ] || fail "no CLAUDE.md at $REPO; wrong repo?"
git remote get-url origin >/dev/null 2>&1 || fail "no origin remote; nothing off-site"

# --- take the other machine's work first ---------------------------------------
if git fetch origin --quiet 2>/dev/null; then
  if ! git -c rebase.autoStash=true pull --rebase --quiet origin "$BRANCH" 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    git stash pop --quiet 2>/dev/null || true
    fail "rebase conflict against origin/$BRANCH; nothing committed, repo not mid-rebase" 3
  fi
else
  log "note: fetch failed (offline?); will still commit locally"
fi

# --- stage everything the .gitignore allows -------------------------------------
git add -A 2>/dev/null

if git diff --cached --quiet; then
  log "no changes to commit"
else
  DELETED=$(git diff --cached --name-status | awk '$1=="D"' | wc -l | tr -d ' ')
  if [ "$DELETED" -gt "$MAX_DELETIONS" ]; then
    {
      echo "# Brain snapshot HALTED - $STAMP"
      echo
      echo "This run would delete **$DELETED** files (threshold: $MAX_DELETIONS)."
      echo "Nothing was committed. The index was reset; the working tree is untouched."
      echo
      echo "A large deletion is either a deliberate consolidation or a real loss, and this"
      echo "job cannot tell the difference. Look before letting it through."
      echo
      echo '```'
      git diff --cached --name-status | awk '$1=="D"{print $2}'
      echo '```'
      echo
      echo "Once satisfied:"
      echo
      echo '```bash'
      echo "MAX_DELETIONS=9999 ~/.hydra/tools/claude-brain-snapshot.sh"
      echo '```'
    } > "$ALERT"
    git reset -q 2>/dev/null || true
    fail "$DELETED deletions exceed $MAX_DELETIONS; see $ALERT" 2
  fi
  A=$(git diff --cached --name-status | awk '$1=="A"' | wc -l | tr -d ' ')
  M=$(git diff --cached --name-status | awk '$1=="M"' | wc -l | tr -d ' ')
  R=$(git diff --cached --name-status | awk '$1 ~ /^R/' | wc -l | tr -d ' ')
  git commit -q -m "job(brain): snapshot $STAMP" \
    -m "Automated heartbeat of the exocortex. ${A} added, ${M} modified, ${R} moved, ${DELETED} removed." \
    || fail "commit failed"
  [ -f "$ALERT" ] && rm -f "$ALERT"
  log "committed: ${A}A ${M}M ${R}R ${DELETED}D"
fi

# --- make $BRANCH follow HEAD without a checkout --------------------------------
CUR=$(git branch --show-current)
if [ -n "$CUR" ] && [ "$CUR" != "$BRANCH" ]; then
  if git merge-base --is-ancestor "$BRANCH" HEAD; then
    git branch -f "$BRANCH" HEAD
    log "fast-forwarded $BRANCH to HEAD (repo parked on $CUR)"
  else
    fail "$BRANCH has diverged from HEAD on $CUR; refusing to move it" 4
  fi
fi

# --- push, then VERIFY the remote actually moved --------------------------------
if ! git push --quiet origin "$BRANCH" 2>/dev/null; then
  fail "push to origin/$BRANCH rejected or offline" 5
fi
git fetch --quiet origin "$BRANCH" 2>/dev/null || true
LOCAL=$(git rev-parse "$BRANCH")
REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)
if [ "$LOCAL" != "$REMOTE" ]; then
  fail "push exited 0 but origin/$BRANCH=$REMOTE != $BRANCH=$LOCAL" 6
fi
log "VERIFIED off-site: origin/$BRANCH = $LOCAL"
write_state green "origin/$BRANCH=$LOCAL"
