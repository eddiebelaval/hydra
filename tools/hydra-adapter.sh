#!/bin/bash
# hydra-adapter.sh - Agent Adapter Dispatch Layer
#
# Standardized execution interface for any agent type.
# Inspired by Paperclip's adapter pattern (packages/adapters/).
#
# Each adapter type implements a contract:
#   Input:  agent config + task context + working directory
#   Output: exit code + cost + token usage + session state
#
# Supported adapter types:
#   claude_local    — Claude Code CLI (claude --print or interactive)
#   codex_local     — OpenAI Codex CLI
#   hydra_daemon    — Existing HYDRA shell daemon (backward compat)
#   http_webhook    — POST task to an HTTP endpoint
#   script          — Run arbitrary script with task context as env vars
#
# Usage:
#   hydra-adapter.sh execute <agent_id> <task_id>
#   hydra-adapter.sh test <agent_id>              # Test adapter connectivity
#   hydra-adapter.sh list                          # Show adapter configs

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
SCHEDULER="$HYDRA_ROOT/tools/hydra-task-scheduler.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-adapter"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_DIR/adapter.log"
}

# ============================================================================
# LOAD AGENT + TASK CONTEXT
# ============================================================================

load_context() {
    local agent_id="$1"
    local task_id="$2"

    # Load agent data
    AGENT_NAME=$(sqlite3 "$HYDRA_DB" "SELECT name FROM agents WHERE id='$agent_id';" 2>/dev/null)
    AGENT_MODEL=$(sqlite3 "$HYDRA_DB" "SELECT model FROM agents WHERE id='$agent_id';" 2>/dev/null)
    ADAPTER_TYPE=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(adapter_type, 'hydra_daemon') FROM agents WHERE id='$agent_id';" 2>/dev/null)
    ADAPTER_CONFIG=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(adapter_config, '{}') FROM agents WHERE id='$agent_id';" 2>/dev/null)

    # Load task data
    TASK_TITLE=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id='$task_id';" 2>/dev/null)
    TASK_DESC=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(description, '') FROM tasks WHERE id='$task_id';" 2>/dev/null)
    TASK_TYPE=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(task_type, 'general') FROM tasks WHERE id='$task_id';" 2>/dev/null)
    TASK_PRIORITY=$(sqlite3 "$HYDRA_DB" "SELECT priority FROM tasks WHERE id='$task_id';" 2>/dev/null)
    TASK_METADATA=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(metadata, '{}') FROM tasks WHERE id='$task_id';" 2>/dev/null)

    # Extract adapter config fields (via python for JSON safety)
    ADAPTER_CWD=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; c=json.load(sys.stdin); print(c.get('cwd','$HOME/Development'))" 2>/dev/null || echo "$HOME/Development")
    ADAPTER_TIMEOUT=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; c=json.load(sys.stdin); print(c.get('timeout_sec', 300))" 2>/dev/null || echo "300")
    ADAPTER_ENV=$(echo "$ADAPTER_CONFIG" | python3 -c "
import json, sys
c = json.load(sys.stdin)
env = c.get('env', {})
for k, v in env.items():
    print(f'{k}={v}')
" 2>/dev/null || echo "")
}

# ============================================================================
# ADAPTER: claude_local
# ============================================================================
# Runs Claude Code CLI with task as prompt. Captures usage from output.
# Mirrors Paperclip's claude-local adapter.

execute_claude_local() {
    local agent_id="$1"
    local task_id="$2"

    local model_flag=""
    if [[ -n "$AGENT_MODEL" ]] && [[ "$AGENT_MODEL" != *"synthetic"* ]]; then
        # Extract model name from format like 'anthropic/claude-sonnet-4-20250514'
        local model_name="${AGENT_MODEL##*/}"
        model_flag="--model $model_name"
    fi

    local prompt="Task: $TASK_TITLE

$TASK_DESC

Type: $TASK_TYPE | Priority: $TASK_PRIORITY

Instructions: Complete this task. Report what you did when finished."

    log "CLAUDE_LOCAL: Executing for $AGENT_NAME in $ADAPTER_CWD"

    local output_file="$LOG_DIR/run-${agent_id}-$(date +%s).json"
    local start_time=$(date +%s)

    # Set adapter env vars
    if [[ -n "$ADAPTER_ENV" ]]; then
        while IFS= read -r line; do
            export "$line" 2>/dev/null || true
        done <<< "$ADAPTER_ENV"
    fi

    # Export task context as env vars (Paperclip's PAPERCLIP_WORKSPACE_* pattern)
    export HYDRA_TASK_ID="$task_id"
    export HYDRA_TASK_TITLE="$TASK_TITLE"
    export HYDRA_TASK_TYPE="$TASK_TYPE"
    export HYDRA_AGENT_ID="$agent_id"
    export HYDRA_AGENT_NAME="$AGENT_NAME"

    local exit_code=0
    local output=""

    # Run Claude Code in print mode with timeout
    output=$(timeout "${ADAPTER_TIMEOUT}s" claude --print $model_flag --output-format json \
        -p "$prompt" \
        --cwd "$ADAPTER_CWD" 2>&1) || exit_code=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Parse usage from JSON output
    local cost_cents=0
    local input_tokens=0
    local output_tokens=0
    local model_used=""

    if echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        cost_cents=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
# Claude --output-format json includes usage stats
usage = data.get('usage', {})
cost = data.get('cost_usd', 0) or 0
print(int(float(cost) * 100))
" 2>/dev/null || echo "0")

        input_tokens=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('usage', {}).get('input_tokens', 0))
" 2>/dev/null || echo "0")

        output_tokens=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('usage', {}).get('output_tokens', 0))
