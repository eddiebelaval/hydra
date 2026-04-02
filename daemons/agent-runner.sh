#!/bin/bash
# agent-runner.sh - HYDRA Agent Task Processor
# Runs on heartbeat schedule for each agent
# Usage: agent-runner.sh <agent-id>
#
# This script:
# 1. Checks agent's notification queue
# 2. Processes simple tasks automatically
# 3. Queues complex tasks for human review
# 4. Generates agent reports
# 5. Notifies Eddie of important items

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

AGENT_ID="${1:-}"
if [[ -z "$AGENT_ID" ]]; then
    echo "Usage: agent-runner.sh <agent-id>"
    echo "Available agents: milo, forge, scout, pulse"
    exit 1
fi

HYDRA_DB="$HOME/.hydra/hydra.db"
HYDRA_BASE="$HOME/.hydra"
LOGS_BASE="$HOME/Library/Logs/claude-automation"
AGENT_LOGS="$LOGS_BASE/hydra-agents/$AGENT_ID"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
LOG_FILE="$AGENT_LOGS/heartbeat-$DATE.log"
REPORT_DIR="$HYDRA_BASE/reports/$AGENT_ID"

# Create directories
mkdir -p "$AGENT_LOGS" "$REPORT_DIR"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_ID] $1" | tee -a "$LOG_FILE"
}

log_activity() {
    local activity_type="$1"
    local description="$2"
    local activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, description, created_at)
        VALUES ('$activity_id', '$AGENT_ID', '$activity_type', '$(echo "$description" | sed "s/'/''/g")', datetime('now'));
    " 2>/dev/null || true
}

# ============================================================================
# AGENT INFO
# ============================================================================

log "========================================"
log "HYDRA Agent Heartbeat: $AGENT_ID"
log "========================================"

# Get agent details
AGENT_INFO=$(sqlite3 "$HYDRA_DB" "SELECT name, role, heartbeat_minutes FROM agents WHERE id = '$AGENT_ID';" 2>/dev/null)
if [[ -z "$AGENT_INFO" ]]; then
    log "ERROR: Agent '$AGENT_ID' not found in database"
    exit 1
fi

AGENT_NAME=$(echo "$AGENT_INFO" | cut -d'|' -f1)
AGENT_ROLE=$(echo "$AGENT_INFO" | cut -d'|' -f2)
HEARTBEAT_MIN=$(echo "$AGENT_INFO" | cut -d'|' -f3)

log "Agent: $AGENT_NAME ($AGENT_ROLE)"
log "Heartbeat: every ${HEARTBEAT_MIN} minutes"

# Update last_heartbeat_at
sqlite3 "$HYDRA_DB" "UPDATE agents SET last_heartbeat_at = datetime('now') WHERE id = '$AGENT_ID';" 2>/dev/null

# ============================================================================
# CHECK RUNTIME ENGINE WORK
# ============================================================================

log "Checking runtime engine..."

RT_RESULT=$(/usr/bin/python3 "$HOME/.hydra/runtime/claim_and_execute.py" "$AGENT_ID" 2>&1)
RT_EXIT=$?

if [[ $RT_EXIT -eq 0 && -n "$RT_RESULT" ]]; then
    log "Runtime engine: $RT_RESULT"
    log_activity "rt_job_executed" "$RT_RESULT"
elif [[ $RT_EXIT -eq 2 ]]; then
    log "Runtime engine: no pending work"
else
    log "Runtime engine error (exit=$RT_EXIT): $RT_RESULT"
fi

# ============================================================================
# CHECK NOTIFICATIONS
# ============================================================================

log "Checking notification queue..."

