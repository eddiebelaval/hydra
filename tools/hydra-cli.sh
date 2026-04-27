#!/bin/bash
# hydra-cli.sh - HYDRA Multi-Agent System CLI
#
# Usage:
#   hydra status              - Show system status
#   hydra agents              - List all agents
#   hydra tasks [agent]       - List tasks (optionally filter by agent)
#   hydra task create         - Create a new task
#   hydra notify @agent msg   - Send notification to agent
#   hydra standup             - Generate daily standup
#   hydra route "message"     - Route a message with @mentions

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
HYDRA_TOOLS="$HOME/.hydra/tools"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Check database exists
check_db() {
    if [[ ! -f "$HYDRA_DB" ]]; then
        echo -e "${RED}Error: HYDRA database not found at $HYDRA_DB${NC}"
        echo "Run: sqlite3 ~/.hydra/hydra.db < ~/.hydra/init-db.sql"
        exit 1
    fi
}

# Show help
show_help() {
    echo -e "${BOLD}HYDRA Multi-Agent System CLI${NC}"
    echo ""
    echo "Usage: hydra <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status              Show system status and agent workload"
    echo "  agents              List all registered agents"
    echo "  tasks [agent]       List tasks (optionally filter by agent)"
    echo "  task create         Interactive task creation"
    echo "  task complete <id>  Mark task as completed"
    echo "  notify @agent msg   Send notification to specific agent"
    echo "  route \"message\"     Route a message (parse @mentions)"
    echo "  standup             Generate daily standup report"
    echo "  notifications       Show pending notifications"
    echo "  activity [n]        Show recent activity (default: 10)"
    echo "  telegram <cmd>      Telegram control (setup/test/start/stop/status)"
    echo "  briefing            Generate and open morning briefing"
    echo ""
    echo "Examples:"
    echo "  hydra status"
    echo "  hydra tasks forge"
    echo "  hydra notify @milo \"Review the PR please\""
    echo "  hydra route \"Hey @forge can you fix the auth bug?\""
}

# Show system status
cmd_status() {
    check_db
    echo -e "${BOLD}${CYAN}HYDRA System Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo -e "${BOLD}Agent Workload:${NC}"
    sqlite3 -header -column "$HYDRA_DB" "
        SELECT
            agent_name as Agent,
            agent_status as Status,
            pending_tasks as Pending,
            in_progress_tasks as 'In Progress',
            blocked_tasks as Blocked,
            completed_today as 'Done Today'
        FROM v_agent_workload;
    "
    echo ""

    echo -e "${BOLD}Task Summary:${NC}"
    sqlite3 "$HYDRA_DB" "
        SELECT
            'Total: ' || COUNT(*) ||
            ' | Pending: ' || SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) ||
            ' | In Progress: ' || SUM(CASE WHEN status='in_progress' THEN 1 ELSE 0 END) ||
            ' | Completed: ' || SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END)
        FROM tasks;
    "
    echo ""

    echo -e "${BOLD}Pending Notifications:${NC}"
    NOTIF_COUNT=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM notifications WHERE delivered = 0;")
    if [[ "$NOTIF_COUNT" -gt 0 ]]; then
        echo -e "${YELLOW}$NOTIF_COUNT undelivered notifications${NC}"
        sqlite3 "$HYDRA_DB" "
            SELECT target_agent || ': ' || content_preview
            FROM notifications WHERE delivered = 0 ORDER BY priority, created_at LIMIT 5;
        " | while read line; do echo "  - $line"; done
    else
        echo -e "${GREEN}All notifications delivered${NC}"
    fi
    echo ""

    echo -e "${BOLD}Launchd Jobs:${NC}"
    launchctl list 2>/dev/null | grep -E "hydra|id8labs" | head -5 || echo "  (none running)"
}

# List agents
cmd_agents() {
    check_db
    echo -e "${BOLD}${CYAN}HYDRA Agents${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sqlite3 -header -column "$HYDRA_DB" "
        SELECT
            id as ID,
            name as Name,
            role as Role,
            model as Model,
            heartbeat_minutes || 'min' as Heartbeat,
            cost_tier as Cost,
            status as Status
        FROM agents;
    "
}

