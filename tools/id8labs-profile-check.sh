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
# Same credential the gateway uses: the long-lived setup-token from Keychain when
# present (does not expire like the browser login), else the config dir's login.
TOKEN="$(security find-generic-password -a hydra -s claude-id8labs-oauth-token -w 2>/dev/null || true)"
RESP="$(printf 'Reply with exactly: ok' | CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" ANTHROPIC_API_KEY='' claude -p --model "$("$HOME/.hydra/bin/hydra-llm" model mid --lane sub)" 2>>"$LOG" || true)"

if printf '%s' "$RESP" | grep -qiE '^[[:space:]]*ok' \
   && ! printf '%s' "$RESP" | grep -qiE 'login expired|profile login|/login|not authenticated|invalid api key'; then
  STATUS=OK
else
  STATUS=EXPIRED
fi

echo "$STATUS $(date '+%FT%T%z')" > "$STATUS_FILE"
log "status=$STATUS (prev=$PREV)"

# Alert on the transition INTO expired, then once a day while it stays expired.
# (One alert only, 2026-09-20, let the fleet bill the personal plan for 26 days.)
STAMP="$HOME/.claude/.id8labs-profile-alerted"
[ "$STATUS" = "OK" ] && rm -f "$STAMP"
if [ "$STATUS" = "EXPIRED" ] && { [ "$PREV" != "EXPIRED" ] || [ -z "$(find "$STAMP" -mmin -1440 2>/dev/null)" ]; }; then
  touch "$STAMP"
  log "ALERT: id8labs profile went EXPIRED; fleet now bills the DEFAULT (personal) profile"
  "$HOME/.hydra/daemons/notify-eddie.sh" urgent "id8labs Claude login expired" \
    "The fleet is falling back to your PERSONAL subscription until you re-login. In Terminal: CLAUDE_CONFIG_DIR=\"\$HOME/.claude-id8labs\" claude  then /login. Or end the re-logins: claude setup-token, then store it in Keychain as claude-id8labs-oauth-token (see ~/.hydra/docs/LLM-GATEWAY.md)." 2>/dev/null || true
fi

exit 0