# Get urgent notifications first
URGENT_NOTIFS=$(sqlite3 "$HYDRA_DB" "
    SELECT n.id, n.notification_type, n.source_type, n.source_id,
           COALESCE(m.content, t.title, 'No preview') as preview
    FROM notifications n
    LEFT JOIN messages m ON n.source_type = 'message' AND n.source_id = m.id
    LEFT JOIN tasks t ON n.source_type = 'task' AND n.source_id = t.id
    WHERE n.target_agent = '$AGENT_ID'
    AND n.delivered = 0
    AND n.priority = 'urgent'
    ORDER BY n.created_at ASC;
" 2>/dev/null || echo "")

URGENT_COUNT=0
if [[ -n "$URGENT_NOTIFS" ]]; then
    URGENT_COUNT=$(echo "$URGENT_NOTIFS" | wc -l | tr -d ' ')
fi

# Get normal notifications
NORMAL_NOTIFS=$(sqlite3 "$HYDRA_DB" "
    SELECT n.id, n.notification_type, n.source_type, n.source_id,
           COALESCE(m.content, t.title, 'No preview') as preview
    FROM notifications n
    LEFT JOIN messages m ON n.source_type = 'message' AND n.source_id = m.id
    LEFT JOIN tasks t ON n.source_type = 'task' AND n.source_id = t.id
    WHERE n.target_agent = '$AGENT_ID'
    AND n.delivered = 0
    AND n.priority != 'urgent'
    ORDER BY n.created_at ASC;
" 2>/dev/null || echo "")

NORMAL_COUNT=0
if [[ -n "$NORMAL_NOTIFS" ]]; then
    NORMAL_COUNT=$(echo "$NORMAL_NOTIFS" | wc -l | tr -d ' ')
fi

TOTAL_NOTIFS=$((URGENT_COUNT + NORMAL_COUNT))
log "Notifications: $TOTAL_NOTIFS total ($URGENT_COUNT urgent, $NORMAL_COUNT normal)"

# ============================================================================
# CHECK TASKS
# ============================================================================

log "Checking task queue..."

PENDING_TASKS=$(sqlite3 "$HYDRA_DB" "
    SELECT id, title, priority, task_type
    FROM tasks
    WHERE assigned_to = '$AGENT_ID'
    AND status = 'pending'
    ORDER BY priority ASC, created_at ASC;
" 2>/dev/null || echo "")

PENDING_COUNT=0
if [[ -n "$PENDING_TASKS" ]]; then
    PENDING_COUNT=$(echo "$PENDING_TASKS" | wc -l | tr -d ' ')
fi

IN_PROGRESS=$(sqlite3 "$HYDRA_DB" "
    SELECT id, title, priority
    FROM tasks
    WHERE assigned_to = '$AGENT_ID'
    AND status = 'in_progress'
    ORDER BY priority ASC;
" 2>/dev/null || echo "")

IN_PROGRESS_COUNT=0
if [[ -n "$IN_PROGRESS" ]]; then
    IN_PROGRESS_COUNT=$(echo "$IN_PROGRESS" | wc -l | tr -d ' ')
fi

log "Tasks: $PENDING_COUNT pending, $IN_PROGRESS_COUNT in progress"

# ============================================================================
# GENERATE HEARTBEAT REPORT
# ============================================================================

REPORT_FILE="$REPORT_DIR/heartbeat-$DATE-$TIME.md"

cat > "$REPORT_FILE" << EOF
# $AGENT_NAME Heartbeat Report
**Time:** $DATE $TIME
**Role:** $AGENT_ROLE

---

## Queue Summary
- **Urgent Notifications:** $URGENT_COUNT
- **Normal Notifications:** $NORMAL_COUNT
- **Pending Tasks:** $PENDING_COUNT
- **In Progress:** $IN_PROGRESS_COUNT

---

## Urgent Items
$(if [[ -n "$URGENT_NOTIFS" ]]; then
    echo "$URGENT_NOTIFS" | while IFS='|' read -r id type source_type source_id preview; do
        echo "- [$type] $preview"
    done
else
    echo "- (none)"
fi)

---

## Pending Tasks
$(if [[ -n "$PENDING_TASKS" ]]; then
    echo "$PENDING_TASKS" | while IFS='|' read -r id title priority task_type; do
        echo "- [P$priority] $title"
    done
else
    echo "- (none)"
fi)

---

## In Progress
$(if [[ -n "$IN_PROGRESS" ]]; then
    echo "$IN_PROGRESS" | while IFS='|' read -r id title priority; do
        echo "- $title"
    done
else
    echo "- (none)"
fi)

---

## Recommended Actions
$(if [[ $URGENT_COUNT -gt 0 ]]; then
    echo "1. **URGENT:** Process $URGENT_COUNT urgent notification(s) immediately"
fi)
$(if [[ $IN_PROGRESS_COUNT -gt 0 ]]; then
    echo "2. Continue work on $IN_PROGRESS_COUNT in-progress task(s)"
fi)
$(if [[ $PENDING_COUNT -gt 0 ]] && [[ $IN_PROGRESS_COUNT -eq 0 ]]; then
    echo "3. Pick up next pending task from queue"
fi)
$(if [[ $TOTAL_NOTIFS -eq 0 ]] && [[ $PENDING_COUNT -eq 0 ]] && [[ $IN_PROGRESS_COUNT -eq 0 ]]; then
    echo "- Queue is clear. Check for proactive opportunities."
fi)

---
*Generated by HYDRA Agent Runner*
EOF

log "Report saved: $REPORT_FILE"

# ============================================================================
# NOTIFY EDDIE (if urgent or significant)
# ============================================================================

NEEDS_ATTENTION=false
ATTENTION_MSG=""

if [[ $URGENT_COUNT -gt 0 ]]; then
    NEEDS_ATTENTION=true
    ATTENTION_MSG="$AGENT_NAME has $URGENT_COUNT URGENT items"
fi

if [[ "$AGENT_ID" == "milo" ]] && [[ $TOTAL_NOTIFS -gt 5 ]]; then
    NEEDS_ATTENTION=true
    ATTENTION_MSG="MILO queue backing up: $TOTAL_NOTIFS notifications"
fi

if [[ "$NEEDS_ATTENTION" == "true" ]]; then
    log "Notifying Eddie: $ATTENTION_MSG"

    # Use the centralized notification dispatcher
    NOTIFY_SCRIPT="$HYDRA_BASE/daemons/notify-eddie.sh"
    if [[ -x "$NOTIFY_SCRIPT" ]]; then
        # Only urgent items open MacDown - normal heartbeats stay quiet
        if [[ $URGENT_COUNT -gt 0 ]]; then
            "$NOTIFY_SCRIPT" urgent "HYDRA: $AGENT_NAME" "$ATTENTION_MSG" "$REPORT_FILE" 2>/dev/null || true
        else
            # Normal priority = macOS notification only (no MacDown spam)
            "$NOTIFY_SCRIPT" normal "HYDRA: $AGENT_NAME" "$ATTENTION_MSG" 2>/dev/null || true
        fi
        log "Notification dispatched via notify-eddie.sh"
    else
        # Fallback to direct terminal-notifier
        if command -v terminal-notifier &> /dev/null; then
            terminal-notifier \
                -title "HYDRA: $AGENT_NAME" \
                -message "$ATTENTION_MSG" \
                -sound default \
                -open "file://$REPORT_FILE" 2>/dev/null || true
        fi
    fi
fi

# ============================================================================
# MARK NOTIFICATIONS AS DELIVERED
# ============================================================================

# Mark all notifications for this agent as delivered so they don't spam on next heartbeat
if [[ $TOTAL_NOTIFS -gt 0 ]]; then
    sqlite3 "$HYDRA_DB" "
        UPDATE notifications
        SET delivered = 1, delivered_at = datetime('now')
        WHERE target_agent = '$AGENT_ID' AND delivered = 0;
    " 2>/dev/null || true
    log "Marked $TOTAL_NOTIFS notifications as delivered"
fi

log_activity "heartbeat" "Processed $TOTAL_NOTIFS notifications, $PENDING_COUNT pending tasks"

# ============================================================================
# SUMMARY
# ============================================================================

log "========================================"
log "Heartbeat Complete"
log "Next heartbeat in $HEARTBEAT_MIN minutes"
log "========================================"

# Return status for launchd
if [[ $URGENT_COUNT -gt 0 ]]; then
    echo "HYDRA $AGENT_NAME: $URGENT_COUNT URGENT | $NORMAL_COUNT normal | $PENDING_COUNT tasks"
    exit 0  # Still success, but with urgent items
else
    echo "HYDRA $AGENT_NAME: $TOTAL_NOTIFS notifications | $PENDING_COUNT tasks"
    exit 0
fi
