#!/bin/bash
# hydra-route-message.sh - Process a message for @mentions and routing
# Called by OpenClaw hook or manually
#
# Usage: hydra-route-message.sh --channel telegram --sender user --content "Hey @forge fix the bug"
# Or:    echo "message content" | hydra-route-message.sh --channel telegram --sender user

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
LOGS_DIR="$HOME/Library/Logs/claude-automation/hydra-routing"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOGS_DIR/routing-$DATE.log"

mkdir -p "$LOGS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Parse arguments
CHANNEL=""
SENDER=""
CONTENT=""
THREAD_ID=""
REPLIED_TO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --sender)
            SENDER="$2"
            shift 2
            ;;
        --content)
            CONTENT="$2"
            shift 2
            ;;
        --thread)
            THREAD_ID="$2"
            shift 2
            ;;
        --reply-to)
            REPLIED_TO="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Read from stdin if content not provided
if [[ -z "$CONTENT" ]]; then
    CONTENT=$(cat)
fi

# Validate required fields
if [[ -z "$CHANNEL" ]] || [[ -z "$SENDER" ]] || [[ -z "$CONTENT" ]]; then
    echo "Usage: hydra-route-message.sh --channel <channel> --sender <sender> --content <content>"
    echo "       or pipe content: echo 'message' | hydra-route-message.sh --channel <channel> --sender <sender>"
    exit 1
fi

# Generate IDs
MESSAGE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
if [[ -z "$THREAD_ID" ]]; then
    THREAD_ID="$MESSAGE_ID"  # New thread
fi

log "Processing message: channel=$CHANNEL sender=$SENDER thread=$THREAD_ID"

# Escape content for SQL
escape_sql() {
    echo "$1" | sed "s/'/''/g"
}

SAFE_CONTENT=$(escape_sql "$CONTENT")

# ============================================================================
# STEP 1: Parse @mentions
# ============================================================================

MENTIONS=""
MENTION_LIST=""

# Check for each agent
if echo "$CONTENT" | grep -qi "@milo"; then
    MENTIONS="${MENTIONS}milo,"
    MENTION_LIST="${MENTION_LIST}milo "
fi

if echo "$CONTENT" | grep -qi "@forge"; then
    MENTIONS="${MENTIONS}forge,"
    MENTION_LIST="${MENTION_LIST}forge "
fi

if echo "$CONTENT" | grep -qi "@scout"; then
    MENTIONS="${MENTIONS}scout,"
    MENTION_LIST="${MENTION_LIST}scout "
fi

if echo "$CONTENT" | grep -qi "@pulse"; then
    MENTIONS="${MENTIONS}pulse,"
    MENTION_LIST="${MENTION_LIST}pulse "
fi

if echo "$CONTENT" | grep -qi "@ava"; then
    MENTIONS="${MENTIONS}ava,"
    MENTION_LIST="${MENTION_LIST}ava "
fi

# @all mentions everyone
if echo "$CONTENT" | grep -qi "@all"; then
    MENTIONS="milo,forge,scout,pulse,ava,"
    MENTION_LIST="milo forge scout pulse ava"
fi

# Remove trailing comma
MENTIONS=$(echo "$MENTIONS" | sed 's/,$//')

log "Mentions found: ${MENTION_LIST:-none}"

# ============================================================================
# STEP 2: Store message in database
# ============================================================================

sqlite3 "$HYDRA_DB" "
    INSERT INTO messages (id, channel, thread_id, sender, content, mentions, replied_to)
    VALUES ('$MESSAGE_ID', '$CHANNEL', '$THREAD_ID', '$SENDER', '$SAFE_CONTENT',
            CASE WHEN '$MENTIONS' = '' THEN NULL ELSE '[\"' || REPLACE('$MENTIONS', ',', '\",\"') || '\"]' END,
            CASE WHEN '$REPLIED_TO' = '' THEN NULL ELSE '$REPLIED_TO' END);
" 2>/dev/null

log "Message stored: $MESSAGE_ID"

# ============================================================================
# STEP 3: Create notifications for mentioned agents
# ============================================================================

NOTIFICATIONS_CREATED=0

