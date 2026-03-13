#!/bin/bash
# log-activity.sh — HYDRA activity logging to SQLite
#
# Inserts an activity record into the HYDRA database.
# Used by all daemons for audit trail.

# Log an activity to the HYDRA database
# Usage: log_activity "activity_type" "entity_type" "entity_id" "description"
log_activity() {
    local activity_type="$1" entity_type="$2" entity_id="$3" description="$4"
    local db="${HYDRA_DB:-$HOME/.hydra/hydra.db}"
    local id
    id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null) || id="act-$(date +%s)"
    # Escape single quotes for SQL safety
    local safe_desc="${description//\'/\'\'}"
    sqlite3 "$db" "
        INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
        VALUES ('$id', '$activity_type', '$entity_type', '$entity_id', '$safe_desc');
    " 2>/dev/null || true
}
