#!/bin/bash
# project-staleness.sh - HYDRA Project Staleness Detector
#
# Runs weekly Sunday 5:30 AM via launchd (after git-hygiene at 4 AM, before KB lint at 6 AM).
#
# For each tracked repo (repos.sh) + auto-discovered product dirs:
#   1. Compute days since last commit
#   2. Detect Vercel deployments (.vercel dir or vercel.json)
#   3. Classify: active (<15d), stale (15-30d), dormant (>30d)
#   4. UPSERT into project_staleness table
#   5. For dormant projects with live deploys, create HYDRA tasks
#   6. Generate weekly report

set -eo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/project-staleness"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/staleness-$DATE.log"
REPORT_FILE="$LOG_DIR/report-$DATE.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Source repo list
source "$HYDRA_ROOT/config/repos.sh"

mkdir -p "$LOG_DIR"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== Project staleness scan starting ==="

# ============================================================================
# COLLECT ALL REPO PATHS (repos.sh + auto-discovered)
# ============================================================================

REPO_NAMES=()
REPO_PATHS=()

# From repos.sh
for entry in "${HYDRA_REPOS[@]}"; do
    parse_repo "$entry"
    REPO_NAMES+=("$REPO_NAME")
    REPO_PATHS+=("$REPO_PATH")
done

# Auto-discover product dirs not in repos.sh
for dir in "$HOME/Development/id8/products/"*/; do
    [[ -d "$dir/.git" ]] || continue
    dname=$(basename "$dir")
    # Skip if already tracked (case-insensitive)
    found=0
    for existing in "${REPO_NAMES[@]}"; do
        existing_lower=$(echo "$existing" | tr '[:upper:]' '[:lower:]')
        dname_lower=$(echo "$dname" | tr '[:upper:]' '[:lower:]')
        if [[ "$existing_lower" == "$dname_lower" ]]; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
        REPO_NAMES+=("$dname")
        REPO_PATHS+=("$dir")
        log "  Auto-discovered: $dname ($dir)"
    fi
done