# List tasks
cmd_tasks() {
    check_db
    local agent="${1:-}"

    echo -e "${BOLD}${CYAN}HYDRA Tasks${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local where_clause=""
    if [[ -n "$agent" ]]; then
        where_clause="WHERE assigned_to = '$agent'"
        echo -e "Filtered by: ${YELLOW}@$agent${NC}"
    fi

    sqlite3 -header -column "$HYDRA_DB" "
        SELECT
            substr(id, 1, 8) as ID,
            substr(title, 1, 40) as Title,
            COALESCE(assigned_to, 'unassigned') as Agent,
            priority as Pri,
            status as Status
        FROM tasks
        $where_clause
        ORDER BY
            CASE status WHEN 'in_progress' THEN 0 WHEN 'pending' THEN 1 WHEN 'blocked' THEN 2 ELSE 3 END,
            priority,
            created_at DESC
        LIMIT 20;
    "
}

# Create task
cmd_task_create() {
    check_db
    echo -e "${BOLD}${CYAN}Create New Task${NC}"
    echo ""

    read -p "Title: " title
    read -p "Description: " description
    read -p "Type (dev/research/ops/marketing/general): " task_type
    read -p "Priority (1=critical, 2=high, 3=normal, 4=low) [3]: " priority
    priority=${priority:-3}
    read -p "Assign to (milo/forge/scout/pulse) [auto]: " assigned_to
    read -p "TTL in hours (24=daily, 168=weekly, blank=no expiry) []: " ttl_hours
    ttl_hours=${ttl_hours:-NULL}

    # Auto-assign based on type
    if [[ -z "$assigned_to" ]]; then
        case "$task_type" in
            dev|code|bug|feature) assigned_to="forge" ;;
            research|marketing|seo|content) assigned_to="scout" ;;
            ops|devops|security|infra) assigned_to="pulse" ;;
            *) assigned_to="milo" ;;
        esac
        echo -e "Auto-assigned to: ${YELLOW}@$assigned_to${NC}"
    fi

    # Escape for SQL
    safe_title=$(echo "$title" | sed "s/'/''/g")
    safe_desc=$(echo "$description" | sed "s/'/''/g")

    # Generate IDs
    task_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    notif_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Insert task
    sqlite3 "$HYDRA_DB" "
        INSERT INTO tasks (id, title, description, source, assigned_to, created_by, priority, task_type, ttl_hours)
        VALUES ('$task_id', '$safe_title', '$safe_desc', 'user', '$assigned_to', 'user', $priority, '$task_type', $ttl_hours);
    "

    # Create notification
    sqlite3 "$HYDRA_DB" "
        INSERT INTO notifications (id, target_agent, notification_type, source_type, source_id, priority, content_preview)
        VALUES ('$notif_id', '$assigned_to', 'task_assigned', 'task', '$task_id',
                CASE WHEN $priority <= 2 THEN 'urgent' ELSE 'normal' END,
                'New task: $safe_title');
    "

    # Log activity
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
        VALUES ('$activity_id', NULL, 'task_created', 'task', '$task_id', 'User created task: $safe_title');
    "

    echo ""
    echo -e "${GREEN}Task created!${NC}"
    echo "  ID: ${task_id:0:8}..."
    echo "  Assigned to: @$assigned_to"
    echo "  Notification queued"
}

# Complete task
cmd_task_complete() {
    check_db
    local task_id="$1"

    if [[ -z "$task_id" ]]; then
        echo "Usage: hydra task complete <task-id>"
        exit 1
    fi

    # Find task by partial ID
    full_id=$(sqlite3 "$HYDRA_DB" "SELECT id FROM tasks WHERE id LIKE '$task_id%' LIMIT 1;")

    if [[ -z "$full_id" ]]; then
        echo -e "${RED}Task not found: $task_id${NC}"
        exit 1
    fi

    sqlite3 "$HYDRA_DB" "
        UPDATE tasks SET status = 'completed', completed_at = datetime('now')
        WHERE id = '$full_id';
    "

    echo -e "${GREEN}Task completed: ${full_id:0:8}...${NC}"
}

