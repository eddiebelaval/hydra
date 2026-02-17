#!/bin/bash
# notify-eddie.sh - HYDRA Notification Dispatcher
# Sends notifications to Eddie via multiple channels
#
# Usage: notify-eddie.sh <priority> <title> <message> [file_to_open] [--entity-type TYPE] [--entity-id ID]
#
# Optional flags (for reply context tracking):
#   --entity-type  Type of HYDRA entity (task, notification, standup)
#   --entity-id    ID of the HYDRA entity
#
# Priority levels:
#   urgent   → Telegram + macOS notification + open file
#   high     → macOS notification + open file
#   normal   → macOS notification only
#   silent   → Log only (for background updates)
#
# Channels:
#   1. Telegram (via OpenClaw gateway) - for urgent/mobile
#   2. terminal-notifier (macOS) - for desktop alerts
#   3. MacDown (open markdown) - for detailed reports

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

PRIORITY="${1:-normal}"
TITLE="${2:-HYDRA}"
MESSAGE="${3:-No message provided}"
FILE_TO_OPEN="${4:-}"

# Parse optional entity tracking flags
ENTITY_TYPE=""
ENTITY_ID=""
shift 4 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case $1 in
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

HYDRA_DB="$HOME/.hydra/hydra.db"

# Load Telegram credentials
TELEGRAM_CONFIG="$HOME/.hydra/config/telegram.env"
if [[ -f "$TELEGRAM_CONFIG" ]]; then
    source "$TELEGRAM_CONFIG"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-notifications"
LOG_FILE="$LOG_DIR/dispatch-$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Dispatch: [$PRIORITY] $TITLE - $MESSAGE"

# ============================================================================
# CHANNEL 1: TELEGRAM (Direct Bot API)
# ============================================================================

# Token-safe curl wrapper: passes URL via stdin so token never appears in ps aux
telegram_curl() {
    local endpoint="$1"
    shift
    local url="${TELEGRAM_API}/${endpoint}"
    printf 'url = "%s"\n' "$url" | curl --config - -s "$@"
}

send_telegram() {
    local msg="$1"

    # Check if credentials are configured
    if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ "$TELEGRAM_BOT_TOKEN" == "YOUR_BOT_TOKEN_HERE" ]]; then
        log "Telegram: Bot token not configured in $TELEGRAM_CONFIG"
        return 1
    fi

    if [[ -z "$TELEGRAM_CHAT_ID" ]] || [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID_HERE" ]]; then
        log "Telegram: Chat ID not configured in $TELEGRAM_CONFIG"
        return 1
    fi

    # Format message for Telegram (MarkdownV2 with proper escaping)
    # Note: MarkdownV2 requires escaping: _ * [ ] ( ) ~ ` > # + - = | { } . !
    local escaped_title=$(echo "$TITLE" | sed 's/[_*[\]()~`>#+=|{}.!-]/\\&/g')
    local escaped_msg=$(echo "$msg" | sed 's/[_*[\]()~`>#+=|{}.!-]/\\&/g')

    local telegram_msg="*HYDRA Alert*

*${escaped_title}*
${escaped_msg}

_$(date '+%Y\\-%-m\\-%-d %H:%M')_"

    # Build plain text message (most reliable)
    local plain_msg="HYDRA Alert

$TITLE
$msg

$(date '+%Y-%m-%d %H:%M')"

    # Escape for JSON (macOS compatible)
    local json_text=$(printf '%s' "$plain_msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    # Send via Telegram Bot API
    local response=$(telegram_curl "sendMessage" -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
            \"text\": ${json_text},
            \"disable_notification\": false
        }" 2>/dev/null)

    if echo "$response" | grep -q '"ok":true'; then
        # Extract message_id for reply context tracking
        local sent_message_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['message_id'])" 2>/dev/null || echo "")

        log "Telegram: Sent successfully (message_id: $sent_message_id)"

        # Store context in telegram_context table if entity info provided
        if [[ -n "$ENTITY_TYPE" ]] && [[ -n "$ENTITY_ID" ]] && [[ -n "$sent_message_id" ]]; then
            local context_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
            sqlite3 "$HYDRA_DB" "
                INSERT INTO telegram_context (id, telegram_message_id, hydra_entity_type, hydra_entity_id)
                VALUES ('$context_id', $sent_message_id, '$ENTITY_TYPE', '$ENTITY_ID');
            " 2>/dev/null || true
            log "Telegram: Context stored for $ENTITY_TYPE/$ENTITY_ID -> msg $sent_message_id"
        fi

        return 0
    else
        log "Telegram: Send failed - $response"
        return 1
    fi
}

# ============================================================================
# CHANNEL 2: MACOS NOTIFICATION (terminal-notifier)
# ============================================================================

send_macos_notification() {
    local title="$1"
    local msg="$2"
    local file="$3"

    if ! command -v terminal-notifier &> /dev/null; then
        log "macOS: terminal-notifier not installed"
        return 1
    fi

    local args=(
        -title "$title"
        -message "$msg"
        -sound default
    )

    # Add click action if file provided
    if [[ -n "$file" ]] && [[ -f "$file" ]]; then
        args+=(-open "file://$file")
    fi

    # Set notification group for HYDRA
    args+=(-group "com.hydra.notifications")

    # Sender icon (uses Terminal if available)
    args+=(-sender "com.apple.Terminal")

    terminal-notifier "${args[@]}" 2>/dev/null
    log "macOS: Notification sent"
    return 0
}

# ============================================================================
# CHANNEL 3: MACDOWN (open markdown file)
# ============================================================================

open_in_macdown() {
    local file="$1"

    if [[ -z "$file" ]] || [[ ! -f "$file" ]]; then
        log "MacDown: No file to open"
        return 1
    fi

    # Check if MacDown is installed
    if [[ -d "/Applications/MacDown.app" ]]; then
        open -a "MacDown" "$file" 2>/dev/null
        log "MacDown: Opened $file"
        return 0
    else
        # Fallback to default markdown viewer
        open "$file" 2>/dev/null
        log "MacDown: Not installed, using default app for $file"
        return 0
    fi
}

# ============================================================================
# DISPATCH BASED ON PRIORITY
# ============================================================================

case "$PRIORITY" in
    urgent)
        log "Priority: URGENT - All channels"

        # All three channels
        send_telegram "$MESSAGE" || true
        send_macos_notification "🚨 $TITLE" "$MESSAGE" "$FILE_TO_OPEN" || true

        if [[ -n "$FILE_TO_OPEN" ]]; then
            sleep 1  # Let notification show first
            open_in_macdown "$FILE_TO_OPEN" || true
        fi
        ;;

    high)
        log "Priority: HIGH - macOS + MacDown"

        # macOS notification + open file
        send_macos_notification "⚠️ $TITLE" "$MESSAGE" "$FILE_TO_OPEN" || true

        if [[ -n "$FILE_TO_OPEN" ]]; then
            sleep 1
            open_in_macdown "$FILE_TO_OPEN" || true
        fi
        ;;

    normal)
        log "Priority: NORMAL - macOS only"

        # Just macOS notification
        send_macos_notification "$TITLE" "$MESSAGE" "$FILE_TO_OPEN" || true
        ;;

    silent)
        log "Priority: SILENT - Log only"
        # Already logged above, nothing else to do
        ;;

    *)
        log "Unknown priority: $PRIORITY, treating as normal"
        send_macos_notification "$TITLE" "$MESSAGE" "$FILE_TO_OPEN" || true
        ;;
esac

log "Dispatch complete"
echo "Notification dispatched: [$PRIORITY] $TITLE"
