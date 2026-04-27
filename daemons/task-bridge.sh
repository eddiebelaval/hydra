#!/bin/bash
# task-bridge.sh - HYDRA <-> MILO Bidirectional Task Sync
#
# Runs daily at 5:50 AM via launchd (before task-sweeper at 5:55, brain-updater at 6:00).
#
# Direction 1 (HYDRA -> MILO): Active HYDRA tasks are mirrored into MILO's task DB
#   so Eddie sees everything in one place. Uses hydra_bridge_id in rationale for provenance.
#
# Direction 2 (MILO -> HYDRA): When bridged tasks are completed in MILO,
#   the corresponding HYDRA task is marked completed too.
#
# Rules:
#   - Never deletes tasks in either direction
#   - Deduplicates by checking for hydra_bridge_id in MILO's rationale field
#   - Writes sync state to ~/.hydra/state/task-bridge-state.json

set -eo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
MILO_DB="$HOME/Library/Application Support/milo/data/milo.db"
STATE_FILE="$HOME/.hydra/state/task-bridge-state.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-task-bridge"
LOG_FILE="$LOG_DIR/bridge-$(date +%Y-%m-%d).log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date +%Y-%m-%d)

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== Task bridge starting ==="

# Verify both databases exist
if [[ ! -f "$HYDRA_DB" ]]; then
    log "ERROR: HYDRA DB not found at $HYDRA_DB"
    exit 1
fi

if [[ ! -f "$MILO_DB" ]]; then
    log "ERROR: MILO DB not found at $MILO_DB"
    exit 1
fi

# ============================================================================
# DIRECTION 1: HYDRA -> MILO (active HYDRA tasks become MILO tasks)
# ============================================================================

SYNCED_TO_MILO=0
SKIPPED=0

log "--- HYDRA -> MILO ---"

# Read active HYDRA tasks
while IFS='|' read -r h_id h_title h_desc h_status h_priority h_due h_source h_source_job; do
    # Skip if already bridged to MILO
    BRIDGE_TAG="hydra_bridge_id:${h_id}"
    EXISTS=$(sqlite3 "$MILO_DB" "SELECT COUNT(*) FROM tasks WHERE rationale LIKE '%${BRIDGE_TAG}%';" 2>/dev/null || echo "0")

    if [[ "$EXISTS" -gt 0 ]]; then
        # Task already bridged -- check if HYDRA status changed
        MILO_STATUS=$(sqlite3 "$MILO_DB" "SELECT status FROM tasks WHERE rationale LIKE '%${BRIDGE_TAG}%' LIMIT 1;" 2>/dev/null || echo "")

        # Map HYDRA status to MILO status
        case "$h_status" in
            blocked) MAPPED_STATUS="deferred" ;;
            in_progress) MAPPED_STATUS="in_progress" ;;
            pending) MAPPED_STATUS="pending" ;;
            *) MAPPED_STATUS="$h_status" ;;
        esac

        # Update MILO if status diverged (but don't overwrite MILO completions)
        if [[ "$MILO_STATUS" != "completed" ]] && [[ "$MILO_STATUS" != "$MAPPED_STATUS" ]]; then
            sqlite3 "$MILO_DB" "UPDATE tasks SET status = '$MAPPED_STATUS', updated_at = datetime('now') WHERE rationale LIKE '%${BRIDGE_TAG}%';" 2>/dev/null
            log "  Updated: '$h_title' -> $MAPPED_STATUS in MILO"
        fi

        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Map HYDRA status to MILO
    case "$h_status" in
        blocked) MILO_STATUS="deferred" ;;
        *) MILO_STATUS="$h_status" ;;
    esac

    # Clamp priority (both use 1-5 compatible range, HYDRA max is 4)
    MILO_PRIORITY="$h_priority"
    if [[ "$MILO_PRIORITY" -gt 5 ]]; then MILO_PRIORITY=5; fi
    if [[ "$MILO_PRIORITY" -lt 1 ]]; then MILO_PRIORITY=1; fi

    # Scheduled date: use due_at if set, otherwise today
    SCHED_DATE="${h_due:-$TODAY}"

    # Build rationale with bridge provenance
    SAFE_TITLE=$(echo "$h_title" | sed "s/'/''/g")
    SAFE_DESC=$(echo "$h_desc" | sed "s/'/''/g")
    SOURCE_INFO="${h_source}${h_source_job:+ / $h_source_job}"
    RATIONALE="[${BRIDGE_TAG}] Source: ${SOURCE_INFO}"
    SAFE_RATIONALE=$(echo "$RATIONALE" | sed "s/'/''/g")

    # Generate UUID for MILO
    MILO_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

    sqlite3 "$MILO_DB" "
        INSERT INTO tasks (id, title, description, status, priority, rationale, scheduled_date, created_at, updated_at, days_worked)
        VALUES ('$MILO_ID', '$SAFE_TITLE', '$SAFE_DESC', '$MILO_STATUS', $MILO_PRIORITY, '$SAFE_RATIONALE', '$SCHED_DATE', datetime('now'), datetime('now'), 0);
    " 2>/dev/null

    if [[ $? -eq 0 ]]; then
        log "  Bridged: '$h_title' (HYDRA $h_id -> MILO $MILO_ID)"
        SYNCED_TO_MILO=$((SYNCED_TO_MILO + 1))
    else
        log "  FAILED to bridge: '$h_title'"
    fi

