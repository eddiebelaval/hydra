#!/bin/bash
# milo-telegram-listener.sh - Milo Personal Assistant Telegram Daemon
#
# Long-polling daemon that receives Telegram messages and dispatches
# to the TypeScript CaF responder. Every message goes through the same
# pipeline: CaF consciousness + context + Claude API + tool_use.
#
# Follows the HYDRA daemon pattern (telegram-listener.sh template).

set -euo pipefail

# ============================================================================
# LOCKFILE (prevent duplicate listeners)
# ============================================================================

LOCK_DIR="$HOME/.hydra/state/milo-telegram-listener.lockdir"
LOCK_FILE="$LOCK_DIR/pid"

if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_FILE"
else
    sleep 3
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        OLD_CMD=$(ps -p "$OLD_PID" -o args= 2>/dev/null || true)
        if echo "$OLD_CMD" | grep -q "milo-telegram-listener"; then
            echo "Already running (PID $OLD_PID). Exiting."
            exit 0
        fi
    fi
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Lock race lost on retry. Exiting."
        exit 0
    fi
    echo $$ > "$LOCK_FILE"
fi

# ============================================================================
# CLEANUP TRAP
# ============================================================================

cleanup() {
    if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
    [[ -n "${updates_dir:-}" ]] && rm -rf "$updates_dir"
}
trap cleanup EXIT

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
STATE_DIR="$HYDRA_ROOT/state"
OFFSET_FILE="$STATE_DIR/milo-telegram-offset.txt"
SESSION_FILE="$STATE_DIR/milo-session-id.txt"
RESPONDER="$HYDRA_ROOT/tools/hydra-router"
MILO_RESPOND="$HYDRA_ROOT/tools/milo-respond"

LOG_DIR="$HOME/Library/Logs/claude-automation/milo-telegram"
LOG_FILE="$LOG_DIR/listener-$(date +%Y-%m-%d).log"

# Load shared creds (ANTHROPIC_API_KEY)
TELEGRAM_CONFIG="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$TELEGRAM_CONFIG" ]]; then
    source "$TELEGRAM_CONFIG"
fi

# Load Milo-specific config
MILO_CONFIG="$HYDRA_ROOT/config/milo-telegram.env"
if [[ -f "$MILO_CONFIG" ]]; then
    source "$MILO_CONFIG"
fi

MILO_BOT_TOKEN="${MILO_TELEGRAM_BOT_TOKEN:-}"
MILO_CHAT_ID="${MILO_TELEGRAM_CHAT_ID:-}"
MILO_API="https://api.telegram.org/bot${MILO_BOT_TOKEN}"

# Polling settings
POLL_TIMEOUT=30
ERROR_BACKOFF_BASE=5
ERROR_BACKOFF_MAX=300
CURRENT_BACKOFF=0

# Session timeout (4 hours default) -- controls session_id rotation
SESSION_TIMEOUT="${MILO_SESSION_TIMEOUT:-14400}"

# Lock-in threshold (2 hours default) -- triggers proactive catch-up surfacing
# in Milo's response when Eddie returns after being away this long. Distinct
# from SESSION_TIMEOUT: lock-in fires more often than session rotation so
# lunch-break gaps get catch-up without rotating the conversation.
MILO_LOCKIN_THRESHOLD="${MILO_LOCKIN_THRESHOLD:-7200}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

log "Starting Milo Telegram Listener (PID $$)"

if [[ -z "$MILO_BOT_TOKEN" ]] || [[ "$MILO_BOT_TOKEN" == "YOUR_TOKEN_HERE" ]]; then
    log_error "Milo bot token not configured. Exiting."
    exit 1
fi

if [[ -z "$MILO_CHAT_ID" ]]; then
    log_error "Milo chat ID not configured. Exiting."
    exit 1
fi

export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log_error "ANTHROPIC_API_KEY not set. Exiting."
    exit 1
fi

# Export for the TS responder
export HYDRA_DB
export MILO_CHAT_MODEL="${MILO_CHAT_MODEL:-claude-sonnet-4-20250514}"
export MILO_EXTRACTION_MODEL="${MILO_EXTRACTION_MODEL:-claude-haiku-4-5-20251001}"
export MILO_ROLLING_WINDOW="${MILO_ROLLING_WINDOW:-40}"
export MILO_SUMMARY_COUNT="${MILO_SUMMARY_COUNT:-5}"
export MILO_MEMORY_LIMIT="${MILO_MEMORY_LIMIT:-20}"
export MILO_MAX_TOOL_LOOPS="${MILO_MAX_TOOL_LOOPS:-5}"

# ============================================================================
# TELEGRAM HELPERS
# ============================================================================

telegram_curl() {
    curl -s --connect-timeout 10 --max-time 60 "$@"
}

