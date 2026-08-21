#!/bin/bash
# dream-send-telegram.sh - send the night's dream to Eddie's private Telegram,
# rendered correctly (bold/italic, no raw #, <!-- -->, or --- junk).
#
# Eddie asked (2026-08-21) for the dream to reach his Telegram too. It is still
# his private channel and his rawest signal -- this sends ONLY to his own chat,
# nowhere else. Reuses the fleet's telegram creds + the md->TG-HTML renderer.
#
# Usage: dream-send-telegram.sh [path-to-dream.md]   (defaults to DREAM.md)
set -uo pipefail

HYDRA="$HOME/.hydra"
DREAM_FILE="${1:-$HYDRA/dreams/DREAM.md}"
RENDERER="$HYDRA/tools/md-to-tg-html.py"
TELEGRAM_CONFIG="$HYDRA/config/telegram.env"
LOG="$HYDRA/logs/dream-sweep.log"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] telegram: $*" >> "$LOG"; }

[ -f "$DREAM_FILE" ] || { log "no dream file at $DREAM_FILE"; exit 0; }
[ -f "$TELEGRAM_CONFIG" ] || { log "no telegram config"; exit 0; }

# shellcheck disable=SC1090
source "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  log "telegram creds not configured; skipping"; exit 0
fi
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Clean the dream for Telegram: drop the metadata comment, the --- rules, and the
# leading blockquote '> ' marker (Telegram HTML has no <hr>/heading, and the
# renderer would escape a bare '>'). Keep # (-> bold) and **bold**/*italic*.
CLEAN="$(sed -E \
  -e '/^[[:space:]]*<!--.*-->[[:space:]]*$/d' \
  -e '/^[[:space:]]*---[[:space:]]*$/d' \
  -e 's/^[[:space:]]*>[[:space:]]?//' \
  "$DREAM_FILE" | sed -E '/^[[:space:]]*$/N;/^\n$/D')"

# Render markdown -> Telegram HTML. Fall back to the cleaned plain text if the
# renderer is unavailable.
HTML_JSON="$(printf '%s' "$CLEAN" | python3 "$RENDERER" 2>/dev/null || true)"
PLAIN_JSON="$(printf '%s' "$CLEAN" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
[ -z "$HTML_JSON" ] && HTML_JSON="$PLAIN_JSON"

# Token-safe curl: the URL (with token) is passed via --config stdin, never argv.
tg_send() {
  local text_json="$1" mode="$2"
  printf 'url = "%s"\n' "${TELEGRAM_API}/sendMessage" | curl --config - -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${text_json},\"parse_mode\":\"${mode}\",\"disable_web_page_preview\":true}"
}

RESP="$(tg_send "$HTML_JSON" "HTML")"
if ! printf '%s' "$RESP" | grep -q '"ok":true'; then
  # HTML rejected (bad tag balance) -> resend as plain text so it always lands.
  log "HTML send rejected, retrying plain text"
  RESP="$(printf 'url = "%s"\n' "${TELEGRAM_API}/sendMessage" | curl --config - -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${PLAIN_JSON},\"disable_web_page_preview\":true}")"
fi

if printf '%s' "$RESP" | grep -q '"ok":true'; then
  log "sent to Telegram"
  exit 0
else
  log "Telegram send FAILED: $(printf '%s' "$RESP" | head -c 200)"
  exit 1
fi
