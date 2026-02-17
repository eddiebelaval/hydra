#!/bin/bash
# goals-updater.sh - HYDRA Goals Auto-Updater
#
# Runs daily at 6:05 AM via launchd (after brain-updater at 6:00 AM).
# Updates bounded sections in GOALS.md with data from SQLite:
#   - Monthly Focus: from monthly_commitments table
#   - Project Health: from brain-updater activity + observer reflections
#   - Priority History: from daily_priorities table (last 7 days)
#
# Pure bash + SQLite -- no AI calls, $0/month.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
GOALS_FILE="$HYDRA_ROOT/GOALS.md"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-goals-updater"
LOG_FILE="$LOG_DIR/goals-updater.log"
DATE=$(date +%Y-%m-%d)
MONTH=$(date +"%B %Y")

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Goals updater started ==="

# Verify GOALS.md exists
if [[ ! -f "$GOALS_FILE" ]]; then
    log "ERROR: GOALS.md not found at $GOALS_FILE"
    exit 1
fi

# ============================================================================
# GATHER DATA
# ============================================================================

# Monthly commitments
MONTHLY_FOCUS=$(sqlite3 "$HYDRA_DB" "
    SELECT '- **' || month || ':** ' || commitment
    FROM monthly_commitments
    ORDER BY month DESC
    LIMIT 5;
" 2>/dev/null || echo "")

if [[ -z "$MONTHLY_FOCUS" ]]; then
    MONTHLY_FOCUS="*No monthly commitments recorded yet.*"
fi

# Recent reflections (from observer/reflector pipeline)
RECENT_REFLECTIONS=$(sqlite3 "$HYDRA_DB" "
    SELECT '- ' || pattern
    FROM reflections
    WHERE period_end >= date('now', '-14 days')
    ORDER BY created_at DESC
    LIMIT 5;
" 2>/dev/null || echo "")

# Project activity summary (from brain-updater bounded section)
BRAIN_FILE="$HYDRA_ROOT/TECHNICAL_BRAIN.md"
PROJECT_HEALTH=""
if [[ -f "$BRAIN_FILE" ]]; then
    PROJECT_HEALTH=$(sed -n '/<!-- BRAIN-UPDATER:START -->/,/<!-- BRAIN-UPDATER:END -->/{
        /<!-- BRAIN-UPDATER/d
        /^## Recent Git Activity/d
        /^\*Auto-updated/d
        p
    }' "$BRAIN_FILE" 2>/dev/null | sed '1{/^$/d;}' || echo "")
fi

if [[ -z "$PROJECT_HEALTH" ]]; then
    PROJECT_HEALTH="*No recent project activity detected.*"
fi

# Combine health section
HEALTH_CONTENT="### Project Activity
$PROJECT_HEALTH"

if [[ -n "$RECENT_REFLECTIONS" ]]; then
    HEALTH_CONTENT="$HEALTH_CONTENT

### Recent Patterns (from Reflector)
$RECENT_REFLECTIONS"
fi

HEALTH_CONTENT="$HEALTH_CONTENT

*Auto-updated $DATE at $(date '+%H:%M')*"

# Priority history (last 7 days)
PRIORITY_HISTORY=$(sqlite3 "$HYDRA_DB" "
    SELECT date || ': ' ||
        GROUP_CONCAT(priority_number || '. ' || description || ' [' || status || ']', '  |  ')
    FROM daily_priorities
    WHERE date >= date('now', '-7 days')
    GROUP BY date
    ORDER BY date DESC;
" 2>/dev/null || echo "")

if [[ -z "$PRIORITY_HISTORY" ]]; then
    PRIORITY_HISTORY="*No priorities recorded in the last 7 days.*"
else
    # Format as a list
    PRIORITY_HISTORY=$(echo "$PRIORITY_HISTORY" | while read -r line; do
        echo "- $line"
    done)
fi

PRIORITY_CONTENT="$PRIORITY_HISTORY

*Auto-updated $DATE at $(date '+%H:%M')*"

# ============================================================================
# UPDATE BOUNDED SECTIONS
# ============================================================================

# Monthly Focus section
MONTHLY_CONTENT="$MONTHLY_FOCUS

*Auto-updated $DATE at $(date '+%H:%M')*"

update_bounded_section() {
    local file="$1"
    local start_marker="$2"
    local end_marker="$3"
    local new_content="$4"

    # Create temp file
    local tmp_file=$(mktemp)

    # Use Python for reliable multi-line bounded replacement
    python3 << PYEOF
import sys

start = "$start_marker"
end = "$end_marker"

with open("$file", "r") as f:
    lines = f.readlines()

new_lines = []
inside = False
replaced = False
for line in lines:
    if start in line:
        new_lines.append(line)
        inside = True
        replaced = True
        # Insert new content
        new_content = """$new_content"""
        new_lines.append(new_content + "\n")
        continue
    if end in line:
        inside = False
        new_lines.append(line)
        continue
    if not inside:
        new_lines.append(line)

if not replaced:
    # Markers not found -- append at end
    new_lines.append("\n" + start + "\n")
    new_content = """$new_content"""
    new_lines.append(new_content + "\n")
    new_lines.append(end + "\n")

with open("$tmp_file", "w") as f:
    f.writelines(new_lines)
PYEOF

    # Replace original file
    mv "$tmp_file" "$file"
}

# Update each section
update_bounded_section "$GOALS_FILE" \
    "<!-- GOALS-UPDATER:START -->" \
    "<!-- GOALS-UPDATER:END -->" \
    "$MONTHLY_CONTENT"
log "Updated Monthly Focus section"

update_bounded_section "$GOALS_FILE" \
    "<!-- GOALS-UPDATER:HEALTH:START -->" \
    "<!-- GOALS-UPDATER:HEALTH:END -->" \
    "$HEALTH_CONTENT"
log "Updated Project Health section"

update_bounded_section "$GOALS_FILE" \
    "<!-- GOALS-UPDATER:PRIORITIES:START -->" \
    "<!-- GOALS-UPDATER:PRIORITIES:END -->" \
    "$PRIORITY_CONTENT"
log "Updated Priority History section"

log "=== Goals updater complete ==="
echo "Goals updated: $GOALS_FILE"