# Send notification
cmd_notify() {
    check_db
    local target="$1"
    shift
    local message="$*"

    # Parse @agent format
    target=$(echo "$target" | sed 's/^@//')

    if [[ ! "$target" =~ ^(milo|forge|scout|pulse|all)$ ]]; then
        echo -e "${RED}Invalid agent: @$target${NC}"
        echo "Valid agents: @milo, @forge, @scout, @pulse, @all"
        exit 1
    fi

    if [[ -z "$message" ]]; then
        echo "Usage: hydra notify @agent \"message\""
        exit 1
    fi

    local agents="$target"
    if [[ "$target" == "all" ]]; then
        agents="milo forge scout pulse"
    fi

    safe_message=$(echo "$message" | sed "s/'/''/g")

    for agent in $agents; do
        notif_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
        sqlite3 "$HYDRA_DB" "
            INSERT INTO notifications (id, target_agent, notification_type, source_type, source_id, priority, content_preview)
            VALUES ('$notif_id', '$agent', 'mention', 'manual', '$notif_id', 'normal', '$safe_message');
        "
        echo -e "${GREEN}Notification sent to @$agent${NC}"
    done
}

# Route message with @mentions
cmd_route() {
    check_db
    local message="$*"

    if [[ -z "$message" ]]; then
        echo "Usage: hydra route \"Hey @forge fix the bug\""
        exit 1
    fi

    "$HYDRA_TOOLS/hydra-route-message.sh" --channel cli --sender user --content "$message"
}

# Generate standup
cmd_standup() {
    check_db
    local date=$(date +%Y-%m-%d)

    echo -e "${BOLD}${CYAN}HYDRA Daily Standup - $date${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo -e "${GREEN}Completed Today:${NC}"
    sqlite3 "$HYDRA_DB" "
        SELECT '  - [' || COALESCE(assigned_to, '?') || '] ' || title
        FROM tasks
        WHERE status = 'completed' AND date(completed_at) = date('now')
        LIMIT 10;
    " || echo "  (none)"
    echo ""

    echo -e "${YELLOW}In Progress:${NC}"
    sqlite3 "$HYDRA_DB" "
        SELECT '  - [' || COALESCE(assigned_to, '?') || '] ' || title
        FROM tasks
        WHERE status = 'in_progress'
        LIMIT 10;
    " || echo "  (none)"
    echo ""

    echo -e "${RED}Blocked:${NC}"
    sqlite3 "$HYDRA_DB" "
        SELECT '  - [' || COALESCE(assigned_to, '?') || '] ' || title || ' (' || COALESCE(blocked_reason, 'no reason') || ')'
        FROM tasks
        WHERE status = 'blocked'
        LIMIT 10;
    " || echo "  (none)"
    echo ""

    echo -e "${BLUE}Recent Activity:${NC}"
    sqlite3 "$HYDRA_DB" "
        SELECT '  - ' || COALESCE(agent_id, 'system') || ': ' || description
        FROM activities
        WHERE date(created_at) = date('now')
        ORDER BY created_at DESC
        LIMIT 5;
    " || echo "  (none)"
}

# Show notifications
cmd_notifications() {
    check_db
    echo -e "${BOLD}${CYAN}Pending Notifications${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sqlite3 -header -column "$HYDRA_DB" "
        SELECT
            substr(id, 1, 8) as ID,
            target_agent as Agent,
            notification_type as Type,
            priority as Priority,
            substr(content_preview, 1, 30) as Preview
        FROM notifications
        WHERE delivered = 0
        ORDER BY
            CASE priority WHEN 'urgent' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
            created_at;
    "
}

