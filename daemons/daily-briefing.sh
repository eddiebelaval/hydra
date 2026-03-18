#!/bin/bash
# daily-briefing.sh - HYDRA Morning Briefing Generator
# Runs: 8:40 AM daily (after sync at 8:30, standup at 8:35)
# Opens comprehensive briefing in MacDown for morning review
#
# This is your "coffee report" - everything you need to know

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_DB="$HOME/.hydra/hydra.db"
HYDRA_BASE="$HOME/.hydra"
LOGS_BASE="$HOME/Library/Logs/claude-automation"
BRIEFING_DIR="$HYDRA_BASE/briefings"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
BRIEFING_FILE="$BRIEFING_DIR/briefing-$DATE.md"

mkdir -p "$BRIEFING_DIR"

# ============================================================================
# GATHER DATA
# ============================================================================

# Agent workload
WORKLOAD=$(sqlite3 "$HYDRA_DB" "
    SELECT agent_name || ': ' || pending_tasks || 'P / ' || in_progress_tasks || 'WIP / ' || completed_today || ' done'
    FROM v_agent_workload
    ORDER BY pending_tasks + in_progress_tasks DESC;
" 2>/dev/null || echo "Unable to fetch workload")

# Urgent notifications
URGENT_ITEMS=$(sqlite3 "$HYDRA_DB" "
    SELECT a.name || ' ← ' || SUBSTR(COALESCE(m.content, t.title, n.notification_type), 1, 60)
    FROM notifications n
    LEFT JOIN agents a ON n.target_agent = a.id
    LEFT JOIN messages m ON n.source_type = 'message' AND n.source_id = m.id
    LEFT JOIN tasks t ON n.source_type = 'task' AND n.source_id = t.id
    WHERE n.delivered = 0 AND n.priority = 'urgent'
    ORDER BY n.created_at DESC
    LIMIT 10;
" 2>/dev/null || echo "")

URGENT_COUNT=0
if [[ -n "$URGENT_ITEMS" ]]; then
    URGENT_COUNT=$(echo "$URGENT_ITEMS" | wc -l | tr -d ' ')
fi

# High priority tasks
HIGH_PRIORITY_TASKS=$(sqlite3 "$HYDRA_DB" "
    SELECT COALESCE(assigned_to, 'unassigned') || ': ' || title
    FROM tasks
    WHERE status IN ('pending', 'in_progress')
    AND priority <= 2
    ORDER BY priority, created_at;
" 2>/dev/null || echo "")

# Blocked items
BLOCKED=$(sqlite3 "$HYDRA_DB" "
    SELECT COALESCE(assigned_to, 'unassigned') || ': ' || title ||
           CASE WHEN blocked_reason IS NOT NULL THEN ' (' || blocked_reason || ')' ELSE '' END
    FROM tasks
    WHERE status = 'blocked';
" 2>/dev/null || echo "")

BLOCKED_COUNT=0
if [[ -n "$BLOCKED" ]]; then
    BLOCKED_COUNT=$(echo "$BLOCKED" | wc -l | tr -d ' ')
fi

# Yesterday's completions
YESTERDAY_DONE=$(sqlite3 "$HYDRA_DB" "
    SELECT COALESCE(assigned_to, 'unassigned') || ': ' || title
    FROM tasks
    WHERE status = 'completed'
    AND date(completed_at) = date('now', '-1 day')
    ORDER BY completed_at DESC;
" 2>/dev/null || echo "")

# Total notifications pending
TOTAL_NOTIFICATIONS=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM notifications WHERE delivered = 0;" 2>/dev/null || echo "0")

# Automation signals
AUTOMATION_SIGNALS=""

# 70% Detector
SEVENTY_REPORT=$(find "$LOGS_BASE/seventy-percent-detector" -name "report-*.md" -type f 2>/dev/null | sort -r | head -1 || echo "")
if [[ -n "$SEVENTY_REPORT" ]] && [[ -f "$SEVENTY_REPORT" ]]; then
    SEVENTY_ITEMS=$(grep -c "^- " "$SEVENTY_REPORT" 2>/dev/null || echo "0")
    if [[ "$SEVENTY_ITEMS" -gt 0 ]]; then
        AUTOMATION_SIGNALS="${AUTOMATION_SIGNALS}- **70% Projects:** $SEVENTY_ITEMS items need finishing\n"
    fi
fi

# Security/Dependencies
SECURITY_REPORT=$(find "$LOGS_BASE/dependency-guardian" -name "report-*.md" -type f 2>/dev/null | sort -r | head -1 || echo "")
if [[ -n "$SECURITY_REPORT" ]] && [[ -f "$SECURITY_REPORT" ]]; then
    URGENCY=$(grep "Urgency Level" "$SECURITY_REPORT" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "")
    if [[ -n "$URGENCY" ]] && [[ "$URGENCY" != "LOW" ]]; then
        AUTOMATION_SIGNALS="${AUTOMATION_SIGNALS}- **Security:** $URGENCY priority updates needed\n"
    fi
fi

# Marketing streak
STREAK_FILE="$LOGS_BASE/marketing-check/.marketing-streak"
if [[ -f "$STREAK_FILE" ]]; then
    STREAK=$(cut -d: -f1 "$STREAK_FILE" 2>/dev/null || echo "0")
    AUTOMATION_SIGNALS="${AUTOMATION_SIGNALS}- **Marketing Streak:** $STREAK days\n"
fi

# Context switch score
CONTEXT_REPORT=$(find "$LOGS_BASE/context-switch" -name "report-*.md" -type f 2>/dev/null | sort -r | head -1 || echo "")
if [[ -n "$CONTEXT_REPORT" ]] && [[ -f "$CONTEXT_REPORT" ]]; then
    FOCUS=$(grep "Focus Score" "$CONTEXT_REPORT" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
    if [[ -n "$FOCUS" ]]; then
        AUTOMATION_SIGNALS="${AUTOMATION_SIGNALS}- **Focus Score:** $FOCUS%\n"
    fi
fi

if [[ -z "$AUTOMATION_SIGNALS" ]]; then
    AUTOMATION_SIGNALS="- All systems nominal"
fi

# Today's priorities (set by morning planner reply)
TODAYS_PRIORITIES=$(sqlite3 "$HYDRA_DB" "
    SELECT priority_number || '. ' || description
    FROM daily_priorities WHERE date = '$DATE'
    ORDER BY priority_number;
" 2>/dev/null || echo "")

# Determine priority section content
if [[ -z "$TODAYS_PRIORITIES" ]]; then
    PRIORITY_SECTION="Priorities: Awaiting your input -- reply to the 8 AM prompt"
else
    PRIORITY_SECTION="$TODAYS_PRIORITIES"
fi

# Goals excerpt (Q1 primary only)
GOALS_FILE="$HYDRA_BASE/GOALS.md"
GOALS_EXCERPT=""
if [[ -f "$GOALS_FILE" ]]; then
    GOALS_EXCERPT=$(sed -n '/### Primary/,/### Secondary/{
        /### Secondary/d
        /### Primary/d
        p
    }' "$GOALS_FILE" 2>/dev/null | sed '/^$/d' || echo "")
fi

# System health summary
HEALTH_SUMMARY=$("$HYDRA_BASE/tools/hydra-health-summary.sh" full 2>/dev/null || echo "### System Health: Unknown (heartbeat not yet run)")

# Project activity from brain-updater (runs at 6 AM, before this briefing)
BRAIN_FILE="$HYDRA_BASE/TECHNICAL_BRAIN.md"
PROJECT_ACTIVITY=""
if [[ -f "$BRAIN_FILE" ]]; then
    PROJECT_ACTIVITY=$(sed -n '/<!-- BRAIN-UPDATER:START -->/,/<!-- BRAIN-UPDATER:END -->/{
        /<!-- BRAIN-UPDATER/d
        /^## Recent Git Activity/d
        /^\*Auto-updated/d
        p
    }' "$BRAIN_FILE" 2>/dev/null || echo "")
    # Trim leading blank line (BSD sed compatible)
    PROJECT_ACTIVITY=$(echo "$PROJECT_ACTIVITY" | sed '1{/^$/d;}')
fi

# ============================================================================
# GENERATE BRIEFING
# ============================================================================

cat > "$BRIEFING_FILE" << EOF
# HYDRA Morning Briefing
## $DAY_NAME, $DATE

---

## Today's Priorities

$PRIORITY_SECTION

---

$(if [[ -n "$GOALS_EXCERPT" ]]; then
cat << GOALS_BLOCK
## Q1 Goals (Primary)

$GOALS_EXCERPT

---

GOALS_BLOCK
fi)

$(if [[ $URGENT_COUNT -gt 0 ]]; then
cat << URGENT_BLOCK
## 🚨 URGENT ($URGENT_COUNT items)

$(echo "$URGENT_ITEMS" | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

---

URGENT_BLOCK
fi)

$(if [[ -n "$PROJECT_ACTIVITY" ]]; then
cat << PROJECT_BLOCK
## Project Activity

$PROJECT_ACTIVITY

---

PROJECT_BLOCK
fi)

## Agent Status

| Agent | Workload |
|-------|----------|
$(echo "$WORKLOAD" | while read -r line; do
    agent=$(echo "$line" | cut -d: -f1)
    status=$(echo "$line" | cut -d: -f2-)
    echo "| $agent |$status |"
done)

---

$(if [[ -n "$HIGH_PRIORITY_TASKS" ]]; then
cat << HIGH_BLOCK
## High Priority Tasks

$(echo "$HIGH_PRIORITY_TASKS" | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

---

HIGH_BLOCK
fi)

$(if [[ $BLOCKED_COUNT -gt 0 ]]; then
cat << BLOCKED_BLOCK
## ⛔ Blocked ($BLOCKED_COUNT)

$(echo "$BLOCKED" | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

---

BLOCKED_BLOCK
fi)

## Automation Signals

$(echo -e "$AUTOMATION_SIGNALS")

---

## Notifications Queue

**Total Pending:** $TOTAL_NOTIFICATIONS

| Agent | Count |
|-------|-------|
$(sqlite3 "$HYDRA_DB" "
    SELECT target_agent, COUNT(*)
    FROM notifications
    WHERE delivered = 0
    GROUP BY target_agent
    ORDER BY COUNT(*) DESC;
" 2>/dev/null | while IFS='|' read -r agent count; do
    echo "| $agent | $count |"
done)

---

$(if [[ -n "$YESTERDAY_DONE" ]]; then
cat << YESTERDAY_BLOCK
## Yesterday's Wins

$(echo "$YESTERDAY_DONE" | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

---

YESTERDAY_BLOCK
fi)

$HEALTH_SUMMARY

---

## Quick Commands

\`\`\`bash
hydra status              # Refresh this view
hydra tasks               # See all tasks
hydra route "@agent msg"  # Assign work
hydra notifications       # Check notification queue
\`\`\`

---

*Generated by HYDRA at $(date '+%H:%M')*
*Briefing: ~/.hydra/briefings/briefing-$DATE.md*
EOF

echo "Briefing generated: $BRIEFING_FILE"

# ============================================================================
# OPEN IN MACDOWN
# ============================================================================

if [[ -d "/Applications/MacDown.app" ]]; then
    open -a "MacDown" "$BRIEFING_FILE"
    echo "Opened in MacDown"
else
    open "$BRIEFING_FILE"
    echo "Opened in default markdown viewer"
fi

# ============================================================================
# NOTIFY WITH FULL DETAILS
# ============================================================================

# Compose detailed Telegram message
TELEGRAM_MSG="HYDRA Briefing - $DAY_NAME

Priorities:
$PRIORITY_SECTION

"

if [[ $URGENT_COUNT -gt 0 ]]; then
    TELEGRAM_MSG+="URGENT ($URGENT_COUNT):
$(echo "$URGENT_ITEMS" | head -5 | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

"
fi

if [[ $BLOCKED_COUNT -gt 0 ]]; then
    TELEGRAM_MSG+="BLOCKED ($BLOCKED_COUNT):
$(echo "$BLOCKED" | head -3 | while read -r line; do [[ -n "$line" ]] && echo "- $line"; done)

"
fi

# Project activity (include actual bullets for Telegram)
if [[ -n "$PROJECT_ACTIVITY" ]]; then
    # Strip markdown bold markers for Telegram plaintext, keep bullets
    ACTIVITY_CLEAN=$(echo "$PROJECT_ACTIVITY" | sed 's/\*\*//g' | head -20)
    TELEGRAM_MSG+="Recent Activity:
$ACTIVITY_CLEAN

"
fi

# Agent summary
TELEGRAM_MSG+="Agents:
$(echo "$WORKLOAD" | while read -r line; do [[ -n "$line" ]] && echo "$line"; done)

"

TELEGRAM_MSG+="Notifications: $TOTAL_NOTIFICATIONS pending"

# Send with appropriate priority
if [[ $URGENT_COUNT -gt 0 ]]; then
    ~/.hydra/daemons/notify-eddie.sh urgent "HYDRA Morning Briefing" "$TELEGRAM_MSG" "$BRIEFING_FILE"
elif [[ $BLOCKED_COUNT -gt 0 ]]; then
    ~/.hydra/daemons/notify-eddie.sh high "HYDRA Morning Briefing" "$TELEGRAM_MSG" "$BRIEFING_FILE"
else
    ~/.hydra/daemons/notify-eddie.sh normal "HYDRA Morning Briefing" "$TELEGRAM_MSG" "$BRIEFING_FILE"
fi

echo "HYDRA Briefing: $URGENT_COUNT urgent | $BLOCKED_COUNT blocked | $TOTAL_NOTIFICATIONS notifications"
