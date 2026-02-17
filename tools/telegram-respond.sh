#!/bin/bash
# telegram-respond.sh - Send response back to Eddie via Telegram
#
# Usage: telegram-respond.sh "message"
#        telegram-respond.sh "message" --reply-to <telegram_message_id>
#        telegram-respond.sh "message" --entity-type task --entity-id <id>
#
# Stores context in telegram_context table for future reply tracking.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

MESSAGE="${1:-}"
shift || true

REPLY_TO_MESSAGE_ID=""
ENTITY_TYPE=""
ENTITY_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --reply-to)
            REPLY_TO_MESSAGE_ID="$2"
            shift 2
            ;;
        --entity-type)
            ENTITY_TYPE="$2"
            shift 2
            ;;
        --entity-id)
            ENTITY_ID="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$MESSAGE" ]]; then
    echo "Usage: telegram-respond.sh \"message\" [--reply-to <msg_id>] [--entity-type <type>] [--entity-id <id>]"
    exit 1
fi

# Load Telegram credentials
TELEGRAM_CONFIG="$HOME/.hydra/config/telegram.env"
if [[ -f "$TELEGRAM_CONFIG" ]]; then
    source "$TELEGRAM_CONFIG"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

HYDRA_DB="$HOME/.hydra/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-telegram"
LOG_FILE="$LOG_DIR/respond-$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ============================================================================
# VALIDATION
# ============================================================================

if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ "$TELEGRAM_BOT_TOKEN" == "YOUR_BOT_TOKEN_HERE" ]]; then
    log "Error: Telegram bot token not configured"
    echo "Error: Telegram not configured. Run: hydra telegram setup"
    exit 1
fi

if [[ -z "$TELEGRAM_CHAT_ID" ]] || [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID_HERE" ]]; then
    log "Error: Telegram chat ID not configured"
    echo "Error: Telegram not configured. Run: hydra telegram setup"
    exit 1
fi

# ============================================================================
# SEND MESSAGE
# ============================================================================

log "Sending response: ${MESSAGE:0:50}..."

# Escape for JSON (macOS compatible)
json_text=$(printf '%s' "$MESSAGE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

# Build request body
REQUEST_BODY="{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${json_text}"

# Add reply_to_message_id if provided
if [[ -n "$REPLY_TO_MESSAGE_ID" ]]; then
    REQUEST_BODY="${REQUEST_BODY}, \"reply_to_message_id\": ${REPLY_TO_MESSAGE_ID}"
fi

REQUEST_BODY="${REQUEST_BODY}}"

# Send via Telegram Bot API
response=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY" 2>/dev/null)

# Check response
if echo "$response" | grep -q '"ok":true'; then
    # Extract message_id from response
    sent_message_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['message_id'])" 2>/dev/null || echo "")

    log "Sent successfully (message_id: $sent_message_id)"

    # Store context if entity info provided
    if [[ -n "$ENTITY_TYPE" ]] && [[ -n "$ENTITY_ID" ]] && [[ -n "$sent_message_id" ]]; then
        context_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
        sqlite3 "$HYDRA_DB" "
            INSERT INTO telegram_context (id, telegram_message_id, hydra_entity_type, hydra_entity_id)
            VALUES ('$context_id', $sent_message_id, '$ENTITY_TYPE', '$ENTITY_ID');
        " 2>/dev/null || true
        log "Context stored: $ENTITY_TYPE/$ENTITY_ID -> msg $sent_message_id"
    fi

    echo "message_id=$sent_message_id"
    exit 0
else
    log "Send failed: $response"
    echo "Error: Failed to send message"
    exit 1
fi
