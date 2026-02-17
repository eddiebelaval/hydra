#!/bin/bash
# hydra-costs.sh - HYDRA Cost Monitor
#
# Tracks spending across AI services and provides daily summaries.
#
# Usage:
#   hydra-costs.sh                  # Show today's costs
#   hydra-costs.sh fetch            # Fetch latest from APIs
#   hydra-costs.sh summary          # Weekly summary
#   hydra-costs.sh alert <amount>   # Set daily alert threshold

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
HYDRA_CONFIG="$HOME/.hydra/config"
DATE=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# ANTHROPIC COST FETCHER
# ============================================================================

fetch_anthropic() {
    local api_key="${ANTHROPIC_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        echo "Anthropic: No API key found"
        return 1
    fi

    # Anthropic doesn't have a public usage API yet
    # We'll estimate from Claude Code logs or use the console
    # For now, log a placeholder that can be manually updated

    echo "Anthropic: Check console.anthropic.com for usage"
    echo "  (Auto-fetch not yet available via API)"

    # Check if there's a manual entry for today
    local existing=$(sqlite3 "$HYDRA_DB" "SELECT cost_usd FROM cost_records WHERE date='$DATE' AND service='anthropic';" 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
        echo "  Today's recorded cost: \$$existing"
    fi
}

# ============================================================================
# PERPLEXITY COST FETCHER
# ============================================================================

fetch_perplexity() {
    local api_key="${PERPLEXITY_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        echo "Perplexity: No API key found"
        return 1
    fi

    echo "Perplexity: Check perplexity.ai/settings for usage"

    local existing=$(sqlite3 "$HYDRA_DB" "SELECT cost_usd FROM cost_records WHERE date='$DATE' AND service='perplexity';" 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
        echo "  Today's recorded cost: \$$existing"
    fi
}

# ============================================================================
# VERCEL COST FETCHER
# ============================================================================

fetch_vercel() {
    local token="${VERCEL_TOKEN:-}"

    if [[ -z "$token" ]]; then
        echo "Vercel: No token found"
        return 1
    fi

    # Vercel API for usage (requires team slug for paid features)
    echo "Vercel: Check vercel.com/dashboard for usage"

    local existing=$(sqlite3 "$HYDRA_DB" "SELECT cost_usd FROM cost_records WHERE date='$DATE' AND service='vercel';" 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
        echo "  Today's recorded cost: \$$existing"
    fi
}

# ============================================================================
# LOG COST MANUALLY
# ============================================================================

log_cost() {
    local service="$1"
    local amount="$2"
    local tokens_in="${3:-0}"
    local tokens_out="${4:-0}"
    local requests="${5:-0}"

    local id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Upsert: delete existing for today's service, then insert
    sqlite3 "$HYDRA_DB" "
        DELETE FROM cost_records WHERE date='$DATE' AND service='$service';
        INSERT INTO cost_records (id, date, service, cost_usd, tokens_input, tokens_output, requests)
        VALUES ('$id', '$DATE', '$service', $amount, $tokens_in, $tokens_out, $requests);
    "

    echo -e "${GREEN}Logged:${NC} $service = \$$amount for $DATE"
}

# ============================================================================
# SHOW TODAY'S COSTS
# ============================================================================

show_today() {
    echo -e "${BLUE}=== HYDRA Cost Monitor ===${NC}"
    echo -e "Date: $DATE\n"

    local total=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM cost_records WHERE date='$DATE';" 2>/dev/null || echo "0")

    echo -e "${YELLOW}Today's Costs:${NC}"
    sqlite3 -column -header "$HYDRA_DB" "
        SELECT service, printf('\$%.2f', cost_usd) as cost,
               COALESCE(tokens_input, 0) || '/' || COALESCE(tokens_output, 0) as 'in/out tokens',
               COALESCE(requests, 0) as requests
        FROM cost_records
        WHERE date='$DATE'
        ORDER BY cost_usd DESC;
    " 2>/dev/null || echo "  No costs recorded yet"

    echo ""
    echo -e "${GREEN}Total: \$$(printf '%.2f' $total)${NC}"

    # Show threshold warning if set
    local threshold=$(cat "$HYDRA_CONFIG/cost-threshold.txt" 2>/dev/null || echo "")
    if [[ -n "$threshold" ]]; then
        if (( $(echo "$total > $threshold" | bc -l) )); then
            echo -e "${RED}WARNING: Exceeded daily threshold of \$$threshold${NC}"
        else
            echo -e "Daily threshold: \$$threshold"
        fi
    fi
}

# ============================================================================
# WEEKLY SUMMARY
# ============================================================================

show_summary() {
    echo -e "${BLUE}=== Weekly Cost Summary ===${NC}\n"

    sqlite3 -column -header "$HYDRA_DB" "
        SELECT date,
               printf('\$%.2f', total_cost) as total,
               services,
               total_requests as requests
        FROM v_daily_costs
        WHERE date >= date('now', '-7 days')
        ORDER BY date DESC;
    " 2>/dev/null || echo "No data yet"

    echo ""
    local week_total=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM cost_records WHERE date >= date('now', '-7 days');" 2>/dev/null || echo "0")
    local month_total=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM cost_records WHERE date >= date('now', '-30 days');" 2>/dev/null || echo "0")

    echo -e "${GREEN}7-day total:  \$$(printf '%.2f' $week_total)${NC}"
    echo -e "${GREEN}30-day total: \$$(printf '%.2f' $month_total)${NC}"
}

# ============================================================================
# SET ALERT THRESHOLD
# ============================================================================

set_threshold() {
    local amount="$1"
    mkdir -p "$HYDRA_CONFIG"
    echo "$amount" > "$HYDRA_CONFIG/cost-threshold.txt"
    echo -e "${GREEN}Daily cost alert threshold set to \$$amount${NC}"
}

# ============================================================================
# TELEGRAM-FRIENDLY OUTPUT
# ============================================================================

telegram_summary() {
    local total=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM cost_records WHERE date='$DATE';" 2>/dev/null || echo "0")
    local week_total=$(sqlite3 "$HYDRA_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM cost_records WHERE date >= date('now', '-7 days');" 2>/dev/null || echo "0")

    local breakdown=$(sqlite3 "$HYDRA_DB" "
        SELECT service || ': \$' || printf('%.2f', cost_usd)
        FROM cost_records
        WHERE date='$DATE'
        ORDER BY cost_usd DESC;
    " 2>/dev/null | tr '\n' ', ' | sed 's/, $//')

    if [[ -z "$breakdown" ]]; then
        breakdown="No costs recorded yet"
    fi

    echo "Cost Report - $DATE

Today: \$$(printf '%.2f' $total)
$breakdown

7-day: \$$(printf '%.2f' $week_total)"
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    fetch)
        echo -e "${BLUE}Fetching costs from services...${NC}\n"
        fetch_anthropic
        echo ""
        fetch_perplexity
        echo ""
        fetch_vercel
        ;;

    log)
        if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]]; then
            echo "Usage: hydra-costs.sh log <service> <amount> [tokens_in] [tokens_out] [requests]"
            echo "Example: hydra-costs.sh log anthropic 2.50 10000 5000 25"
            exit 1
        fi
        log_cost "$2" "$3" "${4:-0}" "${5:-0}" "${6:-0}"
        ;;

    summary)
        show_summary
        ;;

    alert|threshold)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: hydra-costs.sh alert <daily_threshold>"
            echo "Example: hydra-costs.sh alert 10.00"
            exit 1
        fi
        set_threshold "$2"
        ;;

    telegram)
        telegram_summary
        ;;

    help|--help|-h)
        echo "HYDRA Cost Monitor"
        echo ""
        echo "Commands:"
        echo "  (none)           Show today's costs"
        echo "  fetch            Check APIs for latest usage"
        echo "  log <svc> <amt>  Manually log a cost"
        echo "  summary          Show weekly summary"
        echo "  alert <amount>   Set daily spending alert"
        echo "  telegram         Output for Telegram"
        echo ""
        echo "Services: anthropic, perplexity, vercel, openai, other"
        ;;

    *)
        show_today
        ;;
esac
