#!/bin/bash
# memory-guard.sh - HYDRA Memory Pressure Guardian
#
# Runs every 60 seconds via launchd.
# Monitors system memory pressure and takes action to prevent
# watchdog resets caused by memory exhaustion.
#
# Thresholds (36 GB system):
#   WARNING  → 75% used (~27 GB) → Telegram alert + macOS notification
#   CRITICAL → 85% used (~30 GB) → Auto-kill known memory hogs
#   EMERGENCY → 92% used (~33 GB) → Aggressive kill of non-essential processes
#
# Kill priority (safest first):
#   1. Codex Helper (Renderer) — known 2GB+ leak
#   2. Stale node processes (>2GB RSS, not in active terminals)
#   3. Excess Chrome renderers (keep 5, kill rest by RSS desc)
#   4. Electron renderers (Comet, Slack, Discord helpers)
#
# Never kills: Finder, WindowServer, loginwindow, kernel_task,
#              Terminal, wezterm, Ghostty, HYDRA scripts, Claude Code CLI

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-memory-guard"
LOG_FILE="$LOG_DIR/memory-guard.log"
STATE_FILE="$HYDRA_ROOT/state/memory-guard-state.json"

# Thresholds (percentage of 36GB)
WARN_PERCENT=75
CRITICAL_PERCENT=85
EMERGENCY_PERCENT=92

# Rate limiting: minimum seconds between alerts at each level
WARN_COOLDOWN=3600       # 1 hour between warning alerts
CRITICAL_COOLDOWN=600    # 10 min between critical alerts
EMERGENCY_COOLDOWN=120   # 2 min between emergency alerts

# Total system memory in pages (16KB each on ARM64)
TOTAL_MEM_BYTES=$(sysctl -n hw.memsize)
PAGE_SIZE=$(vm_stat | head -1 | grep -o '[0-9]*')

# Load Telegram credentials
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"last_warn":0,"last_critical":0,"last_emergency":0,"kills_today":0,"last_kill_date":""}' > "$STATE_FILE"
fi

# ============================================================================
# HELPERS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_state() {
    python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('$1', '$2'))" 2>/dev/null || echo "$2"
}

set_state() {
    python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    d = json.load(f)
d['$1'] = $2
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f)
" 2>/dev/null
}

now_epoch() {
    date +%s
}

# ============================================================================
# MEMORY CALCULATION
# ============================================================================

get_memory_usage() {
    # Parse vm_stat output for memory pages
    local vmstat=$(vm_stat 2>/dev/null)

    # vm_stat format: "Pages free:                    42934."
    # Field positions vary — extract the last field (the number with trailing period)
    local free=$(echo "$vmstat" | awk '/^Pages free:/ {gsub(/\./,"",$NF); print $NF}')
    local active=$(echo "$vmstat" | awk '/^Pages active:/ {gsub(/\./,"",$NF); print $NF}')
    local inactive=$(echo "$vmstat" | awk '/^Pages inactive:/ {gsub(/\./,"",$NF); print $NF}')
    local speculative=$(echo "$vmstat" | awk '/^Pages speculative:/ {gsub(/\./,"",$NF); print $NF}')
    local wired=$(echo "$vmstat" | awk '/^Pages wired down:/ {gsub(/\./,"",$NF); print $NF}')
    local compressed=$(echo "$vmstat" | awk '/^Pages occupied by compressor:/ {gsub(/\./,"",$NF); print $NF}')

    # Default to 0 if any are empty
    free=${free:-0}
    active=${active:-0}
    inactive=${inactive:-0}
    speculative=${speculative:-0}
    wired=${wired:-0}
    compressed=${compressed:-0}

    # Used = active + wired + compressed (conservative — excludes inactive/speculative)
    local used_pages=$((active + wired + compressed))
    local total_pages=$((TOTAL_MEM_BYTES / PAGE_SIZE))
    local free_pages=$((free + inactive + speculative))

    # Calculate percentage
    if [[ $total_pages -gt 0 ]]; then
        local percent=$((used_pages * 100 / total_pages))
    else
        local percent=0
    fi

    local used_gb=$(python3 -c "print(f'{$used_pages * $PAGE_SIZE / 1024**3:.1f}')" 2>/dev/null || echo "?")
    local free_gb=$(python3 -c "print(f'{$free_pages * $PAGE_SIZE / 1024**3:.1f}')" 2>/dev/null || echo "?")

    echo "$percent|$used_gb|$free_gb"
}

