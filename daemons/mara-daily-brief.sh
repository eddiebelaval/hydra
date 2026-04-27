#!/bin/bash
# mara-daily-brief.sh - MARA's Daily Push Brief
#
# Runs daily at 8:30 AM via launchd (after morning planner at 8:00 AM).
# Reads WEEKLY_PLAN.md, finds today's tasks, checks execution-log.md
# for what MARA already did autonomously, and pushes a Telegram brief.
#
# This is the HUMAN PERSISTENCE layer — Eddie doesn't need to remember
# any commands. MARA comes to him.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
LOG_DIR="$HOME/Library/Logs/claude-automation/mara-daily-brief"
LOG_FILE="$LOG_DIR/mara-brief.log"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
DAY_NUM=$(date +%d)
MONTH_NAME=$(date +%b)

# Parallax distro workspace
DISTRO="$HOME/Development/id8/products/parallax/workspace/distro"
WEEKLY_PLAN="$DISTRO/WEEKLY_PLAN.md"
EXEC_LOG="$DISTRO/execution-log.md"
CAMPAIGN_REMINDERS="$DISTRO/CAMPAIGN_REMINDERS.md"
AGENCY_SOP="$DISTRO/AGENCY_SOP.md"

# Load Telegram env
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== MARA daily brief started ==="

# ============================================================================
# DUPLICATE PREVENTION
# ============================================================================

MARA_SENT_FILE="$HYDRA_ROOT/state/mara-brief-sent-$DATE.flag"
if [[ -f "$MARA_SENT_FILE" ]]; then
    log "Already sent today. Skipping."
    exit 0
fi

# ============================================================================
# WEEKEND CHECK
# ============================================================================

DOW=$(date +%u)  # 1=Monday, 7=Sunday
if [[ "$DOW" -eq 6 || "$DOW" -eq 7 ]]; then
    log "Weekend — no MARA brief."
    exit 0
fi

# ============================================================================
# BUILD THE BRIEF
# ============================================================================

BRIEF=""

# Header
BRIEF="<b>MARA — $DAY_NAME $MONTH_NAME $DAY_NUM</b>"$'\n'$'\n'

# Check if weekly plan exists
if [[ ! -f "$WEEKLY_PLAN" ]]; then
    BRIEF+="No weekly plan found. Run /gtm to set one."$'\n'
    "$NOTIFY" "urgent" "MARA" "$BRIEF"
    touch "$MARA_SENT_FILE"
    log "No weekly plan. Sent alert."
    exit 0
fi

# Extract today's section from WEEKLY_PLAN.md
# Look for lines matching today's day name (e.g., "## Monday Mar 17")
TODAY_SECTION=$(awk -v day="$DAY_NAME" '
    /^## / && $0 ~ day { found=1; next }
    /^## / && found { found=0 }
    found { print }
' "$WEEKLY_PLAN" 2>/dev/null)

if [[ -n "$TODAY_SECTION" ]]; then
    # Extract Eddie's actions
    EDDIE_ACTIONS=$(echo "$TODAY_SECTION" | grep -E "^[0-9]+\." | head -5)
    MARA_ACTIONS=$(echo "$TODAY_SECTION" | sed -n '/MARA Does/,/^$/p' | grep -E "^-" | head -5)

    if [[ -n "$EDDIE_ACTIONS" ]]; then
        BRIEF+="<b>YOUR ACTIONS TODAY:</b>"$'\n'
        BRIEF+="$EDDIE_ACTIONS"$'\n'$'\n'
    fi

    if [[ -n "$MARA_ACTIONS" ]]; then
        BRIEF+="<b>MARA IS HANDLING:</b>"$'\n'
        BRIEF+="$MARA_ACTIONS"$'\n'$'\n'
    fi
else
    BRIEF+="No tasks scheduled for today."$'\n'$'\n'
fi

# Check execution log for what MARA already did
if [[ -f "$EXEC_LOG" ]]; then
    RECENT_EXEC=$(grep "$DATE" "$EXEC_LOG" 2>/dev/null | tail -3 || true)
    if [[ -n "$RECENT_EXEC" ]]; then
        BRIEF+="<b>ALREADY DONE:</b>"$'\n'
        BRIEF+="$RECENT_EXEC"$'\n'$'\n'
    fi
fi

# Check campaign reminders for overdue items
if [[ -f "$CAMPAIGN_REMINDERS" ]]; then
    OVERDUE=$(grep -E "^\- \[ \]" "$CAMPAIGN_REMINDERS" | head -3 || true)
    if [[ -n "$OVERDUE" ]]; then
        OVERDUE_COUNT=$(grep -c "^\- \[ \]" "$CAMPAIGN_REMINDERS" 2>/dev/null || echo "0")
        BRIEF+="<b>PENDING ACTIONS:</b> $OVERDUE_COUNT items"$'\n'$'\n'
    fi
fi

# Autonomous posting status
POSTER_FLAG="$HYDRA_ROOT/state/mara-posted-$DATE.flag"
SKIP_FLAG="$HYDRA_ROOT/state/mara-skip-week-$(date +%V).flag"
SUSPEND_FLAG="$HYDRA_ROOT/state/mara-suspended.flag"

if [[ -f "$SUSPEND_FLAG" ]]; then
    BRIEF+="<b>POSTING: SUSPENDED</b>"$'\n'$'\n'
elif [[ -f "$POSTER_FLAG" ]]; then
    BRIEF+="<b>POSTING:</b> Already posted today."$'\n'$'\n'
elif [[ -f "$SKIP_FLAG" ]] && [[ "$(cat "$SKIP_FLAG")" == "$DOW" ]]; then
    BRIEF+="<b>POSTING:</b> Skip day (anti-bot)."$'\n'$'\n'
elif [[ "$DOW" -eq 6 || "$DOW" -eq 7 ]]; then
    BRIEF+="<b>POSTING:</b> Weekend, no posts."$'\n'$'\n'
else
    READY_COUNT=$(ls "$DISTRO/ready-to-post"/*.md 2>/dev/null | wc -l | tr -d ' ')
    BRIEF+="<b>POSTING:</b> Daemon will fire at 9 AM + jitter. $READY_COUNT pieces in pipeline."$'\n'$'\n'
fi

# Day-specific additions
case "$DOW" in
    1)  # Monday
        BRIEF+="<b>WAR ROOM TODAY.</b>"$'\n'
        BRIEF+="When you're ready: /gtm"$'\n'
        ;;
    3)  # Wednesday
        BRIEF+="Mid-week check: /gtm check"$'\n'
        ;;
    5)  # Friday
        BRIEF+="Weekly recap: /gtm recap"$'\n'
        BRIEF+="MARA auto-recap fires at 4 PM."$'\n'
        ;;
esac

# ============================================================================
# SEND
# ============================================================================

log "Sending brief: $(echo "$BRIEF" | wc -l) lines"
"$NOTIFY" "urgent" "MARA" "$BRIEF"

touch "$MARA_SENT_FILE"
log "Brief sent successfully."
