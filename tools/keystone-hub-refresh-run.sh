#!/bin/bash
# keystone-hub-refresh-run: run the Keystone hub refresh from a dedicated clean worktree.
# Why (2026-11-05): the refresh used to read ~/Development/keystone, a shared dev checkout with
# many sessions' uncommitted work, so whatever sat in that folder decided what the live cockpit
# hub showed, and the checkout could not be brought up to origin/main safely.
# Split inputs (agreed with Keystone 11/05):
#   - code, pod-hub/ and hub-data.js: the clean worktree, which only ever moves to origin/main
#     (~/Development/.worktrees/keystone/hub-refresh, pinned in disk-janitor.keep);
#   - the board, tasks/INTERNAL-TASKS.json: the shared checkout's WORKING copy, as before, so
#     "jobs on the board the same turn" still shows without waiting on a gated PR. It must parse
#     as JSON or the run stops before anything is published.
#     It must also hold at least MIN_TASKS tasks: an empty board would publish a hub with every row gone.
# Failures alert Keystone over Synapse AND Eddie over Telegram (NOTIFY), once per distinct failure per
# 6 hours; the first good run after a failure sends one "recovered" notice. Silence (job unloaded, no
# run for hours) is Rosy's watch, since a job that never runs cannot report itself.
# DRY_RUN and NOTIFY pass through to hub-refresh.sh unchanged. Tests: ~/.hydra/tests/09-keystone-hub-refresh-run.bats
set -u
W="${HUB_REFRESH_WT:-$HOME/Development/.worktrees/keystone/hub-refresh}"
KS_BOARD="${KS_BOARD:-$HOME/Development/keystone/tasks/INTERNAL-TASKS.json}"
LOG="${LOG:-$HOME/Library/Logs/keystone-hub-refresh.log}"
SYNAPSE="${SYNAPSE:-$HOME/.local/bin/synapse}"
REFRESH="${HUB_REFRESH_SCRIPT:-$W/tools/hub-refresh.sh}"
NOTIFY="${NOTIFY-$HOME/.hydra/tools/telegram-respond.sh}"
MIN_TASKS="${MIN_TASKS:-50}"
# Fixed path (not TMPDIR) so a manual run and the launchd run share one lock.
RUNLOCK="${RUNLOCK:-$HOME/.hydra/state/keystone-hub-refresh-run.lock}"
ALERT_STATE="${ALERT_STATE:-$HOME/.hydra/state/keystone-hub-refresh-run.last-alert}"
HELD=0

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "runner: $*" >> "$LOG"; }
unlock() { if [ "$HELD" = "1" ]; then rm -f "$RUNLOCK/pid"; rmdir "$RUNLOCK" 2>/dev/null; HELD=0; fi; }
tell_eddie() { if [ -n "$NOTIFY" ] && [ -x "$NOTIFY" ]; then "$NOTIFY" "$1" >/dev/null 2>&1 || log "telegram alert not sent"; fi; }
alert() {
  log "FAIL $1"
  unlock
  if [ "${DRY_RUN:-0}" != "1" ] && [ -x "$SYNAPSE" ]; then
    now=$(date +%s); last_msg=""; last_at=0
    if [ -f "$ALERT_STATE" ]; then last_at=$(head -n 1 "$ALERT_STATE"); last_msg=$(sed -n 2p "$ALERT_STATE"); fi
    case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
    if [ "$last_msg" != "$1" ] || [ $((now - last_at)) -ge 21600 ]; then
      body="What to do: fix the cause below, then run DRY_RUN=1 NOTIFY= ~/.hydra/tools/keystone-hub-refresh-run.sh and check the log. Log tail:
$(tail -n 15 "$LOG")"
      if "$SYNAPSE" send --from ops --to keystone --kind notice --priority high \
           --subject "Hub refresh failed: $1" --body "$body" >/dev/null 2>&1; then
        :
      else
        log "synapse alert not sent"
      fi
      tell_eddie "Keystone hub refresh stopped: $1. Log: $LOG"
      mkdir -p "$(dirname "$ALERT_STATE")" && printf '%s\n%s\n' "$now" "$1" > "$ALERT_STATE"
    fi
  fi
  exit 1
}

# Own lock around fetch/reset/copy (hub-refresh.sh keeps its own lock for the publish).
# The lock holds the owner's PID; it is only taken over when that PID is gone AND it is over 2 h old.
mkdir -p "$(dirname "$RUNLOCK")"
if mkdir "$RUNLOCK" 2>/dev/null; then
  HELD=1
else
  age=$(( $(date +%s) - $(stat -f %m "$RUNLOCK" 2>/dev/null || date +%s) ))
  owner=$(cat "$RUNLOCK/pid" 2>/dev/null)
  if [ "$age" -gt 7200 ] && { [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; } \
     && rm -f "$RUNLOCK/pid" && rmdir "$RUNLOCK" 2>/dev/null && mkdir "$RUNLOCK" 2>/dev/null; then
    HELD=1; log "cleared a stale run lock (${age}s old, owner ${owner:-unknown} gone)"
  else
    log "another run holds the lock; skipping"; exit 0
  fi
fi
echo $$ > "$RUNLOCK/pid"
trap unlock EXIT

[ -e "$W/.git" ] || alert "worktree missing: $W"
git -C "$W" fetch -q origin || alert "fetch origin"
# Dedicated folder: only the refresh's own generated files and the copied board can differ.
git -C "$W" reset -q --hard origin/main || alert "reset to origin/main"
[ -f "$KS_BOARD" ] || alert "board missing: $KS_BOARD"
/usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$KS_BOARD" 2>/dev/null || alert "board is not valid JSON: $KS_BOARD"
n=$(/usr/bin/python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); print(len(t.get("tasks") or []) if isinstance(t, dict) else 0)' "$KS_BOARD" 2>/dev/null)
[ "${n:-0}" -ge "$MIN_TASKS" ] || alert "board has ${n:-0} tasks, under the $MIN_TASKS minimum: $KS_BOARD"
cp "$KS_BOARD" "$W/tasks/INTERNAL-TASKS.json" || alert "copy board"
log "source $(git -C "$W" rev-parse --short HEAD) (origin/main) + board from $KS_BOARD"
KS="$W" /bin/bash "$REFRESH"
rc=$?
[ "$rc" -eq 0 ] || alert "hub-refresh.sh exit $rc"
if [ "${DRY_RUN:-0}" != "1" ] && [ -f "$ALERT_STATE" ]; then
  rm -f "$ALERT_STATE"
  "$SYNAPSE" send --from ops --to keystone --kind notice --subject "Hub refresh recovered" \
    --body "The hub refresh ran clean again. Log: $LOG" >/dev/null 2>&1 || log "synapse recovery notice not sent"
  tell_eddie "Keystone hub refresh recovered."
fi
exit 0