" 2>/dev/null || echo "0")

        model_used=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('model', ''))
" 2>/dev/null || echo "")
    fi

    # Record cost event
    if [[ "$cost_cents" -gt 0 ]]; then
        sqlite3 "$HYDRA_DB" "
            INSERT INTO cost_events (agent_id, task_id, cost_cents, input_tokens, output_tokens, model, billing_type, source)
            VALUES ('$agent_id', '$task_id', $cost_cents, $input_tokens, $output_tokens, '$model_used', 'api', 'auto');
        " 2>/dev/null
    fi

    # Save run output
    echo "$output" > "$output_file" 2>/dev/null

    # Report completion
    local status="completed"
    local error_msg=""
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
        error_msg="Exit code $exit_code"
        if [[ $exit_code -eq 124 ]]; then
            status="timeout"
            error_msg="Timeout after ${ADAPTER_TIMEOUT}s"
        fi
    fi

    "$SCHEDULER" --complete "$agent_id" "$task_id" "$status" "$cost_cents" "$exit_code" "$error_msg"

    log "CLAUDE_LOCAL: $AGENT_NAME finished ($status, ${cost_cents}c, ${duration}s)"
}

# ============================================================================
# ADAPTER: codex_local
# ============================================================================

execute_codex_local() {
    local agent_id="$1"
    local task_id="$2"

    local prompt="$TASK_TITLE. $TASK_DESC"

    log "CODEX_LOCAL: Executing for $AGENT_NAME in $ADAPTER_CWD"

    local start_time=$(date +%s)
    local exit_code=0

    # Codex CLI execution
    local output=""
    output=$(timeout "${ADAPTER_TIMEOUT}s" codex --approval-mode full-auto \
        -q "$prompt" \
        --cwd "$ADAPTER_CWD" 2>&1) || exit_code=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Codex uses subscription billing — $0 API cost
    local status="completed"
    [[ $exit_code -ne 0 ]] && status="failed"
    [[ $exit_code -eq 124 ]] && status="timeout"

    "$SCHEDULER" --complete "$agent_id" "$task_id" "$status" "0" "$exit_code" ""

    log "CODEX_LOCAL: $AGENT_NAME finished ($status, ${duration}s)"
}

# ============================================================================
# ADAPTER: hydra_daemon (backward compatibility)
# ============================================================================

execute_hydra_daemon() {
    local agent_id="$1"
    local task_id="$2"

    log "HYDRA_DAEMON: $AGENT_NAME — existing daemon pattern, no-op dispatch"

    # For existing daemons, we just mark the task as assigned.
    # The daemon itself handles execution via its own plist schedule.
    # This adapter exists for backward compatibility.

    # Auto-complete after the daemon's heartbeat interval
    local heartbeat_min=$(sqlite3 "$HYDRA_DB" "SELECT heartbeat_minutes FROM agents WHERE id='$agent_id';" 2>/dev/null || echo "30")

    log "HYDRA_DAEMON: $AGENT_NAME will self-manage task (heartbeat: ${heartbeat_min}m)"
}

# ============================================================================
# ADAPTER: http_webhook
# ============================================================================

execute_http_webhook() {
    local agent_id="$1"
    local task_id="$2"

    local webhook_url=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)

    if [[ -z "$webhook_url" ]]; then
        log "HTTP_WEBHOOK: No URL configured for $AGENT_NAME"
        "$SCHEDULER" --complete "$agent_id" "$task_id" "failed" "0" "1" "No webhook URL configured"
        return
    fi

    log "HTTP_WEBHOOK: POST to $webhook_url for $AGENT_NAME"

    local payload=$(python3 -c "
import json
print(json.dumps({
    'agent_id': '$agent_id',
    'agent_name': '$AGENT_NAME',
    'task_id': '$task_id',
    'task_title': '''$TASK_TITLE''',
    'task_description': '''$TASK_DESC''',
    'task_type': '$TASK_TYPE',
    'priority': $TASK_PRIORITY
}))
" 2>/dev/null)

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 30 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "202" ]]; then
        log "HTTP_WEBHOOK: Accepted ($http_code)"
        # Don't auto-complete — webhook will call back
    else
        log "HTTP_WEBHOOK: Failed ($http_code)"
        "$SCHEDULER" --complete "$agent_id" "$task_id" "failed" "0" "1" "Webhook returned $http_code"
    fi
}

# ============================================================================
# ADAPTER: script
# ============================================================================

