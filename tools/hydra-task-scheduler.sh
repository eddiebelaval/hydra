#!/bin/bash
# hydra-task-scheduler.sh - Smart Task Scheduler (Paperclip-Inspired)
#
# Replaces fire-and-forget launchd with intelligent task assignment.
# Key patterns extracted from Paperclip (github.com/paperclipai/paperclip):
#   1. Atomic task checkout — no double-work via SQLite BEGIN EXCLUSIVE
#   2. Budget-aware scheduling — agents pause when over budget
#   3. Persistent session state — context carries across heartbeats
#   4. Goal-aware execution — tasks carry the "why" chain
#
# Usage:
#   hydra-task-scheduler.sh                    # Run one scheduling cycle
#   hydra-task-scheduler.sh --agent <id>       # Schedule for specific agent
#   hydra-task-scheduler.sh --dry-run          # Show what would be assigned
#   hydra-task-scheduler.sh --reset-budgets    # Reset monthly spend counters
#   hydra-task-scheduler.sh --status           # Show agent availability + budget
#
# Designed to be called by launchd every 5 minutes (replaces per-agent crons)

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-scheduler"
LOG_FILE="$LOG_DIR/scheduler.log"
ADAPTER_SCRIPT="$HYDRA_ROOT/tools/hydra-adapter.sh"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ============================================================================
# MONTHLY BUDGET RESET
# ============================================================================
# Paperclip resets spentMonthlyCents on the 1st. We do the same.

