#!/bin/bash
# todo-sync.sh — Per-Project TODO.md <-> Milo DB Bidirectional Sync
#
# Runs daily at 5:45 AM via launchd (before task-bridge at 5:50).
#
# Direction 1 (TODO.md -> Milo): Parse each project's TODO.md, insert
#   new tasks into Milo DB with todo_id provenance tags.
#
# Direction 2 (Milo -> TODO.md): When Milo marks a bridged task completed,
#   update the checkbox in the TODO.md file.
#
# Follows the same patterns as task-bridge.sh: provenance tags in rationale,
# state file, logging, lockfile.

set -eo pipefail

# ============================================================================
# CONFIG
# ============================================================================

MILO_DB="$HOME/Library/Application Support/milo/data/milo.db"
STATE_FILE="$HOME/.hydra/state/todo-sync-state.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/todo-sync"
LOG_FILE="$LOG_DIR/sync-$(date +%Y-%m-%d).log"
LOCK_DIR="$HOME/.hydra/state/todo-sync.lockdir"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date +%Y-%m-%d)

# Source project registry
source "$HOME/.hydra/config/todo-projects.sh"

mkdir -p "$LOG_DIR"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

# ============================================================================
# LOCKFILE
# ============================================================================

if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
else
    OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    echo $$ > "$LOCK_DIR/pid"
fi