# Show activity
cmd_activity() {
    check_db
    local limit="${1:-10}"

    echo -e "${BOLD}${CYAN}Recent Activity${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    sqlite3 -header -column "$HYDRA_DB" "
        SELECT
            substr(created_at, 12, 5) as Time,
            COALESCE(agent_id, 'system') as Agent,
            activity_type as Type,
            substr(description, 1, 40) as Description
        FROM activities
        ORDER BY created_at DESC
        LIMIT $limit;
    "
}

# Telegram setup/test/listen
cmd_telegram() {
    local action="${1:-setup}"

    case "$action" in
        setup)
            "$HOME/.hydra/tools/telegram-setup.sh"
            ;;
        test)
            echo "Sending test notification..."
            "$HOME/.hydra/daemons/notify-eddie.sh" urgent "HYDRA Test" "This is a test notification from hydra telegram test"
            ;;
        listen)
            echo -e "${CYAN}Starting Telegram listener in foreground...${NC}"
            echo "Press Ctrl+C to stop"
            echo ""
            "$HOME/.hydra/daemons/telegram-listener.sh"
            ;;
        start)
            echo "Starting Telegram listener daemon..."
            launchctl load ~/Library/LaunchAgents/com.hydra.telegram-listener.plist 2>/dev/null || true
            launchctl start com.hydra.telegram-listener 2>/dev/null || true
            sleep 1
            if launchctl list | grep -q "com.hydra.telegram-listener"; then
                echo -e "${GREEN}Telegram listener started${NC}"
            else
                echo -e "${RED}Failed to start listener. Check logs at:${NC}"
                echo "  ~/Library/Logs/claude-automation/hydra-telegram/"
            fi
            ;;
        stop)
            echo "Stopping Telegram listener daemon..."
            launchctl stop com.hydra.telegram-listener 2>/dev/null || true
            launchctl unload ~/Library/LaunchAgents/com.hydra.telegram-listener.plist 2>/dev/null || true
            echo -e "${GREEN}Telegram listener stopped${NC}"
            ;;
        status)
            echo -e "${BOLD}Telegram Listener Status${NC}"
            if launchctl list 2>/dev/null | grep -q "com.hydra.telegram-listener"; then
                echo -e "${GREEN}Running${NC}"
                local offset=$(cat ~/.hydra/state/telegram-offset.txt 2>/dev/null || echo "0")
                echo "  Offset: $offset"
                echo "  Logs: ~/Library/Logs/claude-automation/hydra-telegram/"
            else
                echo -e "${YELLOW}Not running${NC}"
                echo "  Start with: hydra telegram start"
            fi
            ;;
        *)
            echo "Usage: hydra telegram <command>"
            echo ""
            echo "Commands:"
            echo "  setup   - Configure Telegram bot credentials"
            echo "  test    - Send test notification"
            echo "  listen  - Run listener in foreground (for testing)"
            echo "  start   - Start listener daemon (background)"
            echo "  stop    - Stop listener daemon"
            echo "  status  - Check listener status"
            ;;
    esac
}

# Generate and open briefing
cmd_briefing() {
    echo "Generating morning briefing..."
    "$HOME/.hydra/daemons/daily-briefing.sh"
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-help}" in
    status)
        cmd_status
        ;;
    agents)
        cmd_agents
        ;;
    tasks)
        cmd_tasks "${2:-}"
        ;;
    task)
        case "${2:-}" in
            create)
                cmd_task_create
                ;;
            complete)
                cmd_task_complete "${3:-}"
                ;;
            *)
                echo "Usage: hydra task <create|complete>"
                ;;
        esac
        ;;
    notify)
        cmd_notify "${2:-}" "${@:3}"
        ;;
    route)
        cmd_route "${@:2}"
        ;;
    standup)
        cmd_standup
        ;;
    notifications)
        cmd_notifications
        ;;
    activity)
        cmd_activity "${2:-10}"
        ;;
    telegram)
        cmd_telegram "${2:-setup}"
        ;;
    briefing)
        cmd_briefing
        ;;
    rt)
        shift
        /usr/bin/python3 "$HOME/.hydra/runtime/rt_cli.py" "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