execute_script() {
    local agent_id="$1"
    local task_id="$2"

    local script_path=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('script',''))" 2>/dev/null)

    if [[ ! -x "$script_path" ]]; then
        log "SCRIPT: Not executable: $script_path"
        "$SCHEDULER" --complete "$agent_id" "$task_id" "failed" "0" "1" "Script not found or not executable"
        return
    fi

    export HYDRA_TASK_ID="$task_id"
    export HYDRA_TASK_TITLE="$TASK_TITLE"
    export HYDRA_TASK_TYPE="$TASK_TYPE"
    export HYDRA_AGENT_ID="$agent_id"

    local exit_code=0
    timeout "${ADAPTER_TIMEOUT}s" "$script_path" 2>&1 >> "$LOG_DIR/script-${agent_id}.log" || exit_code=$?

    local status="completed"
    [[ $exit_code -ne 0 ]] && status="failed"

    "$SCHEDULER" --complete "$agent_id" "$task_id" "$status" "0" "$exit_code" ""

    log "SCRIPT: $AGENT_NAME finished ($status)"
}

# ============================================================================
# DISPATCH
# ============================================================================

execute() {
    local agent_id="$1"
    local task_id="$2"

    load_context "$agent_id" "$task_id"

    log "DISPATCH: $AGENT_NAME ($ADAPTER_TYPE) -> task '$TASK_TITLE'"

    case "$ADAPTER_TYPE" in
        claude_local)    execute_claude_local "$agent_id" "$task_id" ;;
        codex_local)     execute_codex_local "$agent_id" "$task_id" ;;
        hydra_daemon)    execute_hydra_daemon "$agent_id" "$task_id" ;;
        http_webhook)    execute_http_webhook "$agent_id" "$task_id" ;;
        script)          execute_script "$agent_id" "$task_id" ;;
        *)
            log "ERROR: Unknown adapter type '$ADAPTER_TYPE' for $AGENT_NAME"
            "$SCHEDULER" --complete "$agent_id" "$task_id" "failed" "0" "1" "Unknown adapter: $ADAPTER_TYPE"
            ;;
    esac
}

# ============================================================================
# TEST ADAPTER
# ============================================================================

test_adapter() {
    local agent_id="$1"

    ADAPTER_TYPE=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(adapter_type, 'hydra_daemon') FROM agents WHERE id='$agent_id';" 2>/dev/null)
    AGENT_NAME=$(sqlite3 "$HYDRA_DB" "SELECT name FROM agents WHERE id='$agent_id';" 2>/dev/null)
    ADAPTER_CONFIG=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(adapter_config, '{}') FROM agents WHERE id='$agent_id';" 2>/dev/null)

    echo "Testing adapter for $AGENT_NAME ($ADAPTER_TYPE)..."

    case "$ADAPTER_TYPE" in
        claude_local)
            if command -v claude &>/dev/null; then
                echo "  claude CLI: FOUND ($(which claude))"
            else
                echo "  claude CLI: NOT FOUND"
            fi
            ;;
        codex_local)
            if command -v codex &>/dev/null; then
                echo "  codex CLI: FOUND ($(which codex))"
            else
                echo "  codex CLI: NOT FOUND"
            fi
            ;;
        hydra_daemon)
            echo "  hydra_daemon: backward-compat mode (no test needed)"
            ;;
        http_webhook)
            local url=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
            if [[ -n "$url" ]]; then
                local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
                echo "  webhook $url: HTTP $code"
            else
                echo "  webhook: NO URL CONFIGURED"
            fi
            ;;
        script)
            local script=$(echo "$ADAPTER_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('script',''))" 2>/dev/null)
            if [[ -x "$script" ]]; then
                echo "  script $script: EXECUTABLE"
            else
                echo "  script $script: NOT FOUND or NOT EXECUTABLE"
            fi
            ;;
    esac
}

# ============================================================================
# LIST ADAPTERS
# ============================================================================

list_adapters() {
    echo "=== HYDRA Adapter Registry ==="
    echo ""
    sqlite3 -column -header "$HYDRA_DB" "
        SELECT id, name, adapter_type, adapter_config
        FROM agents
        WHERE status != 'disabled'
        ORDER BY name;
    " 2>/dev/null
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    execute)
        if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]]; then
            echo "Usage: hydra-adapter.sh execute <agent_id> <task_id>"
            exit 1
        fi
        execute "$2" "$3"
        ;;
    test)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: hydra-adapter.sh test <agent_id>"
            exit 1
        fi
        test_adapter "$2"
        ;;
    list)
        list_adapters
        ;;
    *)
        echo "HYDRA Adapter Dispatch (Paperclip-inspired)"
        echo ""
        echo "Commands:"
        echo "  execute <agent> <task>   Dispatch task to agent's adapter"
        echo "  test <agent>             Test adapter connectivity"
        echo "  list                     Show all agent adapter configs"
        echo ""
        echo "Adapter types: claude_local, codex_local, hydra_daemon, http_webhook, script"
        ;;
esac
