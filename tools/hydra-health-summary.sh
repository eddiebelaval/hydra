#!/bin/bash
# hydra-health-summary.sh - Generate health report for briefing/Telegram
#
# Usage: hydra-health-summary.sh [format]
#   format: "brief" (default, for Telegram) or "full" (for briefing file)
#
# Reads latest system_health records and produces a human-readable summary.

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
FORMAT="${1:-brief}"

if [[ ! -f "$HYDRA_DB" ]]; then
    echo "Database not found"
    exit 1
fi

# Get latest check per component
LATEST_CHECKS=$(sqlite3 "$HYDRA_DB" "
    SELECT h.check_type, h.component, h.status, h.details, h.failure_count
    FROM system_health h
    INNER JOIN (
        SELECT check_type, component, MAX(check_time) as max_time
        FROM system_health
        GROUP BY check_type, component
    ) latest ON h.check_type = latest.check_type
        AND h.component = latest.component
        AND h.check_time = latest.max_time
    ORDER BY
        CASE h.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END,
        h.check_type;
" 2>/dev/null || echo "")

if [[ -z "$LATEST_CHECKS" ]]; then
    echo "No health data yet. Run: ~/.hydra/tools/hydra-heartbeat.sh"
    exit 0
fi

# Count by status
CRITICAL=$(echo "$LATEST_CHECKS" | grep -c "|critical|" || true)
WARNING=$(echo "$LATEST_CHECKS" | grep -c "|warning|" || true)
HEALTHY=$(echo "$LATEST_CHECKS" | grep -c "|healthy|" || true)
TOTAL=$((CRITICAL + WARNING + HEALTHY))

# Last check time
LAST_CHECK=$(sqlite3 "$HYDRA_DB" "SELECT MAX(check_time) FROM system_health;" 2>/dev/null || echo "unknown")

if [[ "$FORMAT" == "brief" ]]; then
    # Telegram-friendly compact format
    if [[ $CRITICAL -gt 0 ]]; then
        echo "System Health: CRITICAL"
    elif [[ $WARNING -gt 0 ]]; then
        echo "System Health: WARNING"
    else
        echo "System Health: ALL CLEAR"
    fi
    echo ""
    echo "$HEALTHY/$TOTAL healthy"
    if [[ $WARNING -gt 0 ]]; then echo "$WARNING warnings"; fi
    if [[ $CRITICAL -gt 0 ]]; then echo "$CRITICAL CRITICAL"; fi
    echo ""

    # Show non-healthy items
    echo "$LATEST_CHECKS" | while IFS='|' read -r check_type component status details failure_count; do
        if [[ "$status" == "critical" ]]; then
            echo "CRITICAL: $check_type/$component"
            echo "  $details"
        elif [[ "$status" == "warning" ]]; then
            echo "WARN: $check_type/$component"
            echo "  $details"
        fi
    done

    echo ""
    echo "Last check: $LAST_CHECK"

elif [[ "$FORMAT" == "full" ]]; then
    # Briefing markdown format
    if [[ $CRITICAL -gt 0 ]]; then
        echo "### System Health: CRITICAL"
    elif [[ $WARNING -gt 0 ]]; then
        echo "### System Health: NEEDS ATTENTION"
    else
        echo "### System Health: ALL CLEAR"
    fi
    echo ""
    echo "| Check | Component | Status | Details |"
    echo "|-------|-----------|--------|---------|"

    echo "$LATEST_CHECKS" | while IFS='|' read -r check_type component status details failure_count; do
        icon=""
        case "$status" in
            healthy) icon="OK" ;;
            warning) icon="WARN" ;;
            critical) icon="CRIT" ;;
        esac
        echo "| $check_type | $component | $icon | ${details:0:60} |"
    done

    echo ""
    echo "*Last check: $LAST_CHECK*"
fi
