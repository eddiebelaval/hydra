#!/bin/bash
# parallax-monitor.sh - HYDRA Parallax Project Monitor
#
# Monitors the Parallax hackathon project: GitHub activity, deploy health,
# pipeline stage, and production uptime.
#
# Usage: parallax-monitor.sh <subcommand>
#
# Subcommands:
#   status   - Quick overview (health + last commits + pipeline stage)
#   github   - Recent commits + open PRs via gh CLI
#   deploy   - Check production URL HTTP status + response time
#   pipeline - Parse PIPELINE_STATUS.md for current stage
#   health   - Check /api/health endpoint
#   check    - Full automated check (used by launchd, sends alerts)

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SUBCMD="${1:-status}"
HYDRA_ROOT="$HOME/.hydra"
HYDRA_TOOLS="$HYDRA_ROOT/tools"
STATE_FILE="$HYDRA_ROOT/state/parallax-monitor-state.json"
PARALLAX_DIR="$HOME/Development/id8/products/parallax"
PARALLAX_URL="https://parallax-ebon-three.vercel.app"
HEALTH_URL="${PARALLAX_URL}/api/health"
REPO_OWNER="eddiebelaval"
REPO_NAME="parallax"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-parallax-monitor"
LOG_FILE="$LOG_DIR/monitor-$(date +%Y-%m-%d).log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        python3 -c "
import json
state = {
    'last_check': '',
    'last_deploy_status': 'unknown',
    'last_health_status': 'unknown',
    'last_commit_sha': '',
    'consecutive_failures': 0
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
        log "Created new state file"
    fi
}

get_state() {
    local key="$1"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
print(state.get('$key', ''))
" 2>/dev/null || echo ""
}

update_state() {
    local key="$1"
    local value="$2"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
state['$key'] = '$value'
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
}

update_state_int() {
    local key="$1"
    local value="$2"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
state['$key'] = $value
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
}

init_state

# ============================================================================
# SUBCOMMAND: health
# ============================================================================

do_health() {
    local start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    local http_code=""
    local body=""

    body=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "CURL_FAILED")

    if [[ "$body" == "CURL_FAILED" ]]; then
        echo "Health: UNREACHABLE"
        echo "URL: $HEALTH_URL"
        echo "Error: Connection failed or timed out"
        return 1
    fi

    http_code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')

    local end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    local elapsed=$((end_ms - start_ms))

    if [[ "$http_code" == "200" ]]; then
        local status=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
        local ts=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timestamp',''))" 2>/dev/null || echo "")
        echo "Health: OK"
        echo "Status: $status"
        echo "Response time: ${elapsed}ms"
        echo "Server time: $ts"
        return 0
    else
        echo "Health: DEGRADED (HTTP $http_code)"
        echo "URL: $HEALTH_URL"
        echo "Response time: ${elapsed}ms"
        return 1
    fi
}

# ============================================================================
# SUBCOMMAND: deploy
# ============================================================================

do_deploy() {
    local start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    local http_code=""

    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$PARALLAX_URL" 2>/dev/null || echo "000")

    local end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    local elapsed=$((end_ms - start_ms))

    echo "Deploy Check"
    echo "URL: $PARALLAX_URL"
    echo "HTTP Status: $http_code"
    echo "Response time: ${elapsed}ms"

    if [[ "$http_code" == "200" ]]; then
        echo "Result: LIVE"
        return 0
    elif [[ "$http_code" == "000" ]]; then
        echo "Result: UNREACHABLE"
        return 1
    else
        echo "Result: ERROR (HTTP $http_code)"
        return 1
    fi
}

# ============================================================================
# SUBCOMMAND: github
# ============================================================================

do_github() {
    if ! command -v gh &>/dev/null; then
        echo "Error: gh CLI not installed"
        return 1
    fi

    echo "GitHub Activity: $REPO_OWNER/$REPO_NAME"
    echo "---"

    # Recent commits (last 10)
    echo ""
    echo "Recent Commits:"
    if [[ -d "$PARALLAX_DIR/.git" ]]; then
        git -C "$PARALLAX_DIR" log --oneline --max-count=10 2>/dev/null || echo "  (no commits found)"
    else
        echo "  (repo not found locally)"
    fi

    # Open PRs
    echo ""
    echo "Open Pull Requests:"
    local prs=$(gh pr list --repo "$REPO_OWNER/$REPO_NAME" --state open --limit 10 2>/dev/null || echo "")
    if [[ -n "$prs" ]]; then
        echo "$prs"
    else
        echo "  None open"
    fi

    # Recent closed PRs
    echo ""
    echo "Recently Merged:"
    local merged=$(gh pr list --repo "$REPO_OWNER/$REPO_NAME" --state merged --limit 5 2>/dev/null || echo "")
    if [[ -n "$merged" ]]; then
        echo "$merged"
    else
        echo "  None recently"
    fi
}

# ============================================================================
# SUBCOMMAND: pipeline
# ============================================================================

do_pipeline() {
    local pipeline_file="$PARALLAX_DIR/PIPELINE_STATUS.md"

    if [[ ! -f "$pipeline_file" ]]; then
        echo "Pipeline: No PIPELINE_STATUS.md found"
        return 1
    fi

    echo "Pipeline Status: Parallax"
    echo "---"

    # Parse current stage, progress, and last updated
    python3 << PYEOF
import re

with open("$pipeline_file") as f:
    content = f.read()

# Extract current stage
stage_match = re.search(r'\*\*Current Stage:\*\*\s*(.+)', content)
progress_match = re.search(r'\*\*Progress:\*\*\s*(.+)', content)
updated_match = re.search(r'\*\*Last Updated:\*\*\s*(.+)', content)

if stage_match:
    print(f"Current Stage: {stage_match.group(1).strip()}")
if progress_match:
    print(f"Progress: {progress_match.group(1).strip()}")
if updated_match:
    print(f"Last Updated: {updated_match.group(1).strip()}")

# Count passed stages
passed = len(re.findall(r'PASSED', content))
print(f"Gates Passed: {passed}")

# Check for blockers
blocker_match = re.search(r'\*\*Blockers:\*\*\s*(.+)', content)
if blocker_match:
    blockers = blocker_match.group(1).strip()
    if blockers.lower() != "none identified":
        print(f"BLOCKERS: {blockers}")
PYEOF
}

