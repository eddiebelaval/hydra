#!/bin/bash
# board-read.sh - Read messages from the HYDRA Agent Board
#
# Usage: board-read.sh [channel] [--since "2h"|"1d"|"30m"] [--agent <name>] [--limit N] [--thread <id>]
#
# With no args: shows last 20 posts across all channels (last 24h).
# With channel: filters to that channel.
# With --thread: shows a post and all its replies.
#
# Output format (human-readable):
#   [ID] CHANNEL | AGENT | MESSAGE | TAGS | TIMESTAMP
#
# For machine consumption (other scripts), use --format json.

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"

CHANNEL=""
SINCE="24h"
AGENT=""
LIMIT=20
THREAD=""
FORMAT="text"

# Parse args
if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
    CHANNEL="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)  SINCE="$2"; shift 2 ;;
        --agent)  AGENT="$2"; shift 2 ;;
        --limit)  LIMIT="$2"; shift 2 ;;
        --thread) THREAD="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        *)        shift ;;
    esac
done

# Convert --since to SQLite datetime modifier
# Supports: 30m, 2h, 1d, 7d
SINCE_MOD=""
if [[ "$SINCE" =~ ^([0-9]+)m$ ]]; then
    SINCE_MOD="-${BASH_REMATCH[1]} minutes"
elif [[ "$SINCE" =~ ^([0-9]+)h$ ]]; then
    SINCE_MOD="-${BASH_REMATCH[1]} hours"
elif [[ "$SINCE" =~ ^([0-9]+)d$ ]]; then
    SINCE_MOD="-${BASH_REMATCH[1]} days"
else
    SINCE_MOD="-24 hours"
fi

# Build query
if [[ -n "$THREAD" ]]; then
    # Thread view: parent + all replies
    QUERY="SELECT id, channel, agent, message, tags, created_at
           FROM agent_board
           WHERE id = $THREAD OR parent_id = $THREAD
           ORDER BY created_at ASC;"
else
    WHERE_CLAUSES="created_at >= datetime('now', '$SINCE_MOD')"

    if [[ -n "$CHANNEL" ]]; then
        WHERE_CLAUSES="$WHERE_CLAUSES AND channel = '$CHANNEL'"
    fi

    if [[ -n "$AGENT" ]]; then
        WHERE_CLAUSES="$WHERE_CLAUSES AND agent = '$AGENT'"
    fi

    QUERY="SELECT id, channel, agent, message, tags, created_at
           FROM agent_board
           WHERE $WHERE_CLAUSES AND parent_id IS NULL
           ORDER BY created_at DESC
           LIMIT $LIMIT;"
fi

if [[ "$FORMAT" == "json" ]]; then
    sqlite3 -json "$HYDRA_DB" "$QUERY" 2>/dev/null || echo "[]"
else
    # Human-readable output
    RESULTS=$(sqlite3 -separator '|' "$HYDRA_DB" "$QUERY" 2>/dev/null || echo "")

    if [[ -z "$RESULTS" ]]; then
        echo "No posts found."
        exit 0
    fi

    echo "$RESULTS" | while IFS='|' read -r id channel agent message tags ts; do
        TAG_DISPLAY=""
        if [[ -n "$tags" ]]; then
            TAG_DISPLAY=" [$tags]"
        fi
        # Truncate message for display
        SHORT_MSG="${message:0:120}"
        if [[ ${#message} -gt 120 ]]; then
            SHORT_MSG="${SHORT_MSG}..."
        fi
        echo "#$id  $channel | $agent | $SHORT_MSG$TAG_DISPLAY  ($ts)"
    done
fi