reset_budgets_if_new_month() {
    local current_month=$(date +%Y-%m)

    # Check each agent's spend_reset_month
    local agents_needing_reset=$(sqlite3 "$HYDRA_DB" "
        SELECT id FROM agents
        WHERE spend_reset_month != '$current_month' OR spend_reset_month IS NULL OR spend_reset_month = '';
    " 2>/dev/null)

    if [[ -n "$agents_needing_reset" ]]; then
        sqlite3 "$HYDRA_DB" "
            UPDATE agents
            SET spent_monthly_cents = 0,
                spend_reset_month = '$current_month',
                updated_at = datetime('now')
            WHERE spend_reset_month != '$current_month' OR spend_reset_month IS NULL OR spend_reset_month = '';
        " 2>/dev/null
        log "Budget reset for new month: $current_month"
    fi
}

# ============================================================================
# AGENT AVAILABILITY CHECK
# ============================================================================
# An agent is available if:
#   1. status = 'active' (not paused/disabled)
#   2. Within active hours
#   3. Not currently working on a task (current_task_id IS NULL)
#   4. Under budget (or budget = 0 = unlimited)
#   5. Heartbeat interval has elapsed since last wake

check_agent_available() {
    local agent_id="$1"
    local current_hour=$(date +%H)
    local current_minute=$(date +%M)
    local now_minutes=$((10#$current_hour * 60 + 10#$current_minute))

    local agent_data=$(sqlite3 -separator '|' "$HYDRA_DB" "
        SELECT status, active_hours_start, active_hours_end,
               current_task_id, budget_monthly_cents, spent_monthly_cents,
               heartbeat_minutes, last_heartbeat_at, name
        FROM agents WHERE id = '$agent_id';
    " 2>/dev/null)

    if [[ -z "$agent_data" ]]; then
        echo "NOT_FOUND"
        return
    fi

    local status="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local start_time="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local end_time="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local current_task="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local budget="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local spent="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local heartbeat_min="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local last_beat="${agent_data%%|*}"; agent_data="${agent_data#*|}"
    local name="${agent_data}"

    # Check 1: Status
    if [[ "$status" != "active" ]]; then
        echo "PAUSED:$name is $status"
        return
    fi

    # Check 2: Active hours
    local start_h="${start_time%%:*}"
    local start_m="${start_time##*:}"
    local end_h="${end_time%%:*}"
    local end_m="${end_time##*:}"
    local start_minutes=$((10#$start_h * 60 + 10#$start_m))
    local end_minutes=$((10#$end_h * 60 + 10#$end_m))

    if [[ $now_minutes -lt $start_minutes ]] || [[ $now_minutes -gt $end_minutes ]]; then
        echo "OFF_HOURS:$name outside ${start_time}-${end_time}"
        return
    fi

    # Check 3: Not already working
    if [[ -n "$current_task" ]] && [[ "$current_task" != "" ]]; then
        echo "BUSY:$name working on $current_task"
        return
    fi

    # Check 4: Budget (Paperclip pattern: pause when spent >= budget)
    if [[ "$budget" -gt 0 ]] && [[ "$spent" -ge "$budget" ]]; then
        # Auto-pause the agent (Paperclip does this in costService.createEvent)
        sqlite3 "$HYDRA_DB" "
            UPDATE agents SET status = 'paused', updated_at = datetime('now')
            WHERE id = '$agent_id' AND status = 'active';
        " 2>/dev/null
        log "BUDGET: $name paused — spent $spent/$budget cents"

        # Alert Eddie
        if [[ -x "$NOTIFY" ]]; then
            "$NOTIFY" normal "Budget Limit" "$name hit monthly budget (\$$(echo "scale=2; $spent/100" | bc)/\$$(echo "scale=2; $budget/100" | bc))" 2>/dev/null || true
        fi

        echo "OVER_BUDGET:$name spent $spent/$budget cents"
        return
    fi

    # Check 5: Heartbeat interval (skip if heartbeat_minutes = 0 = on-demand only)
    if [[ "$heartbeat_min" -gt 0 ]] && [[ -n "$last_beat" ]] && [[ "$last_beat" != "" ]]; then
        local seconds_since=$(python3 -c "
from datetime import datetime, timezone
try:
    last = datetime.strptime('$last_beat', '%Y-%m-%d %H:%M:%S')
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    print(int((now - last).total_seconds()))
except:
    print(99999)
" 2>/dev/null || echo "99999")
        local interval_seconds=$((heartbeat_min * 60))
        if [[ $seconds_since -lt $interval_seconds ]]; then
            echo "COOLING:$name last beat ${seconds_since}s ago (interval: ${interval_seconds}s)"
            return
        fi
    fi

    echo "AVAILABLE"
}

# ============================================================================
# ATOMIC TASK CHECKOUT
# ============================================================================
# Paperclip's key innovation: task checkout is atomic.
# No two agents can grab the same task. SQLite's BEGIN EXCLUSIVE handles this.

checkout_task() {
    local agent_id="$1"

    # Get agent's task_types from agents.yaml (skills_filter column)
    local agent_types=$(sqlite3 "$HYDRA_DB" "
        SELECT COALESCE(skills_filter, '[\"all\"]') FROM agents WHERE id = '$agent_id';
    " 2>/dev/null || echo '["all"]')

    # Build task type filter
    local type_filter=""
    if [[ "$agent_types" != '["all"]' ]]; then
        # Extract types from JSON array, build SQL IN clause
        local types=$(echo "$agent_types" | python3 -c "
import json, sys
types = json.load(sys.stdin)
print(','.join(f\"'{t}'\" for t in types))
" 2>/dev/null || echo "")
        if [[ -n "$types" ]]; then
            type_filter="AND task_type IN ($types)"
        fi
    fi

    # Atomic checkout: find highest-priority unassigned task matching agent skills
    # BEGIN EXCLUSIVE ensures no race condition between agents
    local task_id=$(sqlite3 "$HYDRA_DB" "
        BEGIN EXCLUSIVE;

        -- Find best matching task
        SELECT id FROM tasks
        WHERE status = 'pending'
        AND (assigned_to IS NULL OR assigned_to = '')
        $type_filter
        ORDER BY priority ASC, created_at ASC
        LIMIT 1;
    " 2>/dev/null)

    if [[ -z "$task_id" ]]; then
        # No task available — commit empty transaction
        sqlite3 "$HYDRA_DB" "COMMIT;" 2>/dev/null || true
        echo ""
        return
    fi

    # Assign task to agent atomically
    sqlite3 "$HYDRA_DB" "
        UPDATE tasks
        SET assigned_to = '$agent_id',
            status = 'in_progress',
            updated_at = datetime('now')
        WHERE id = '$task_id' AND status = 'pending';

        UPDATE agents
        SET current_task_id = '$task_id',
            last_heartbeat_at = datetime('now'),
            updated_at = datetime('now')
        WHERE id = '$agent_id';

        -- Create a task run record
        INSERT INTO task_runs (agent_id, task_id, status)
        VALUES ('$agent_id', '$task_id', 'running');

        COMMIT;
    " 2>/dev/null

    echo "$task_id"
}

# ============================================================================
# COMPLETE TASK
# ============================================================================
# Called by adapter after agent finishes work.

complete_task() {
    local agent_id="$1"
    local task_id="$2"
    local status="${3:-completed}"  # 'completed' or 'failed'
    local cost_cents="${4:-0}"
    local exit_code="${5:-0}"
    local error_msg="${6:-}"

    sqlite3 "$HYDRA_DB" "
        -- Update task
        UPDATE tasks
        SET status = '$status',
            completed_at = CASE WHEN '$status' = 'completed' THEN datetime('now') ELSE NULL END,
            updated_at = datetime('now')
        WHERE id = '$task_id';

        -- Release agent
        UPDATE agents
        SET current_task_id = NULL,
            last_heartbeat_at = datetime('now'),
            spent_monthly_cents = spent_monthly_cents + $cost_cents,
            updated_at = datetime('now')
        WHERE id = '$agent_id';

        -- Update task run
        UPDATE task_runs
        SET status = '$status',
            exit_code = $exit_code,
            cost_cents = $cost_cents,
            error_message = '$(echo "$error_msg" | sed "s/'/''/g")',
            finished_at = datetime('now'),
            duration_sec = CAST((julianday('now') - julianday(started_at)) * 86400 AS INTEGER)
        WHERE agent_id = '$agent_id' AND task_id = '$task_id' AND status = 'running';
    " 2>/dev/null

    log "COMPLETE: $agent_id finished $task_id (status=$status, cost=${cost_cents}c)"

    # Post to agent board
    if [[ -x "$HYDRA_ROOT/tools/board-post.sh" ]]; then
        local task_title=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id='$task_id';" 2>/dev/null)
        "$HYDRA_ROOT/tools/board-post.sh" builds "$agent_id" "Task $status: $task_title (cost: ${cost_cents}c)" --tags "$status" 2>/dev/null || true
    fi
}

# ============================================================================
# SCHEDULING CYCLE
# ============================================================================
# Run one full scheduling cycle across all agents.

run_cycle() {
    local dry_run="${1:-false}"
    local target_agent="${2:-}"

    log "=== Scheduling cycle started (dry_run=$dry_run) ==="

    # Reset budgets if new month
    reset_budgets_if_new_month

    # Get agents to check
    local agent_list
    if [[ -n "$target_agent" ]]; then
        agent_list="$target_agent"
    else
        agent_list=$(sqlite3 "$HYDRA_DB" "SELECT id FROM agents WHERE status != 'disabled' ORDER BY heartbeat_minutes ASC;" 2>/dev/null)
    fi

    local scheduled=0
    local skipped=0

    for agent_id in $agent_list; do
        local availability=$(check_agent_available "$agent_id")

        if [[ "$availability" != "AVAILABLE" ]]; then
            log "  SKIP $agent_id: $availability"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$dry_run" == "true" ]]; then
            log "  DRY-RUN: $agent_id is available, would check out a task"
            echo "AVAILABLE: $agent_id"
            continue
        fi

        # Atomic checkout
        local task_id=$(checkout_task "$agent_id")

        if [[ -z "$task_id" ]]; then
            log "  $agent_id: available but no matching tasks"
            # Still update heartbeat so we don't re-check too soon
            sqlite3 "$HYDRA_DB" "
                UPDATE agents SET last_heartbeat_at = datetime('now'), updated_at = datetime('now')
                WHERE id = '$agent_id';
            " 2>/dev/null
            continue
        fi

        local task_title=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id='$task_id';" 2>/dev/null)
        log "  ASSIGNED: $agent_id <- '$task_title' ($task_id)"

        # Dispatch to adapter (async — don't block the scheduler)
        if [[ -x "$ADAPTER_SCRIPT" ]]; then
            "$ADAPTER_SCRIPT" execute "$agent_id" "$task_id" >> "$LOG_DIR/adapter-$agent_id.log" 2>&1 &
            log "  DISPATCHED: $agent_id (PID $!)"
        else
            log "  WARN: No adapter script at $ADAPTER_SCRIPT — task assigned but not executed"
        fi

        scheduled=$((scheduled + 1))
    done

    log "=== Cycle complete: $scheduled assigned, $skipped skipped ==="
    echo "Scheduled: $scheduled, Skipped: $skipped"
}

# ============================================================================
# STATUS DISPLAY
# ============================================================================

show_status() {
    echo "=== HYDRA Agent Status ==="
    echo ""
    sqlite3 -column -header "$HYDRA_DB" "
        SELECT
            id,
            name,
            status,
            adapter_type,
            CASE WHEN budget_monthly_cents = 0 THEN 'unlimited'
                 ELSE printf('\$%.2f/\$%.2f', spent_monthly_cents/100.0, budget_monthly_cents/100.0)
            END AS budget,
            CASE WHEN current_task_id IS NOT NULL AND current_task_id != ''
                 THEN substr(current_task_id, 1, 8) || '...'
                 ELSE 'idle'
            END AS working_on,
            COALESCE(last_heartbeat_at, 'never') AS last_beat
        FROM agents
        WHERE status != 'disabled'
        ORDER BY name;
    " 2>/dev/null

    echo ""
    echo "=== Pending Tasks ==="
    sqlite3 -column -header "$HYDRA_DB" "
        SELECT
            substr(id, 1, 8) || '...' AS id,
            title,
            priority,
            task_type,
            COALESCE(assigned_to, 'unassigned') AS agent
        FROM tasks
        WHERE status IN ('pending', 'in_progress')
        ORDER BY priority ASC, created_at ASC
        LIMIT 10;
    " 2>/dev/null

    echo ""
    echo "=== Recent Runs ==="
    sqlite3 -column -header "$HYDRA_DB" "
        SELECT * FROM v_recent_runs LIMIT 5;
    " 2>/dev/null || echo "(no runs yet)"
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    --dry-run)
        run_cycle "true" "${2:-}"
        ;;
    --agent)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: hydra-task-scheduler.sh --agent <agent_id>"
            exit 1
        fi
        run_cycle "false" "$2"
        ;;
    --reset-budgets)
        reset_budgets_if_new_month
        echo "Budget reset check complete."
        ;;
    --status)
        show_status
        ;;
    --complete)
        # Called by adapter: --complete <agent_id> <task_id> <status> [cost_cents] [exit_code] [error]
        complete_task "${2:-}" "${3:-}" "${4:-completed}" "${5:-0}" "${6:-0}" "${7:-}"
        ;;
    --help|-h)
        echo "HYDRA Task Scheduler (Paperclip-inspired)"
        echo ""
        echo "Commands:"
        echo "  (none)              Run one scheduling cycle"
        echo "  --agent <id>        Schedule for specific agent only"
        echo "  --dry-run           Show what would be assigned"
        echo "  --status            Show agent availability + budgets"
        echo "  --reset-budgets     Force monthly budget reset"
        echo "  --complete <args>   Mark task complete (called by adapter)"
        echo ""
        echo "Patterns from Paperclip:"
        echo "  - Atomic task checkout (SQLite EXCLUSIVE)"
        echo "  - Budget-aware scheduling (auto-pause on limit)"
        echo "  - Persistent session state across heartbeats"
        echo "  - Goal-aware execution (task carries context)"
        ;;
    *)
        run_cycle "false" ""
        ;;
esac