# ============================================================================
# PROCESS KILLERS (ordered by aggression)
# ============================================================================

# Protected process names — NEVER kill these
PROTECTED="Finder|WindowServer|loginwindow|kernel_task|launchd|systemd|powerd"
PROTECTED="$PROTECTED|Terminal|wezterm-gui|ghostty|Ghostty"
PROTECTED="$PROTECTED|notify-eddie|hydra-|telegram-listener|memory-guard"
PROTECTED="$PROTECTED|sshd|sudo|login|cron|bash.*hydra"

kill_codex_helpers() {
    # Codex Helper (Renderer) is the #1 offender — 2GB+ leak
    local killed=0
    local pids=$(pgrep -f "Codex Helper" 2>/dev/null || true)
    for pid in $pids; do
        local name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        local rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null || echo "0")
        local rss_mb=$((rss_kb / 1024))
        kill "$pid" 2>/dev/null && {
            log "  KILLED: Codex Helper (PID $pid, ${rss_mb}MB)"
            killed=$((killed + 1))
        }
    done
    echo "$killed"
}

kill_stale_node() {
    # Kill node processes using >2GB RSS that aren't attached to active terminals
    local killed=0
    local threshold_kb=$((2 * 1024 * 1024))  # 2GB in KB

    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local rss_kb=$(echo "$line" | awk '{print $2}')
        local tty=$(echo "$line" | awk '{print $3}')
        local cmd=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i}')

        # Skip if attached to a terminal (user is likely using it)
        if [[ "$tty" != "??" ]] && [[ "$tty" != "-" ]]; then
            continue
        fi

        # Skip if it matches protected patterns
        if echo "$cmd" | grep -qE "$PROTECTED"; then
            continue
        fi

        if [[ $rss_kb -gt $threshold_kb ]]; then
            local rss_mb=$((rss_kb / 1024))
            kill "$pid" 2>/dev/null && {
                log "  KILLED: node (PID $pid, ${rss_mb}MB, cmd: ${cmd:0:60})"
                killed=$((killed + 1))
            }
        fi
    done < <(ps -eo pid,rss,tty,command 2>/dev/null | grep "[n]ode" | sort -k2 -rn)
    echo "$killed"
}

kill_excess_chrome_renderers() {
    # Keep the 5 lowest-memory Chrome renderers, kill the rest
    local killed=0
    local keep=5
    local count=0

    # Get Chrome renderer PIDs sorted by RSS descending (kill biggest first)
    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local rss_kb=$(echo "$line" | awk '{print $2}')
        count=$((count + 1))

        # Count total first
        true
    done < <(pgrep -f "Chrome Helper (Renderer)" 2>/dev/null | while read p; do
        echo "$p $(ps -p "$p" -o rss= 2>/dev/null || echo 0)"
    done | sort -k2 -rn)

    if [[ $count -le $keep ]]; then
        echo "0"
        return
    fi

    local to_kill=$((count - keep))
    local idx=0

    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local rss_kb=$(echo "$line" | awk '{print $2}')
        local rss_mb=$((rss_kb / 1024))

        if [[ $idx -lt $to_kill ]]; then
            kill "$pid" 2>/dev/null && {
                log "  KILLED: Chrome Renderer (PID $pid, ${rss_mb}MB)"
                killed=$((killed + 1))
            }
        fi
        idx=$((idx + 1))
    done < <(pgrep -f "Chrome Helper (Renderer)" 2>/dev/null | while read p; do
        echo "$p $(ps -p "$p" -o rss= 2>/dev/null || echo 0)"
    done | sort -k2 -rn)

    echo "$killed"
}