done < <(sqlite3 "$HYDRA_DB" "
    SELECT id, title, COALESCE(description,''), status, priority, due_at, COALESCE(source,''), COALESCE(source_job,'')
    FROM tasks
    WHERE status NOT IN ('completed', 'cancelled')
    ORDER BY priority, created_at;
" 2>/dev/null)

log "HYDRA -> MILO: $SYNCED_TO_MILO new, $SKIPPED already bridged"

# ============================================================================
# DIRECTION 2: MILO -> HYDRA (bridged tasks completed in MILO update HYDRA)
# ============================================================================

SYNCED_BACK=0

log "--- MILO -> HYDRA ---"

# Find bridged tasks that are completed in MILO
while IFS='|' read -r m_rationale m_completed_at; do
    # Extract HYDRA ID from rationale
    HYDRA_ID=$(echo "$m_rationale" | sed -n 's/.*hydra_bridge_id:\([^] ]*\).*/\1/p')

    if [[ -z "$HYDRA_ID" ]]; then continue; fi

    # Check if HYDRA task is already completed
    H_STATUS=$(sqlite3 "$HYDRA_DB" "SELECT status FROM tasks WHERE id = '$HYDRA_ID';" 2>/dev/null || echo "")

    if [[ "$H_STATUS" == "completed" ]] || [[ "$H_STATUS" == "cancelled" ]]; then
        continue
    fi

    # Mark completed in HYDRA
    sqlite3 "$HYDRA_DB" "
        UPDATE tasks SET status = 'completed', completed_at = COALESCE('$m_completed_at', datetime('now')), updated_at = datetime('now')
        WHERE id = '$HYDRA_ID';
    " 2>/dev/null

    if [[ $? -eq 0 ]]; then
        log "  Completed in HYDRA: $HYDRA_ID (synced from MILO)"
        SYNCED_BACK=$((SYNCED_BACK + 1))
    fi

done < <(sqlite3 "$MILO_DB" "
    SELECT rationale, completed_at
    FROM tasks
    WHERE status = 'completed'
    AND rationale LIKE '%hydra_bridge_id:%';
" 2>/dev/null)

log "MILO -> HYDRA: $SYNCED_BACK completions synced back"

# ============================================================================
# WRITE STATE
# ============================================================================

cat > "$STATE_FILE" << EOF
{
    "last_sync": "$TIMESTAMP",
    "hydra_to_milo": $SYNCED_TO_MILO,
    "milo_to_hydra": $SYNCED_BACK,
    "skipped": $SKIPPED
}
EOF

log "State written to $STATE_FILE"
log "=== Task bridge complete ==="
