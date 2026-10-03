#!/bin/bash
# board-post.sh - Post a message to the HYDRA Agent Board
#
# Usage: board-post.sh <channel> <agent> <message> [--parent <id>] [--tags "tag1,tag2"] [--dedupe-hours N]
#
# Channels: research, builds, health, coordination, ideas, revenue
# Agents: observer, planner, brain-updater, reflector, research-lab, ava, manual
#
# The board is a read-only LOG of agent findings (Synapse decision, 2026-10-03). Agent-to-agent
# messages that need delivery or a reply go through Synapse (`synapse send`), not here.
#
# --dedupe-hours N: skip the post when the same agent already posted a near-identical message
# (word-set Jaccard >= 0.5) on the same channel in the last N hours. Added after the observer
# reposted ~270 distinct lines 4,384 times (one "stale projects" finding every 15 minutes).
# Writes use bound parameters; channel/agent/parent are validated (v1 spliced them into SQL).

set -euo pipefail

HYDRA_DB="${HYDRA_DB:-$HOME/.hydra/hydra.db}"

CHANNEL="${1:-}"
AGENT="${2:-}"
MESSAGE="${3:-}"
PARENT_ID=""
TAGS=""
DEDUPE_HOURS="0"

shift 3 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent)       PARENT_ID="$2"; shift 2 ;;
        --tags)         TAGS="$2"; shift 2 ;;
        --dedupe-hours) DEDUPE_HOURS="$2"; shift 2 ;;
        *)              shift ;;
    esac
done

if [[ -z "$CHANNEL" ]] || [[ -z "$AGENT" ]] || [[ -z "$MESSAGE" ]]; then
    echo "Usage: board-post.sh <channel> <agent> <message> [--parent <id>] [--tags \"tag1,tag2\"] [--dedupe-hours N]"
    echo ""
    echo "Channels: research, builds, health, coordination, ideas, revenue"
    exit 1
fi
if [[ ! "$CHANNEL" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || [[ ! "$AGENT" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    echo "board-post: channel and agent must be lowercase slugs" >&2
    exit 1
fi
if [[ -n "$PARENT_ID" && ! "$PARENT_ID" =~ ^[0-9]+$ ]]; then
    echo "board-post: --parent must be a numeric post id" >&2
    exit 1
fi
if [[ ! "$DEDUPE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "board-post: --dedupe-hours must be a whole number" >&2
    exit 1
fi

python3 - "$HYDRA_DB" "$CHANNEL" "$AGENT" "$MESSAGE" "$PARENT_ID" "$TAGS" "$DEDUPE_HOURS" <<'PY'
import re, sqlite3, sys
db, channel, agent, message, parent, tags, hours = sys.argv[1:8]
con = sqlite3.connect(db, timeout=10)
words = lambda s: set(re.findall(r"[a-z0-9]+", s.lower()))
if int(hours) > 0:
    mine = words(message)
    for pid, prev in con.execute(
            "SELECT id, message FROM agent_board WHERE channel=? AND agent=? "
            "AND created_at >= datetime('now', ?) ORDER BY id DESC",
            (channel, agent, f"-{int(hours)} hours")):
        theirs = words(prev)
        if mine and theirs and len(mine & theirs) / len(mine | theirs) >= 0.5:
            print(f"skipped: near-duplicate of #{pid}")
            sys.exit(0)
cur = con.execute("INSERT INTO agent_board (channel, agent, message, parent_id, tags) VALUES (?,?,?,?,?)",
                  (channel, agent, message, int(parent) if parent else None, tags))
con.commit()
print(cur.lastrowid)
PY
