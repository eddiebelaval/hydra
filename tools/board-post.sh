#!/bin/bash
# board-post.sh - Post a message to the HYDRA Agent Board
#
# Usage: board-post.sh <channel> <agent> <message> [--parent <id>] [--tags "tag1,tag2"]
#
# Channels: research, builds, health, coordination, ideas, revenue
# Agents: observer, planner, brain-updater, reflector, research-lab, ava, manual
#
# This is the AgentHub-inspired lateral coordination layer.
# Instead of all agent communication going through Eddie (hub-and-spoke),
# agents post findings and other agents read them (mesh).

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"

# Parse args
CHANNEL="${1:-}"
AGENT="${2:-}"
MESSAGE="${3:-}"
PARENT_ID=""
TAGS=""

shift 3 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent) PARENT_ID="$2"; shift 2 ;;
        --tags)   TAGS="$2"; shift 2 ;;
        *)        shift ;;
    esac
done

if [[ -z "$CHANNEL" ]] || [[ -z "$AGENT" ]] || [[ -z "$MESSAGE" ]]; then
    echo "Usage: board-post.sh <channel> <agent> <message> [--parent <id>] [--tags \"tag1,tag2\"]"
    echo ""
    echo "Channels: research, builds, health, coordination, ideas, revenue"
    exit 1
fi

# Escape single quotes for SQLite
SAFE_MSG=$(echo "$MESSAGE" | sed "s/'/''/g")
SAFE_TAGS=$(echo "$TAGS" | sed "s/'/''/g")

# Insert and return ID in a single sqlite3 call
if [[ -n "$PARENT_ID" ]]; then
    sqlite3 "$HYDRA_DB" "
        INSERT INTO agent_board (channel, agent, message, parent_id, tags)
        VALUES ('$CHANNEL', '$AGENT', '$SAFE_MSG', $PARENT_ID, '$SAFE_TAGS');
        SELECT last_insert_rowid();
    "
else
    sqlite3 "$HYDRA_DB" "
        INSERT INTO agent_board (channel, agent, message, tags)
        VALUES ('$CHANNEL', '$AGENT', '$SAFE_MSG', '$SAFE_TAGS');
        SELECT last_insert_rowid();
    "
fi