TOTAL=${#REPO_NAMES[@]}
log "Scanning $TOTAL repositories"

# ============================================================================
# SCAN EACH REPO
# ============================================================================

ACTIVE=0
STALE=0
DORMANT=0
DORMANT_WITH_DEPLOY=0

REPORT="# Project Staleness Report -- $DATE\n\n"
REPORT+="| Project | Days Since Commit | Last Commit | Vercel? | Status |\n"
REPORT+="|---------|-------------------|-------------|---------|--------|\n"

for i in $(seq 0 $((TOTAL - 1))); do
    name="${REPO_NAMES[$i]}"
    path="${REPO_PATHS[$i]}"

    # Skip if not a git repo
    if [[ ! -d "$path/.git" ]]; then
        log "  SKIP (not git): $name ($path)"
        continue
    fi

    # Last commit date and message
    LAST_DATE=$(git -C "$path" log -1 --format=%ai 2>/dev/null | cut -d' ' -f1 || echo "")
    LAST_MSG=$(git -C "$path" log -1 --format=%s 2>/dev/null | head -c 60 || echo "")

    if [[ -z "$LAST_DATE" ]]; then
        log "  SKIP (no commits): $name"
        continue
    fi

    # Days since last commit
    DAYS=$(python3 -c "
from datetime import datetime, date
last = datetime.strptime('$LAST_DATE', '%Y-%m-%d').date()
print((date.today() - last).days)
" 2>/dev/null || echo "999")

    # Check for Vercel deployment
    HAS_VERCEL=0
    VERCEL_URL=""
    if [[ -d "$path/.vercel" ]] || [[ -f "$path/vercel.json" ]]; then
        HAS_VERCEL=1
        # Try to extract URL from .vercel/project.json
        if [[ -f "$path/.vercel/project.json" ]]; then
            VERCEL_URL=$(python3 -c "
import json
try:
    d = json.load(open('$path/.vercel/project.json'))
    org = d.get('orgId','')
    proj = d.get('projectId','')
    print(f'vercel project: {proj[:12]}...')
except: print('')
" 2>/dev/null || echo "")
        fi
    fi

    # Classify status
    if [[ "$DAYS" -le 14 ]]; then
        STATUS="active"
        ACTIVE=$((ACTIVE + 1))
    elif [[ "$DAYS" -le 30 ]]; then
        STATUS="stale"
        STALE=$((STALE + 1))
    else
        STATUS="dormant"
        DORMANT=$((DORMANT + 1))
        if [[ "$HAS_VERCEL" -eq 1 ]]; then
            DORMANT_WITH_DEPLOY=$((DORMANT_WITH_DEPLOY + 1))
        fi
    fi

    # Escape for SQL
    SAFE_NAME=$(echo "$name" | sed "s/'/''/g")
    SAFE_PATH=$(echo "$path" | sed "s/'/''/g")
    SAFE_MSG=$(echo "$LAST_MSG" | sed "s/'/''/g")
    SAFE_URL=$(echo "$VERCEL_URL" | sed "s/'/''/g")

    # UPSERT into staleness table
    sqlite3 "$HYDRA_DB" "
        INSERT INTO project_staleness (repo_name, repo_path, last_commit_date, last_commit_msg, days_since_commit, has_vercel, vercel_url, status, updated_at)
        VALUES ('$SAFE_NAME', '$SAFE_PATH', '$LAST_DATE', '$SAFE_MSG', $DAYS, $HAS_VERCEL, '$SAFE_URL', '$STATUS', datetime('now'))
        ON CONFLICT(repo_name) DO UPDATE SET
            last_commit_date = '$LAST_DATE',
            last_commit_msg = '$SAFE_MSG',
            days_since_commit = $DAYS,
            has_vercel = $HAS_VERCEL,
            vercel_url = '$SAFE_URL',
            status = CASE WHEN status = 'archived' THEN 'archived' ELSE '$STATUS' END,
            updated_at = datetime('now');
    " 2>/dev/null

    # Report row
    DEPLOY_MARK=""
    [[ "$HAS_VERCEL" -eq 1 ]] && DEPLOY_MARK="YES"
    STATUS_MARK="$STATUS"
    [[ "$STATUS" == "dormant" ]] && [[ "$HAS_VERCEL" -eq 1 ]] && STATUS_MARK="**DORMANT+DEPLOYED**"
    REPORT+="| $name | $DAYS | $LAST_MSG | $DEPLOY_MARK | $STATUS_MARK |\n"

    log "  $name: ${DAYS}d ago, vercel=$HAS_VERCEL, status=$STATUS"
done

# ============================================================================
# CREATE TASKS FOR DORMANT+DEPLOYED PROJECTS
# ============================================================================

if [[ "$DORMANT_WITH_DEPLOY" -gt 0 ]]; then
    log "Creating tasks for $DORMANT_WITH_DEPLOY dormant projects with live Vercel deploys"

    while IFS='|' read -r repo days; do
        TASK_TITLE="STALENESS: $repo has live Vercel deploy but ${days}d without commits"

        # Check if task already exists
        EXISTS=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM tasks WHERE title LIKE 'STALENESS: $repo%' AND status NOT IN ('completed','cancelled');" 2>/dev/null || echo "0")
        if [[ "$EXISTS" -gt 0 ]]; then
            log "  Task already exists for $repo"
            continue
        fi

        TASK_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
        sqlite3 "$HYDRA_DB" "
            INSERT INTO tasks (id, title, description, source, source_job, assigned_to, status, priority, task_type, ttl_hours)
            VALUES ('$TASK_ID', '$TASK_TITLE', 'Either update the project or tear down the Vercel deployment to reduce attack surface and hosting costs.', 'automation', 'project-staleness', 'milo', 'pending', 3, 'ops', 168);
        " 2>/dev/null
        log "  Created task: $TASK_TITLE"
    done < <(sqlite3 "$HYDRA_DB" "
        SELECT repo_name, days_since_commit FROM project_staleness
        WHERE status = 'dormant' AND has_vercel = 1
        ORDER BY days_since_commit DESC;
    " 2>/dev/null)
fi

# ============================================================================
# WRITE REPORT
# ============================================================================

REPORT+="\n## Summary\n\n"
REPORT+="- **Active** (<15d): $ACTIVE\n"
REPORT+="- **Stale** (15-30d): $STALE\n"
REPORT+="- **Dormant** (>30d): $DORMANT\n"
REPORT+="- **Dormant + Live Deploy**: $DORMANT_WITH_DEPLOY\n"
REPORT+="\n*Generated $TIMESTAMP*\n"

echo -e "$REPORT" > "$REPORT_FILE"
log "Report written to $REPORT_FILE"

# ============================================================================
# UPDATE TECHNICAL_BRAIN.md BOUNDED SECTION
# ============================================================================

BRAIN_FILE="$HYDRA_ROOT/TECHNICAL_BRAIN.md"
if [[ -f "$BRAIN_FILE" ]]; then
    STALENESS_SUMMARY=$(sqlite3 "$HYDRA_DB" "
        SELECT repo_name || ' (' || days_since_commit || 'd, ' || status || CASE WHEN has_vercel THEN ', deployed' ELSE '' END || ')'
        FROM project_staleness
        WHERE status != 'archived'
        ORDER BY days_since_commit DESC;
    " 2>/dev/null | sed 's/^/- /')

    SECTION="<!-- STALENESS:START -->
## Project Staleness
*Auto-updated $TIMESTAMP by project-staleness.sh*

Active: $ACTIVE | Stale: $STALE | Dormant: $DORMANT | Dormant+Deployed: $DORMANT_WITH_DEPLOY

$STALENESS_SUMMARY
<!-- STALENESS:END -->"

    python3 -c "
import sys
with open('$BRAIN_FILE', 'r') as f:
    content = f.read()
start = '<!-- STALENESS:START -->'
end = '<!-- STALENESS:END -->'
if start in content and end in content:
    si = content.index(start)
    ei = content.index(end) + len(end)
    section = '''$SECTION'''
    updated = content[:si] + section + content[ei:]
    with open('$BRAIN_FILE', 'w') as f:
        f.write(updated)
    print('TECHNICAL_BRAIN.md staleness section updated')
else:
    print('Staleness markers not found in TECHNICAL_BRAIN.md', file=sys.stderr)
" 2>&1
    log "TECHNICAL_BRAIN.md updated with staleness data"
fi

log "=== Staleness scan complete: $ACTIVE active, $STALE stale, $DORMANT dormant ==="