cleanup() {
    if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# VERIFY MILO DB
# ============================================================================

if [[ ! -f "$MILO_DB" ]]; then
    log "ERROR: Milo DB not found at $MILO_DB"
    exit 1
fi

log "=== TODO sync starting ==="

# ============================================================================
# HELPER: Parse a TODO.md task line
# Returns: STATUS, TITLE, PRIORITY, OWNER, TASK_ID, CREATED, DONE_DATE
# ============================================================================

parse_todo_line() {
    local line="$1"
    STATUS="" TITLE="" PRIORITY="3" OWNER="" TASK_ID="" CREATED="" DONE_DATE=""

    # Match checkbox line
    if [[ "$line" =~ ^-\ \[([\ xX])\]\ (.+)$ ]]; then
        local checked="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"

        if [[ "$checked" == " " ]]; then
            STATUS="pending"
        else
            STATUS="completed"
        fi

        # Extract tags
        PRIORITY=$(echo "$rest" | grep -o '`p:[0-9]`' | head -1 | tr -dc '0-9' || echo "3")
        [[ -z "$PRIORITY" ]] && PRIORITY="3"
        OWNER=$(echo "$rest" | grep -o '`@[^`]*`' | head -1 | sed 's/`@//;s/`//' || echo "")
        TASK_ID=$(echo "$rest" | grep -o '`id:[^`]*`' | head -1 | sed 's/`id://;s/`//' || echo "")
        CREATED=$(echo "$rest" | grep -o '`created:[^`]*`' | head -1 | sed 's/`created://;s/`//' || echo "")
        DONE_DATE=$(echo "$rest" | grep -o '`done:[^`]*`' | head -1 | sed 's/`done://;s/`//' || echo "")

        # Title = line minus all backtick tags, trimmed
        TITLE=$(echo "$rest" | sed 's/`[^`]*`//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        return 0
    fi
    return 1
}

# ============================================================================
# HELPER: Get next available ID for a prefix
# ============================================================================

next_id() {
    local file="$1"
    local prefix="$2"

    local max_num=0
    while IFS= read -r line; do
        local num=$(echo "$line" | grep -o "\`id:${prefix}-[0-9]*\`" | head -1 | sed "s/\`id:${prefix}-//;s/\`//" || echo "")
        if [[ -n "$num" ]] && [[ "$num" -gt "$max_num" ]]; then
            max_num="$num"
        fi
    done < "$file"

    printf "%s-%03d" "$prefix" $((max_num + 1))
}

# ============================================================================
# HELPER: Ensure project exists in Milo DB, return project_id
# ============================================================================

ensure_milo_project() {
    local proj_name="$1"
    local proj_path="$2"

    local existing
    existing=$(sqlite3 "$MILO_DB" "SELECT id FROM projects WHERE name = '${proj_name}' LIMIT 1;" 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        echo "$existing"
        return
    fi

    local proj_id
    proj_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    sqlite3 "$MILO_DB" "
        INSERT INTO projects (id, name, path, status, created_at, updated_at)
        VALUES ('$proj_id', '$proj_name', '$proj_path', 'active', datetime('now'), datetime('now'));
    " 2>/dev/null

    log "  Created Milo project: $proj_name ($proj_id)"
    echo "$proj_id"
}

# ============================================================================
# DIRECTION 1: TODO.md -> Milo DB
# ============================================================================

TOTAL_NEW=0
TOTAL_UPDATED=0
TOTAL_SKIPPED=0
TOTAL_IDS_ASSIGNED=0
FILES_PROCESSED=0

for entry in "${TODO_PROJECTS[@]}"; do
    IFS='|' read -r proj_name todo_path prefix <<< "$entry"

    # Skip if TODO.md doesn't exist yet
    if [[ ! -f "$todo_path" ]]; then
        continue
    fi

    FILES_PROCESSED=$((FILES_PROCESSED + 1))
    log "--- Processing: $proj_name ($todo_path) ---"

    # Ensure project exists in Milo
    proj_dir=$(dirname "$todo_path")
    proj_id=$(ensure_milo_project "$proj_name" "$proj_dir")

    # Track ID assignments for writeback (bash 3 compatible — temp file)
    needs_writeback=false
    ID_MAP_FILE=$(mktemp)

    # Read and parse TODO.md
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        if parse_todo_line "$line"; then
            # Assign ID if missing
            if [[ -z "$TASK_ID" ]]; then
                TASK_ID=$(next_id "$todo_path" "$prefix")
                echo "${line_num}|${TASK_ID}" >> "$ID_MAP_FILE"
                needs_writeback=true
                TOTAL_IDS_ASSIGNED=$((TOTAL_IDS_ASSIGNED + 1))
                log "  Assigned ID: $TASK_ID to '$TITLE'"
            fi

            # Check if already in Milo
            BRIDGE_TAG="todo_id:${TASK_ID}"
            EXISTS=$(sqlite3 "$MILO_DB" "SELECT COUNT(*) FROM tasks WHERE rationale LIKE '%${BRIDGE_TAG}%';" 2>/dev/null || echo "0")

            if [[ "$EXISTS" -gt 0 ]]; then
                # Already bridged — check for status changes
                MILO_STATUS=$(sqlite3 "$MILO_DB" "SELECT status FROM tasks WHERE rationale LIKE '%${BRIDGE_TAG}%' LIMIT 1;" 2>/dev/null || echo "")

                if [[ "$STATUS" == "completed" ]] && [[ "$MILO_STATUS" != "completed" ]]; then
                    # TODO.md marked done, update Milo
                    sqlite3 "$MILO_DB" "
                        UPDATE tasks SET status = 'completed',
                            completed_at = COALESCE('${DONE_DATE}', datetime('now')),
                            updated_at = datetime('now')
                        WHERE rationale LIKE '%${BRIDGE_TAG}%';
                    " 2>/dev/null
                    log "  Completed in Milo: $TASK_ID ('$TITLE')"
                    TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
                else
                    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
                fi
                continue
            fi

            # New task — insert into Milo
            SAFE_TITLE=$(echo "$TITLE" | sed "s/'/''/g")
            RATIONALE="[${BRIDGE_TAG}] project:${proj_name}"
            [[ -n "$OWNER" ]] && RATIONALE="$RATIONALE owner:${OWNER}"

            MILO_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
            SCHED_DATE="${CREATED:-$TODAY}"

            sqlite3 "$MILO_DB" "
                INSERT INTO tasks (id, title, status, priority, rationale, scheduled_date,
                    project_id, created_at, updated_at, days_worked)
                VALUES ('$MILO_ID', '$SAFE_TITLE', '$STATUS', $PRIORITY,
                    '$RATIONALE', '$SCHED_DATE', '$proj_id',
                    datetime('now'), datetime('now'), 0);
            " 2>/dev/null

            if [[ $? -eq 0 ]]; then
                log "  Synced to Milo: $TASK_ID -> $MILO_ID ('$TITLE')"
                TOTAL_NEW=$((TOTAL_NEW + 1))
            else
                log "  FAILED to sync: $TASK_ID ('$TITLE')"
            fi
        fi
    done < "$todo_path"

    # Write back assigned IDs (bash 3 compatible — read from temp file)
    if [[ "$needs_writeback" == true ]] && [[ -s "$ID_MAP_FILE" ]]; then
        tmp=$(mktemp)
        line_num=0
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            new_id=$(grep "^${line_num}|" "$ID_MAP_FILE" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
            if [[ -n "$new_id" ]]; then
                if echo "$line" | grep -q '`'; then
                    line=$(echo "$line" | sed "s/\`/\`id:${new_id}\` \`/1")
                else
                    line="$line \`id:${new_id}\` \`created:${TODAY}\`"
                fi
                log "  Wrote ID $new_id back to line $line_num"
            fi
            echo "$line" >> "$tmp"
        done < "$todo_path"
        mv "$tmp" "$todo_path"
    fi

    rm -f "$ID_MAP_FILE"
done

log "TODO -> Milo: $TOTAL_NEW new, $TOTAL_UPDATED status updates, $TOTAL_SKIPPED unchanged, $TOTAL_IDS_ASSIGNED IDs assigned"

# ============================================================================
# DIRECTION 2: Milo -> TODO.md (reverse-sync completions)
# ============================================================================

REVERSE_SYNCED=0

log "--- Reverse sync: Milo -> TODO.md ---"

# Find Milo tasks with todo_id that are completed
while IFS='|' read -r m_rationale m_completed_at; do
    # Extract todo_id from rationale
    TASK_ID=$(echo "$m_rationale" | sed -n 's/.*todo_id:\([^] ]*\).*/\1/p')
    [[ -z "$TASK_ID" ]] && continue

    # Extract project name
    PROJ_NAME=$(echo "$m_rationale" | sed -n 's/.*project:\([^ ]*\).*/\1/p')
    [[ -z "$PROJ_NAME" ]] && continue

    # Find the TODO.md path for this project
    todo_path=""
    for entry in "${TODO_PROJECTS[@]}"; do
        IFS='|' read -r pn pp px <<< "$entry"
        if [[ "$pn" == "$PROJ_NAME" ]]; then
            todo_path="$pp"
            break
        fi
    done
    [[ -z "$todo_path" ]] || [[ ! -f "$todo_path" ]] && continue

    # Check if the line is still unchecked
    if grep -q "\- \[ \].*\`id:${TASK_ID}\`" "$todo_path"; then
        # Mark as done
        DONE_DATE=$(echo "$m_completed_at" | cut -c1-10)
        [[ -z "$DONE_DATE" ]] && DONE_DATE="$TODAY"

        sed -i '' "s/- \[ \]\(.*\`id:${TASK_ID}\`\)/- [x]\1 \`done:${DONE_DATE}\`/" "$todo_path"
        log "  Reverse-synced: $TASK_ID in $PROJ_NAME (marked done)"
        REVERSE_SYNCED=$((REVERSE_SYNCED + 1))
    fi

done < <(sqlite3 "$MILO_DB" "
    SELECT rationale, completed_at
    FROM tasks
    WHERE status = 'completed'
    AND rationale LIKE '%todo_id:%';
" 2>/dev/null)

log "Milo -> TODO: $REVERSE_SYNCED completions synced back"

# ============================================================================
# UPDATE SYNC TIMESTAMPS
# ============================================================================

for entry in "${TODO_PROJECTS[@]}"; do
    IFS='|' read -r proj_name todo_path prefix <<< "$entry"
    [[ ! -f "$todo_path" ]] && continue

    # Update the "Last synced" line
    if grep -q "^> Last synced by Milo:" "$todo_path"; then
        sed -i '' "s/^> Last synced by Milo:.*/> Last synced by Milo: $TIMESTAMP/" "$todo_path"
    fi
done

# ============================================================================
# WRITE STATE
# ============================================================================

cat > "$STATE_FILE" << EOF
{
    "last_sync": "$TIMESTAMP",
    "files_processed": $FILES_PROCESSED,
    "new_tasks": $TOTAL_NEW,
    "updated": $TOTAL_UPDATED,
    "skipped": $TOTAL_SKIPPED,
    "ids_assigned": $TOTAL_IDS_ASSIGNED,
    "reverse_synced": $REVERSE_SYNCED
}
EOF

log "=== TODO sync complete ==="