kill_electron_helpers() {
    # Kill non-essential Electron renderer processes (Comet, Slack, Discord)
    local killed=0
    local targets="Comet Helper|Slack Helper|Discord Helper"

    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local rss_kb=$(echo "$line" | awk '{print $2}')
        local rss_mb=$((rss_kb / 1024))
        local name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")

        # Only kill renderers using >100MB
        if [[ $rss_kb -gt 102400 ]]; then
            kill "$pid" 2>/dev/null && {
                log "  KILLED: $name (PID $pid, ${rss_mb}MB)"
                killed=$((killed + 1))
            }
        fi
    done < <(pgrep -f "$targets" 2>/dev/null | while read p; do
        echo "$p $(ps -p "$p" -o rss= 2>/dev/null || echo 0)"
    done | sort -k2 -rn)

    echo "$killed"
}

# ============================================================================
# ALERT + ACTION
# ============================================================================

handle_warning() {
    local used_gb="$1"
    local free_gb="$2"
    local percent="$3"

    local now=$(now_epoch)
    local last=$(get_state "last_warn" "0")
    local diff=$((now - last))

    if [[ $diff -lt $WARN_COOLDOWN ]]; then
        log "Warning suppressed (cooldown: ${diff}s / ${WARN_COOLDOWN}s)"
        return
    fi

    set_state "last_warn" "$now"

    local msg="Memory at ${percent}% (${used_gb}GB used, ${free_gb}GB free of 36GB).

Top consumers:
$(ps -eo pid,rss,comm 2>/dev/null | sort -k2 -rn | head -5 | awk '{printf "%s (%dMB)\n", $3, $2/1024}')"

    "$NOTIFY" high "Memory Warning" "$msg" 2>/dev/null || true
    log "WARNING alert sent: ${percent}% used"
}

handle_critical() {
    local used_gb="$1"
    local free_gb="$2"
    local percent="$3"

    local now=$(now_epoch)
    local last=$(get_state "last_critical" "0")
    local diff=$((now - last))

    if [[ $diff -lt $CRITICAL_COOLDOWN ]]; then
        log "Critical alert suppressed (cooldown: ${diff}s / ${CRITICAL_COOLDOWN}s)"
    else
        set_state "last_critical" "$now"

        local top5=$(ps -eo pid,rss,comm 2>/dev/null | sort -k2 -rn | head -5 | awk '{printf "%s (%dMB)\n", $3, $2/1024}')

        "$NOTIFY" urgent "Memory CRITICAL" "Memory at ${percent}% (${used_gb}GB / 36GB). Auto-killing memory hogs now.

Top consumers:
${top5}" 2>/dev/null || true
        log "CRITICAL alert sent: ${percent}% used"
    fi

    # Auto-kill: Codex first, then stale node
    local total_killed=0
    local codex_killed=$(kill_codex_helpers)
    total_killed=$((total_killed + codex_killed))

    local node_killed=$(kill_stale_node)
    total_killed=$((total_killed + node_killed))

    if [[ $total_killed -gt 0 ]]; then
        log "CRITICAL action: killed $total_killed processes (codex: $codex_killed, node: $node_killed)"
        record_kill_count "$total_killed"
    else
        log "CRITICAL: no killable processes found"
    fi
}

