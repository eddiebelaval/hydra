#!/bin/bash
# hydra-heartbeat.sh - HYDRA System Health Monitor
#
# Runs every 30 minutes via launchd.
# Performs 5 health checks (no AI calls except a minimal API ping):
#   1. Launchd jobs: all HYDRA plists loaded and running
#   2. Database: integrity check + size limit
#   3. Disk space: ~/.hydra < 5GB, home dir > 10GB free
#   4. Event buffer: size < 10MB (auto-rotate if exceeded)
#   5. API keys: minimal Haiku ping (~$0.0001)
#
# Alert logic:
#   - Only alerts on CRITICAL status
#   - Requires 2+ consecutive failures (no transient noise)
#   - Rate limited to 1 alert per 2 hours per component

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
EVENT_BUFFER="$HYDRA_ROOT/state/event-buffer.log"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-heartbeat"
LOG_FILE="$LOG_DIR/heartbeat.log"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"

# Load API key for ping check
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Heartbeat check started ==="

# ============================================================================
# HELPERS
# ============================================================================

record_check() {
    local check_type="$1"
    local component="$2"
    local status="$3"
    local details="$4"

    # Get previous failure count for this component
    local prev_failures=$(sqlite3 "$HYDRA_DB" "
        SELECT COALESCE(failure_count, 0) FROM system_health
        WHERE check_type = '$check_type' AND component = '$component'
        ORDER BY check_time DESC LIMIT 1;
    " 2>/dev/null || echo "0")

    local failure_count=0
    if [[ "$status" == "critical" ]] || [[ "$status" == "warning" ]]; then
        failure_count=$((prev_failures + 1))
    fi

    # Insert health record
    sqlite3 "$HYDRA_DB" "
        INSERT INTO system_health (check_type, component, status, details, failure_count)
        VALUES ('$check_type', '$component', '$status', '$(echo "$details" | sed "s/'/''/g")', $failure_count);
    " 2>/dev/null

    log "  [$status] $check_type/$component: $details (failures: $failure_count)"

    # Alert on critical with 2+ consecutive failures
    if [[ "$status" == "critical" ]] && [[ $failure_count -ge 2 ]]; then
        # Rate limit: 1 alert per 2 hours per component
        local last_alert=$(sqlite3 "$HYDRA_DB" "
            SELECT last_alert_sent FROM system_health
            WHERE check_type = '$check_type' AND component = '$component'
            AND last_alert_sent IS NOT NULL
            ORDER BY check_time DESC LIMIT 1;
        " 2>/dev/null || echo "")

        local should_alert="true"
        if [[ -n "$last_alert" ]]; then
            local hours_since=$(python3 -c "
from datetime import datetime
last = datetime.strptime('$last_alert', '%Y-%m-%d %H:%M:%S')
now = datetime.now()
print((now - last).total_seconds() / 3600)
" 2>/dev/null || echo "999")
            if python3 -c "exit(0 if float('$hours_since') < 2 else 1)" 2>/dev/null; then
                should_alert="false"
                log "  Alert suppressed (rate limit: last alert ${hours_since}h ago)"
            fi
        fi

        if [[ "$should_alert" == "true" ]]; then
            "$NOTIFY" urgent "HYDRA Health: CRITICAL" "$check_type/$component: $details (${failure_count} consecutive failures)" 2>/dev/null || true
            # Update last_alert_sent
            sqlite3 "$HYDRA_DB" "
                UPDATE system_health SET last_alert_sent = datetime('now')
                WHERE id = (SELECT id FROM system_health WHERE check_type = '$check_type' AND component = '$component' ORDER BY check_time DESC LIMIT 1);
            " 2>/dev/null
            log "  ALERT SENT for $check_type/$component"
        fi
    fi
}

# ============================================================================
# CHECK 1: LAUNCHD JOBS
# ============================================================================

check_launchd() {
    log "Check 1: Launchd jobs"

    # Expected HYDRA plists (core infrastructure)
    local expected_jobs=(
        "com.hydra.telegram-listener"
        "com.hydra.briefing"
        "com.hydra.brain-updater"
        "com.hydra.observer"
        "com.hydra.reflector"
        "com.hydra.notification-check"
        "com.hydra.log-rotate"
        "com.hydra.goals-updater"
        "com.hydra.morning-planner"
        "com.hydra.evening-review"
        "com.hydra.heartbeat"
    )

    local loaded_jobs=$(launchctl list 2>/dev/null | grep "com.hydra" | awk '{print $3}')
    local missing=""
    local count=0
    local total=${#expected_jobs[@]}

    for job in "${expected_jobs[@]}"; do
        if echo "$loaded_jobs" | grep -q "^${job}$"; then
            count=$((count + 1))
        else
            missing="${missing}${job}, "
        fi
    done

    if [[ $count -eq $total ]]; then
        record_check "launchd" "all_jobs" "healthy" "$count/$total jobs loaded"
    elif [[ $count -ge $((total - 2)) ]]; then
        record_check "launchd" "all_jobs" "warning" "$count/$total loaded. Missing: ${missing%, }"
    else
        record_check "launchd" "all_jobs" "critical" "$count/$total loaded. Missing: ${missing%, }"
    fi

    # Special check: telegram-listener should have a running PID
    local listener_pid=$(launchctl list 2>/dev/null | grep "com.hydra.telegram-listener" | awk '{print $1}')
    if [[ "$listener_pid" != "-" ]] && [[ -n "$listener_pid" ]] && [[ "$listener_pid" != "0" ]]; then
        record_check "launchd" "telegram_listener" "healthy" "Running (PID $listener_pid)"
    else
        record_check "launchd" "telegram_listener" "warning" "Not actively running (PID: ${listener_pid:-none})"
    fi
}

# ============================================================================
# CHECK 2: DATABASE INTEGRITY
# ============================================================================

check_database() {
    log "Check 2: Database"

    if [[ ! -f "$HYDRA_DB" ]]; then
        record_check "db" "hydra.db" "critical" "Database file not found"
        return
    fi

    # Integrity check
    local integrity=$(sqlite3 "$HYDRA_DB" "PRAGMA integrity_check;" 2>/dev/null || echo "FAILED")
    if [[ "$integrity" == "ok" ]]; then
        record_check "db" "integrity" "healthy" "PRAGMA integrity_check: ok"
    else
        record_check "db" "integrity" "critical" "Integrity check failed: $integrity"
    fi

    # Size check (< 1GB)
    local db_size_bytes=$(stat -f%z "$HYDRA_DB" 2>/dev/null || echo "0")
    local db_size_mb=$((db_size_bytes / 1048576))
    if [[ $db_size_mb -lt 500 ]]; then
        record_check "db" "size" "healthy" "${db_size_mb}MB (limit: 1000MB)"
    elif [[ $db_size_mb -lt 1000 ]]; then
        record_check "db" "size" "warning" "${db_size_mb}MB approaching 1GB limit"
    else
        record_check "db" "size" "critical" "${db_size_mb}MB exceeds 1GB limit"
    fi
}

# ============================================================================
# CHECK 3: DISK SPACE
# ============================================================================

check_disk() {
    log "Check 3: Disk space"

    # ~/.hydra directory size (< 5GB)
    local hydra_size_kb=$(du -sk "$HYDRA_ROOT" 2>/dev/null | cut -f1)
    local hydra_size_mb=$((hydra_size_kb / 1024))
    if [[ $hydra_size_mb -lt 2000 ]]; then
        record_check "disk" "hydra_dir" "healthy" "${hydra_size_mb}MB (limit: 5000MB)"
    elif [[ $hydra_size_mb -lt 5000 ]]; then
        record_check "disk" "hydra_dir" "warning" "${hydra_size_mb}MB approaching 5GB limit"
    else
        record_check "disk" "hydra_dir" "critical" "${hydra_size_mb}MB exceeds 5GB limit"
    fi

    # Home directory free space (> 10GB)
    local free_kb=$(df -k "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
    local free_gb=$((free_kb / 1048576))
    if [[ $free_gb -gt 20 ]]; then
        record_check "disk" "free_space" "healthy" "${free_gb}GB free"
    elif [[ $free_gb -gt 10 ]]; then
        record_check "disk" "free_space" "warning" "${free_gb}GB free (getting low)"
    else
        record_check "disk" "free_space" "critical" "${free_gb}GB free (below 10GB threshold)"
    fi
}

# ============================================================================
# CHECK 4: EVENT BUFFER
# ============================================================================

check_event_buffer() {
    log "Check 4: Event buffer"

    if [[ ! -f "$EVENT_BUFFER" ]]; then
        record_check "event_buffer" "size" "healthy" "No buffer file (normal if observer just ran)"
        return
    fi

    local buffer_size_bytes=$(stat -f%z "$EVENT_BUFFER" 2>/dev/null || echo "0")
    local buffer_size_kb=$((buffer_size_bytes / 1024))

    if [[ $buffer_size_kb -lt 5000 ]]; then
        record_check "event_buffer" "size" "healthy" "${buffer_size_kb}KB (limit: 10240KB)"
    elif [[ $buffer_size_kb -lt 10240 ]]; then
        record_check "event_buffer" "size" "warning" "${buffer_size_kb}KB approaching 10MB limit"
    else
        # Auto-rotate: keep last 1000 lines, archive the rest
        local archive="$HYDRA_ROOT/state/event-buffer-$(date +%Y%m%d-%H%M%S).log.bak"
        cp "$EVENT_BUFFER" "$archive"
        tail -1000 "$EVENT_BUFFER" > "${EVENT_BUFFER}.tmp"
        mv "${EVENT_BUFFER}.tmp" "$EVENT_BUFFER"
        record_check "event_buffer" "size" "warning" "Auto-rotated from ${buffer_size_kb}KB. Archive: $archive"
        log "  Event buffer auto-rotated"
    fi
}

# ============================================================================
# CHECK 5: API KEYS (minimal Haiku ping)
# ============================================================================

check_api() {
    log "Check 5: API keys"

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        record_check "api" "anthropic" "critical" "ANTHROPIC_API_KEY not set"
        return
    fi

    # Export so Python subprocess can read it
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

    # Minimal Haiku ping — cheapest possible API call (~$0.0001)
    local api_result=$(python3 << 'PYEOF'
import json, urllib.request, os

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 5,
    "messages": [{"role": "user", "content": "say ok"}]
}).encode()

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        }
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        if result.get("content"):
            print("ok")
        else:
            print("empty_response")
except urllib.error.HTTPError as e:
    print(f"http_{e.code}")
except Exception as e:
    print(f"error: {e}")
PYEOF
)

    if [[ "$api_result" == "ok" ]]; then
        record_check "api" "anthropic" "healthy" "Haiku ping successful"
    elif echo "$api_result" | grep -q "http_401"; then
        record_check "api" "anthropic" "critical" "API key invalid (401)"
    elif echo "$api_result" | grep -q "http_429"; then
        record_check "api" "anthropic" "warning" "Rate limited (429) — temporary"
    else
        record_check "api" "anthropic" "warning" "Ping result: $api_result"
    fi
}

# ============================================================================
# RUN ALL CHECKS
# ============================================================================

check_launchd
check_database
check_disk
check_event_buffer
check_api

# Cleanup: prune health records older than 30 days
sqlite3 "$HYDRA_DB" "DELETE FROM system_health WHERE check_time < datetime('now', '-30 days');" 2>/dev/null

log "=== Heartbeat check complete ==="
echo "Heartbeat complete. $(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM system_health WHERE date(check_time) = date('now');" 2>/dev/null) checks today."
