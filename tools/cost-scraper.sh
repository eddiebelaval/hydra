#!/bin/bash
# cost-scraper.sh - Quick cost logging from AI service dashboards
#
# Opens dashboards in your browser and prompts for cost input.
# Also supports Telegram-based cost logging.
#
# Usage:
#   cost-scraper.sh                 # Interactive: open dashboards + prompt
#   cost-scraper.sh quick           # Just open dashboards (you log via Telegram)
#   cost-scraper.sh remind          # Send Telegram reminder to log costs
#   cost-scraper.sh --schedule      # Set up daily reminder at 8 PM

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
COST_TOOL="$HYDRA_ROOT/tools/hydra-costs.sh"
NOTIFY_TOOL="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-costs"
DATE=$(date +%Y-%m-%d)

mkdir -p "$LOG_DIR"

# Dashboard URLs
ANTHROPIC_URL="https://console.anthropic.com/settings/usage"
VERCEL_URL="https://vercel.com/~/usage"
PERPLEXITY_URL="https://www.perplexity.ai/settings/api"

# ============================================================================
# OPEN DASHBOARDS
# ============================================================================

open_dashboards() {
    echo "Opening cost dashboards in your browser..."
    echo ""

    echo "1. Anthropic Console (Claude API)"
    open "$ANTHROPIC_URL"
    sleep 1

    echo "2. Vercel Dashboard"
    open "$VERCEL_URL"
    sleep 1

    echo "3. Perplexity Settings"
    open "$PERPLEXITY_URL"

    echo ""
    echo "Dashboards opened in your default browser."
}

# ============================================================================
# INTERACTIVE COST INPUT
# ============================================================================

interactive_input() {
    open_dashboards

    echo ""
    echo "=== Enter costs from each dashboard ==="
    echo "(Press Enter to skip, type 'done' when finished)"
    echo ""

    # Anthropic
    read -p "Anthropic cost today (\$): " anthropic_cost
    if [[ -n "$anthropic_cost" ]] && [[ "$anthropic_cost" != "done" ]]; then
        "$COST_TOOL" log anthropic "$anthropic_cost"
    fi

    # Vercel
    if [[ "$anthropic_cost" != "done" ]]; then
        read -p "Vercel cost today (\$): " vercel_cost
        if [[ -n "$vercel_cost" ]] && [[ "$vercel_cost" != "done" ]]; then
            "$COST_TOOL" log vercel "$vercel_cost"
        fi
    fi

    # Perplexity
    if [[ "${vercel_cost:-}" != "done" ]]; then
        read -p "Perplexity cost today (\$): " perplexity_cost
        if [[ -n "$perplexity_cost" ]] && [[ "$perplexity_cost" != "done" ]]; then
            "$COST_TOOL" log perplexity "$perplexity_cost"
        fi
    fi

    echo ""
    echo "=== Today's Costs ==="
    "$COST_TOOL"
}

# ============================================================================
# SEND TELEGRAM REMINDER
# ============================================================================

send_reminder() {
    local current=$("$COST_TOOL" telegram)

    local msg="Time to log today's costs!

$current

Reply with costs like:
'log anthropic 5.00'
'log vercel 0'

Or check dashboards:
- console.anthropic.com
- vercel.com/~/usage"

    if [[ -x "$NOTIFY_TOOL" ]]; then
        "$NOTIFY_TOOL" normal "HYDRA Cost Reminder" "$msg"
        echo "Reminder sent to Telegram"
    else
        echo "Notify tool not found"
    fi
}

# ============================================================================
# TELEGRAM COST LOGGING (for use from listener)
# ============================================================================

log_from_telegram() {
    # Parse: "log anthropic 5.00" or "anthropic 5.00"
    local input="$*"
    local service=$(echo "$input" | awk '{print $1}')
    local amount=$(echo "$input" | awk '{print $2}')

    if [[ -z "$service" ]] || [[ -z "$amount" ]]; then
        echo "Usage: log <service> <amount>"
        echo "Example: log anthropic 5.00"
        return 1
    fi

    "$COST_TOOL" log "$service" "$amount"
}

# ============================================================================
# SCHEDULE DAILY REMINDER
# ============================================================================

setup_schedule() {
    local plist_file="$HOME/Library/LaunchAgents/com.hydra.cost-reminder.plist"

    cat > "$plist_file" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hydra.cost-reminder</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/eddiebelaval/.hydra/tools/cost-scraper.sh</string>
        <string>remind</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>20</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/eddiebelaval</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/eddiebelaval/Library/Logs/claude-automation/hydra-costs/reminder.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/eddiebelaval/Library/Logs/claude-automation/hydra-costs/reminder-error.log</string>
</dict>
</plist>
EOF

    launchctl unload "$plist_file" 2>/dev/null || true
    launchctl load "$plist_file"

    echo "Daily cost reminder scheduled for 8 PM"
    echo "You'll get a Telegram message to log your costs"
    echo ""
    echo "Plist: $plist_file"
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-interactive}" in
    interactive|"")
        interactive_input
        ;;
    quick|open)
        open_dashboards
        echo ""
        echo "Log costs via Telegram: 'log anthropic 5.00'"
        ;;
    remind|reminder)
        send_reminder
        ;;
    log)
        shift
        log_from_telegram "$@"
        ;;
    --schedule|schedule)
        setup_schedule
        ;;
    --help|-h|help)
        echo "HYDRA Cost Scraper"
        echo ""
        echo "Usage:"
        echo "  cost-scraper.sh              Interactive: open dashboards + prompt"
        echo "  cost-scraper.sh quick        Just open dashboards"
        echo "  cost-scraper.sh remind       Send Telegram reminder"
        echo "  cost-scraper.sh log <svc> <amt>  Log a cost"
        echo "  cost-scraper.sh --schedule   Set up daily 8 PM reminder"
        echo ""
        echo "Services: anthropic, vercel, perplexity, openai, other"
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run with --help for usage"
        exit 1
        ;;
esac