send_typing() {
    telegram_curl -X POST "$MILO_API/sendChatAction" \
        -d "chat_id=$MILO_CHAT_ID" \
        -d "action=typing" >/dev/null 2>&1 || true
}

send_message() {
    local text="$1"
    local reply_to="${2:-}"

    # Chunk if needed (Telegram limit: 4096)
    if [[ ${#text} -le 4000 ]]; then
        _send_single "$text" "$reply_to"
    else
        # Split at paragraph boundaries
        local chunk=""
        while IFS= read -r line; do
            if [[ ${#chunk} -gt 0 ]] && [[ $(( ${#chunk} + ${#line} + 1 )) -gt 3900 ]]; then
                _send_single "$chunk" "$reply_to"
                chunk="$line"
                reply_to="" # Only reply-to on first chunk
            else
                [[ -n "$chunk" ]] && chunk="$chunk
$line" || chunk="$line"
            fi
        done <<< "$text"
        [[ -n "$chunk" ]] && _send_single "$chunk" "$reply_to"
    fi
}

_send_single() {
    local text="$1"
    local reply_to="${2:-}"

    # Use --data-urlencode for safe encoding of arbitrary text
    local args=(-X POST "$MILO_API/sendMessage"
        --data-urlencode "text=$text"
        -d "chat_id=$MILO_CHAT_ID")

    [[ -n "$reply_to" ]] && args+=(-d "reply_to_message_id=$reply_to")

    telegram_curl "${args[@]}" >/dev/null 2>&1 || true
}

# ============================================================================
# SESSION MANAGEMENT
# ============================================================================

get_session_id() {
    # Check if current session is stale
    local last_turn
    last_turn=$(sqlite3 "$HYDRA_DB" "SELECT MAX(created_at) FROM milo_conversations;" 2>/dev/null || echo "")

    if [[ -n "$last_turn" ]]; then
        local last_epoch
        last_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_turn" "+%s" 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date "+%s")
        local gap=$(( now_epoch - last_epoch ))

        if [[ $gap -gt $SESSION_TIMEOUT ]]; then
            # Session expired, create new one
            uuidgen | tr '[:upper:]' '[:lower:]' > "$SESSION_FILE"
            log "New session (${gap}s gap): $(cat "$SESSION_FILE")"
        fi
    fi

    # Return current session ID or create first one
    if [[ ! -f "$SESSION_FILE" ]]; then
        uuidgen | tr '[:upper:]' '[:lower:]' > "$SESSION_FILE"
        log "Initial session: $(cat "$SESSION_FILE")"
    fi

    cat "$SESSION_FILE"
}

# ============================================================================
# MESSAGE PROCESSOR
# ============================================================================

process_message() {
    local json_file="$1"

    # Extract fields
    local chat_id text message_id
    chat_id=$(python3 -c "import json; d=json.load(open('$json_file')); print(d.get('message',{}).get('chat',{}).get('id',''))" 2>/dev/null || echo "")
    text=$(python3 -c "import json; d=json.load(open('$json_file')); print(d.get('message',{}).get('text',''))" 2>/dev/null || echo "")
    message_id=$(python3 -c "import json; d=json.load(open('$json_file')); print(d.get('message',{}).get('message_id',''))" 2>/dev/null || echo "")

    # Auth gate: only Eddie
    if [[ "$chat_id" != "$MILO_CHAT_ID" ]]; then
        log "Ignored message from unauthorized chat: $chat_id"
        return
    fi

    # Skip empty messages
    if [[ -z "$text" ]]; then
        # TODO: handle voice messages via whisper.cpp
        log "Skipped non-text message (message_id: $message_id)"
        return
    fi

    log "Processing message from Eddie: ${text:0:100}..."

    # Send typing indicator
    send_typing

    # Get or rotate session
    local session_id
    session_id=$(get_session_id)

    # Lock-in freshness check: if Eddie has been away from this chat for
    # >= MILO_LOCKIN_THRESHOLD seconds (based on his last user-role turn),
    # pass --lockin-fresh so Milo proactively surfaces new bulletin entries
    # and task changes on the opening. This is separate from session rotation.
    local lockin_flag=""
    local last_user_turn
    last_user_turn=$(sqlite3 "$HYDRA_DB" "SELECT MAX(created_at) FROM milo_conversations WHERE role='user';" 2>/dev/null || echo "")
    if [[ -n "$last_user_turn" ]]; then
        local last_user_epoch
        last_user_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_user_turn" "+%s" 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date "+%s")
        local user_gap=$(( now_epoch - last_user_epoch ))
        if [[ $user_gap -ge $MILO_LOCKIN_THRESHOLD ]]; then
            lockin_flag="--lockin-fresh"
            log "Lock-in fresh (${user_gap}s gap, threshold ${MILO_LOCKIN_THRESHOLD}s)"
        fi
    fi

    # Write message to temp file for safe passing (avoids shell escaping issues)
    local msg_tmp
    msg_tmp=$(mktemp)
    echo "$text" > "$msg_tmp"

    # Dispatch to TypeScript responder
    local response resp_tmp
    resp_tmp=$(mktemp)
    if cd "$RESPONDER" && node --import tsx/esm src/index.ts \
        --message "$(cat "$msg_tmp")" \
        --message-id "$message_id" \
        --session-id "$session_id" \
        $lockin_flag \
        >"$resp_tmp" 2>>"$LOG_FILE"; then

        response=$(cat "$resp_tmp")
    else
        log_error "Responder failed for message: ${text:0:50}"
        send_message "Something went wrong. Check the logs." "$message_id"
        rm -f "$msg_tmp" "$resp_tmp"
        return
    fi

    if [[ -n "$response" ]]; then
        send_message "$response" "$message_id"
        log "Sent response (${#response} chars)"

        # Async: extract memories + mood (non-blocking)
        (cd "$MILO_RESPOND" && node --import tsx/esm src/extract-memories.ts \
            --user-message "$(cat "$msg_tmp")" \
            --assistant-message "$response" \
            2>>"$LOG_FILE") &

        # Async: check if summarization needed
        (cd "$MILO_RESPOND" && node --import tsx/esm src/summarize.ts 2>>"$LOG_FILE") &
    else
        log_error "Empty response from responder"
    fi

    rm -f "$msg_tmp" "$resp_tmp"
}

# ============================================================================
# CONFLICT DETECTION (Telegram only allows one getUpdates consumer)
# ============================================================================

log "Running conflict detection..."
CONFLICT_COUNT=0
for _ in 1 2 3; do
    CURRENT_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")
    result=$(telegram_curl "$MILO_API/getUpdates?offset=$CURRENT_OFFSET&limit=1&timeout=1" 2>&1)
    if echo "$result" | grep -q '"error_code":409'; then
        CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
    fi
done

if [[ $CONFLICT_COUNT -ge 3 ]]; then
    log_error "CONFLICT: Another process is polling this bot token (3 consecutive 409s)"
    osascript -e 'display notification "Milo bot conflict: another consumer is polling." with title "HYDRA: Milo Conflict" sound name "Basso"' 2>/dev/null || true
    exit 1
fi
log "Conflict detection passed."

# ============================================================================
# MAIN POLLING LOOP
# ============================================================================

log "Entering main polling loop..."

while true; do
    CURRENT_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

    # Long poll
    updates_dir=$(mktemp -d)
    updates_file="$updates_dir/updates.json"

    http_code=$(telegram_curl -o "$updates_file" -w "%{http_code}" \
        "$MILO_API/getUpdates?offset=$CURRENT_OFFSET&limit=10&timeout=$POLL_TIMEOUT" 2>/dev/null || echo "000")

    if [[ "$http_code" != "200" ]]; then
        log_error "Telegram API returned HTTP $http_code"

        if [[ "$http_code" == "409" ]]; then
            log_error "409 Conflict - another consumer. Backing off."
        fi

        CURRENT_BACKOFF=$((CURRENT_BACKOFF + ERROR_BACKOFF_BASE))
        [[ $CURRENT_BACKOFF -gt $ERROR_BACKOFF_MAX ]] && CURRENT_BACKOFF=$ERROR_BACKOFF_MAX
        sleep $CURRENT_BACKOFF
        rm -rf "$updates_dir"
        continue
    fi

    # Reset backoff on success
    CURRENT_BACKOFF=0

    # Check for valid response
    ok=$(python3 -c "import json; d=json.load(open('$updates_file')); print(d.get('ok', False))" 2>/dev/null || echo "False")
    if [[ "$ok" != "True" ]]; then
        log_error "Telegram response not ok"
        rm -rf "$updates_dir"
        sleep 2
        continue
    fi

    # Process updates
    update_count=$(python3 -c "import json; d=json.load(open('$updates_file')); print(len(d.get('result', [])))" 2>/dev/null || echo "0")

    if [[ "$update_count" -gt 0 ]]; then
        # Split updates into individual files and get max update_id
        max_update_id=$(python3 -c "
import json
with open('$updates_file') as f:
    data = json.load(f)
max_id = 0
for i, update in enumerate(data.get('result', [])):
    with open(f'$updates_dir/update_{i}.json', 'w') as out:
        json.dump(update, out)
    uid = update.get('update_id', 0)
    if uid > max_id:
        max_id = uid
print(max_id)
" 2>/dev/null || echo "0")

        # Process each update
        for update_file in "$updates_dir"/update_*.json; do
            [[ -f "$update_file" ]] || continue
            process_message "$update_file"
        done

        # Update offset to max + 1
        if [[ "$max_update_id" -gt 0 ]]; then
            echo "$((max_update_id + 1))" > "$OFFSET_FILE"
        fi
    fi

    rm -rf "$updates_dir"
done