handle_emergency() {
    local used_gb="$1"
    local free_gb="$2"
    local percent="$3"

    local now=$(now_epoch)
    local last=$(get_state "last_emergency" "0")
    local diff=$((now - last))

    if [[ $diff -lt $EMERGENCY_COOLDOWN ]]; then
        log "Emergency alert suppressed (cooldown: ${diff}s / ${EMERGENCY_COOLDOWN}s)"
    else
        set_state "last_emergency" "$now"
        "$NOTIFY" urgent "MEMORY EMERGENCY" "Memory at ${percent}% (${used_gb}GB / 36GB). Emergency kill sequence active. System at risk of watchdog reset." 2>/dev/null || true
        log "EMERGENCY alert sent: ${percent}% used"
    fi

    # Full kill sequence
    local total_killed=0

    local codex_killed=$(kill_codex_helpers)
    total_killed=$((total_killed + codex_killed))

    local node_killed=$(kill_stale_node)
    total_killed=$((total_killed + node_killed))

    local chrome_killed=$(kill_excess_chrome_renderers)
    total_killed=$((total_killed + chrome_killed))

    local electron_killed=$(kill_electron_helpers)
    total_killed=$((total_killed + electron_killed))

    if [[ $total_killed -gt 0 ]]; then
        log "EMERGENCY action: killed $total_killed processes (codex: $codex_killed, node: $node_killed, chrome: $chrome_killed, electron: $electron_killed)"
        record_kill_count "$total_killed"
    else
        log "EMERGENCY: nothing left to kill — manual intervention needed"
    fi
}

record_kill_count() {
    local count="$1"
    local today=$(date +%Y-%m-%d)
    local kill_date=$(get_state "last_kill_date" '""')

    # Strip quotes from JSON string
    kill_date=$(echo "$kill_date" | tr -d '"')

    if [[ "$kill_date" == "$today" ]]; then
        local prev=$(get_state "kills_today" "0")
        set_state "kills_today" "$((prev + count))"
    else
        set_state "kills_today" "$count"
        set_state "last_kill_date" "\"$today\""
    fi
}

# ============================================================================
# HEALTH RECORD (integrate with heartbeat's system_health table)
# ============================================================================

record_health() {
    local status="$1"
    local details="$2"

    sqlite3 "$HYDRA_DB" "
        INSERT INTO system_health (check_type, component, status, details, failure_count)
        VALUES ('memory', 'pressure', '$status', '$(echo "$details" | sed "s/'/''/g")', 0);
    " 2>/dev/null || true
}

# ============================================================================
# MAIN
# ============================================================================

result=$(get_memory_usage)
percent=$(echo "$result" | cut -d'|' -f1)
used_gb=$(echo "$result" | cut -d'|' -f2)
free_gb=$(echo "$result" | cut -d'|' -f3)

if [[ $percent -ge $EMERGENCY_PERCENT ]]; then
    log "EMERGENCY: ${percent}% memory used (${used_gb}GB / 36GB, ${free_gb}GB free)"
    record_health "critical" "EMERGENCY ${percent}% used (${used_gb}GB), ${free_gb}GB free"
    handle_emergency "$used_gb" "$free_gb" "$percent"

elif [[ $percent -ge $CRITICAL_PERCENT ]]; then
    log "CRITICAL: ${percent}% memory used (${used_gb}GB / 36GB, ${free_gb}GB free)"
    record_health "critical" "${percent}% used (${used_gb}GB), ${free_gb}GB free"
    handle_critical "$used_gb" "$free_gb" "$percent"

elif [[ $percent -ge $WARN_PERCENT ]]; then
    log "WARNING: ${percent}% memory used (${used_gb}GB / 36GB, ${free_gb}GB free)"
    record_health "warning" "${percent}% used (${used_gb}GB), ${free_gb}GB free"
    handle_warning "$used_gb" "$free_gb" "$percent"

else
    # Healthy — log every 15 minutes (every 15th run at 60s interval)
    run_count=$(get_state "run_count" "0")
    run_count=$((run_count + 1))
    set_state "run_count" "$run_count"

    if [[ $((run_count % 15)) -eq 0 ]]; then
        log "OK: ${percent}% memory used (${used_gb}GB / 36GB, ${free_gb}GB free)"
    fi

    record_health "healthy" "${percent}% used (${used_gb}GB), ${free_gb}GB free"
fi

# Log rotation: keep last 5000 lines
if [[ -f "$LOG_FILE" ]]; then
    line_count=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [[ $line_count -gt 5000 ]]; then
        tail -3000 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (was $line_count lines)"
    fi
fi
