#!/bin/bash
# id8labs-profile-check.sh - liveness probe for the id8labs Claude billing profile.
#
# The fleet bills unattended jobs to the id8labs subscription via an isolated
# Claude config dir (~/.claude-id8labs) logged in with the id8labs account (see
# ~/.claude/id8labs-sub.env). That OAuth login expires periodically; when it does,
# EVERY job that sources sub.env fails silently ("Anthropic profile login expired").
#
# This probe makes one tiny call on that profile every couple hours and writes a
# status flag that sub.env reads to decide id8labs-vs-default billing. On the
# transition INTO expired it alerts Eddie once (re-login clears it). Cheap: one
# minimal call per run.
set -uo pipefail

CFG="$HOME/.claude-id8labs"
STATUS_FILE="$HOME/.claude/.id8labs-profile-status"
LOG="$HOME/.hydra/logs/id8labs-profile-check.log"
mkdir -p "$(dirname "$LOG")"
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

PREV="$(cut -d' ' -f1 "$STATUS_FILE" 2>/dev/null || echo UNKNOWN)"

# Probe: a trivial prompt on the id8labs profile only. Never inherit an API key
# (that would bill metered) and never let the default profile answer for it.
RESP="$(printf 'Reply with exactly: ok' | CLAUDE_CONFIG_DIR="$CFG" ANTHROPIC_API_KEY= claude -p --model claude-sonnet-5 2>>"$LOG" || true)"

if printf '%s' "$RESP" | grep -qiE '^[[:space:]]*ok' \
   && ! printf '%s' "$RESP" | grep -qiE 'login expired|profile login|/login|not authenticated|invalid api key'; then
  STATUS=OK
else
  STATUS=EXPIRED
fi

echo "$STATUS $(date '+%FT%T%z')" > "$STATUS_FILE"
log "status=$STATUS (prev=$PREV)"

# Alert only on the transition INTO expired, so it's loud once, not spammy.
if [ "$STATUS" = "EXPIRED" ] && [ "$PREV" != "EXPIRED" ]; then
  log "ALERT: id8labs profile went EXPIRED; fleet now bills the DEFAULT (personal) profile"
  "$HOME/.hydra/daemons/notify-eddie.sh" urgent "id8labs Claude login expired" \
    "The fleet is falling back to your PERSONAL subscription until you re-login. In Terminal: CLAUDE_CONFIG_DIR=\"\$HOME/.claude-id8labs\" claude  then /login." 2>/dev/null || true
fi

exit 0