# ============================================================================
# SUBCOMMAND: status (default)
# ============================================================================

do_status() {
    echo "Parallax Monitor"
    echo "================"
    echo ""

    # Health check (inline, compact)
    local health_result=""
    health_result=$(do_health 2>/dev/null) || true
    local health_line=$(echo "$health_result" | head -1)
    local response_time=$(echo "$health_result" | grep "Response time" | head -1)
    echo "$health_line${response_time:+ | $response_time}"

    # Pipeline stage (inline, compact)
    local pipeline_file="$PARALLAX_DIR/PIPELINE_STATUS.md"
    if [[ -f "$pipeline_file" ]]; then
        local stage=$(python3 -c "
import re
with open('$pipeline_file') as f:
    content = f.read()
m = re.search(r'\*\*Current Stage:\*\*\s*(.+)', content)
p = re.search(r'\*\*Progress:\*\*\s*(.+)', content)
stage = m.group(1).strip() if m else 'Unknown'
progress = p.group(1).strip() if p else ''
print(f'Pipeline: Stage {stage} ({progress})')
" 2>/dev/null || echo "Pipeline: Unknown")
        echo "$stage"
    fi

    # Last 3 commits
    echo ""
    echo "Recent Commits:"
    if [[ -d "$PARALLAX_DIR/.git" ]]; then
        git -C "$PARALLAX_DIR" log --oneline --max-count=3 2>/dev/null || echo "  (none)"
    fi

    # Branch info
    echo ""
    echo "Branch: $(git -C "$PARALLAX_DIR" branch --show-current 2>/dev/null || echo 'unknown')"

    # Uncommitted changes
    local dirty=$(git -C "$PARALLAX_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dirty" -gt 0 ]]; then
        echo "Uncommitted changes: $dirty files"
    fi
}

# ============================================================================
# SUBCOMMAND: check (automated, used by launchd)
# ============================================================================

do_check() {
    log "Running automated check"
    local issues=""
    local severity="ok"

    # 1. Health check
    local health_ok=true
    do_health >/dev/null 2>&1 || health_ok=false

    if [[ "$health_ok" == "false" ]]; then
        issues="${issues}Health check FAILED. "
        severity="high"
        local failures=$(get_state "consecutive_failures")
        failures=$((${failures:-0} + 1))
        update_state_int "consecutive_failures" "$failures"
        update_state "last_health_status" "failed"

        if [[ $failures -ge 3 ]]; then
            severity="urgent"
        fi
    else
        update_state_int "consecutive_failures" "0"
        update_state "last_health_status" "ok"
    fi

    # 2. Deploy check
    local deploy_ok=true
    local deploy_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$PARALLAX_URL" 2>/dev/null || echo "000")

    if [[ "$deploy_code" != "200" ]]; then
        deploy_ok=false
        issues="${issues}Deploy returned HTTP $deploy_code. "
        if [[ "$severity" == "ok" ]]; then
            severity="high"
        fi
        update_state "last_deploy_status" "failed"
    else
        update_state "last_deploy_status" "ok"
    fi

    # 3. Track new commits (silent)
    if [[ -d "$PARALLAX_DIR/.git" ]]; then
        local current_sha=$(git -C "$PARALLAX_DIR" rev-parse HEAD 2>/dev/null || echo "")
        local last_sha=$(get_state "last_commit_sha")
        if [[ -n "$current_sha" ]] && [[ "$current_sha" != "$last_sha" ]]; then
            local new_commits=$(git -C "$PARALLAX_DIR" log --oneline "${last_sha}..HEAD" --max-count=10 2>/dev/null | wc -l | tr -d ' ')
            log "New commits since last check: $new_commits"
            update_state "last_commit_sha" "$current_sha"
        fi
    fi

    # Update timestamp
    update_state "last_check" "$TIMESTAMP"

    # Send alerts if issues found
    if [[ -n "$issues" ]]; then
        log "Issues detected ($severity): $issues"
        "$HYDRA_ROOT/daemons/notify-eddie.sh" "$severity" "Parallax Monitor" "$issues" "" \
            --entity-type "monitor" --entity-id "parallax" 2>/dev/null || true
        echo "CHECK: ISSUES FOUND ($severity) - $issues"
    else
        log "All checks passed"
        echo "CHECK: ALL OK"
    fi
}

# ============================================================================
# DISPATCH
# ============================================================================

case "$SUBCMD" in
    status)   do_status ;;
    github)   do_github ;;
    deploy)   do_deploy ;;
    pipeline) do_pipeline ;;
    health)   do_health ;;
    check)    do_check ;;
    *)
        echo "Unknown subcommand: $SUBCMD"
        echo ""
        echo "Usage: parallax-monitor.sh <subcommand>"
        echo ""
        echo "Subcommands:"
        echo "  status   - Quick overview (default)"
        echo "  github   - Recent commits + PRs"
        echo "  deploy   - Production HTTP check"
        echo "  pipeline - ID8 Pipeline stage"
        echo "  health   - /api/health endpoint"
        echo "  check    - Full automated check (launchd)"
        exit 1
        ;;
esac