for AGENT in $MENTION_LIST; do
    NOTIF_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Determine priority (user messages are normal, urgent keywords boost priority)
    PRIORITY="normal"
    if echo "$CONTENT" | grep -qiE "urgent|critical|emergency|asap|immediately"; then
        PRIORITY="urgent"
    fi

    # Create preview (first 100 chars)
    PREVIEW=$(echo "$CONTENT" | head -c 100 | sed "s/'/''/g")

    sqlite3 "$HYDRA_DB" "
        INSERT INTO notifications (id, target_agent, notification_type, source_type, source_id, priority, content_preview)
        VALUES ('$NOTIF_ID', '$AGENT', 'mention', 'message', '$MESSAGE_ID', '$PRIORITY', '$PREVIEW');
    " 2>/dev/null

    NOTIFICATIONS_CREATED=$((NOTIFICATIONS_CREATED + 1))
    log "Notification created for @$AGENT (priority: $PRIORITY)"
done

# ============================================================================
# STEP 4: Auto-subscribe sender to thread (if agent)
# ============================================================================

if [[ "$SENDER" =~ ^(milo|forge|scout|pulse)$ ]]; then
    SUB_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Check if already subscribed
    EXISTING=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM subscriptions WHERE agent_id = '$SENDER' AND thread_id = '$THREAD_ID';" 2>/dev/null || echo "0")

    if [[ "$EXISTING" -eq 0 ]]; then
        sqlite3 "$HYDRA_DB" "
            INSERT INTO subscriptions (id, agent_id, thread_id, reason)
            VALUES ('$SUB_ID', '$SENDER', '$THREAD_ID', 'replied');
        " 2>/dev/null
        log "Auto-subscribed $SENDER to thread $THREAD_ID"
    fi
fi

# ============================================================================
# STEP 5: Notify thread subscribers (if this is a reply)
# ============================================================================

if [[ -n "$REPLIED_TO" ]] || [[ "$THREAD_ID" != "$MESSAGE_ID" ]]; then
    # Get all subscribers to this thread (except sender)
    SUBSCRIBERS=$(sqlite3 "$HYDRA_DB" "
        SELECT agent_id FROM subscriptions
        WHERE thread_id = '$THREAD_ID'
        AND agent_id != '$SENDER'
        AND unsubscribed_at IS NULL;
    " 2>/dev/null || echo "")

    for SUB_AGENT in $SUBSCRIBERS; do
        # Don't duplicate if already mentioned
        if ! echo "$MENTION_LIST" | grep -q "$SUB_AGENT"; then
            NOTIF_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
            PREVIEW=$(echo "$CONTENT" | head -c 100 | sed "s/'/''/g")

            sqlite3 "$HYDRA_DB" "
                INSERT INTO notifications (id, target_agent, notification_type, source_type, source_id, priority, content_preview)
                VALUES ('$NOTIF_ID', '$SUB_AGENT', 'thread_activity', 'message', '$MESSAGE_ID', 'low', '$PREVIEW');
            " 2>/dev/null

            NOTIFICATIONS_CREATED=$((NOTIFICATIONS_CREATED + 1))
            log "Thread notification for subscriber $SUB_AGENT"
        fi
    done
fi

# ============================================================================
# STEP 6: Log activity
# ============================================================================

ACTIVITY_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
    VALUES ('$ACTIVITY_ID',
            CASE WHEN '$SENDER' IN ('milo','forge','scout','pulse') THEN '$SENDER' ELSE NULL END,
            'message_received', 'message', '$MESSAGE_ID',
            'Message from $SENDER in $CHANNEL' || CASE WHEN '$MENTIONS' != '' THEN ' mentioning $MENTIONS' ELSE '' END);
" 2>/dev/null

# ============================================================================
# OUTPUT
# ============================================================================

echo "message_id=$MESSAGE_ID"
echo "thread_id=$THREAD_ID"
echo "mentions=$MENTIONS"
echo "notifications_created=$NOTIFICATIONS_CREATED"

log "Complete: message_id=$MESSAGE_ID notifications=$NOTIFICATIONS_CREATED"
