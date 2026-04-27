#!/bin/bash
# wellness-daemon.sh - HYDRA Wellness & Boundary System
#
# Runs every 15 minutes via launchd. Checks current time against a
# schedule of wellness reminders and sends the right message via
# notify-eddie.sh (Telegram + macOS notification).
#
# MORNING FLOW (event-driven, not clock-driven):
#   07:30  Gym checkpoint — creates conversation thread, waits for proof
#          Eddie replies (photo or text) → gym handler triggers planner
#   11:00  Fallback — if gym not cleared, fires planner anyway
#
# WEEKDAY SCHEDULE (clock-driven):
#   09:30  Water
#   11:00  Water (+ gym fallback if needed)
#   12:30  Lunch (30 min away from screen)
#   14:00  Water
#   15:00  Movement break (15 min walk)
#   16:30  Water
#   18:30  Dinner
#   19:30  Water (last of day)
#   21:30  Shutdown warning (30 min ritual)
#   22:00  Hard stop
#   22:20  "You're still here" check
#
# FRIDAY 21:30: Special Friday shutdown (queue weekend automations)
#
# WEEKEND:
#   09:00  "No terminal today. Automations running."
#
# State: ~/.hydra/state/wellness-state.json
#   Tracks sent slots, gym phase (pre_gym/gym_cleared), and checkpoint thread.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
STATE_FILE="$HYDRA_ROOT/state/wellness-state.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-wellness"
LOG_FILE="$LOG_DIR/wellness.log"

TODAY=$(date +%Y-%m-%d)
NOW_H=$(date +%H)
NOW_M=$(date +%M)
NOW_MIN=$((10#$NOW_H * 60 + 10#$NOW_M))
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
DAY_NAME=$(date +%A)

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

# Load or reset daily state (preserves phase tracking)
if [[ -f "$STATE_FILE" ]]; then
    STATE_DATE=$(python3 -c "
import json
try:
    print(json.load(open('$STATE_FILE')).get('date',''))
except:
    print('')
" 2>/dev/null || echo "")
    if [[ "$STATE_DATE" != "$TODAY" ]]; then
        echo "{\"date\":\"$TODAY\",\"sent\":[],\"phase\":\"pre_gym\",\"gym_cleared_at\":null,\"gym_thread_id\":null}" > "$STATE_FILE"
        log "State reset for new day: $TODAY"
    fi
else
    echo "{\"date\":\"$TODAY\",\"sent\":[],\"phase\":\"pre_gym\",\"gym_cleared_at\":null,\"gym_thread_id\":null}" > "$STATE_FILE"
    log "State file created: $TODAY"
fi

# Read current phase
GYM_PHASE=$(python3 -c "
import json
try:
    print(json.load(open('$STATE_FILE')).get('phase','pre_gym'))
except:
    print('pre_gym')
" 2>/dev/null || echo "pre_gym")

# Check if a slot was already sent today
already_sent() {
    python3 -c "
import json
state = json.load(open('$STATE_FILE'))
print('yes' if '$1' in state.get('sent',[]) else 'no')
" 2>/dev/null || echo "no"
}

# Mark a slot as sent
mark_sent() {
    python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state.setdefault('sent',[]).append('$1')
with open('$STATE_FILE','w') as f:
    json.dump(state, f)
" 2>/dev/null || true
}

# ============================================================================
# TIME MATCHING
# ============================================================================

# Check if current time is within +/- 10 min of target HHMM
in_window() {
    local target="$1"
    local t_h="${target:0:2}"
    local t_m="${target:2:2}"
    local target_min=$((10#$t_h * 60 + 10#$t_m))
    local diff=$((NOW_MIN - target_min))
    if [[ $diff -lt 0 ]]; then diff=$((-diff)); fi
    [[ $diff -le 10 ]]
}

# ============================================================================
# SEND HELPER
# ============================================================================

send() {
    local slot="$1"
    local priority="$2"
    local title="$3"
    local message="$4"

    if [[ $(already_sent "$slot") == "yes" ]]; then
        return 0
    fi

    log "Sending [$slot] $title ($priority)"
    "$NOTIFY" "$priority" "$title" "$message" "" 2>/dev/null || true
    mark_sent "$slot"
}

# Send with entity tracking (for conversation threads)
send_with_thread() {
    local slot="$1"
    local priority="$2"
    local title="$3"
    local message="$4"
    local entity_type="$5"
    local entity_id="$6"

    if [[ $(already_sent "$slot") == "yes" ]]; then
        return 0
    fi

    log "Sending [$slot] $title ($priority) with thread=$entity_id"
    "$NOTIFY" "$priority" "$title" "$message" "" \
        --entity-type "$entity_type" --entity-id "$entity_id" 2>/dev/null || true
    mark_sent "$slot"
}

# ============================================================================
# WEEKEND MODE
# ============================================================================

if [[ "$DAY_OF_WEEK" -ge 6 ]]; then
    if in_window "0900"; then
        send "weekend" "urgent" "Weekend Mode" "It's $DAY_NAME. No terminal today.

Your automations are running. HYDRA has it covered.

Go outside. See a friend. Rest.
The work will be better on Monday because you stopped."
    fi
    log "Weekend mode active — skipping weekday schedule"
    exit 0
fi

# ============================================================================
# MORNING: GYM CHECKPOINT (event-driven)
# ============================================================================

# 07:30 — Create gym checkpoint conversation thread
if in_window "0730" && [[ "$GYM_PHASE" == "pre_gym" ]]; then
    if [[ $(already_sent "gym_checkpoint") == "no" ]]; then
        # Create conversation thread for gym proof
        THREAD_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "gym-$(date +%s)")

        # Thread expires at 11:00 AM (fallback window)
        EXPIRES=$(date -v+210M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

        sqlite3 "$HYDRA_DB" "
            INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
            VALUES ('$THREAD_ID', 'gym_checkpoint', 'awaiting_input', '{\"date\":\"$TODAY\"}', '$EXPIRES');
        " 2>/dev/null || true

        # Store thread ID in wellness state
        python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state['gym_thread_id'] = '$THREAD_ID'
with open('$STATE_FILE','w') as f:
    json.dump(state, f)
" 2>/dev/null || true

        # Send with entity tracking so replies route to gym handler
        send_with_thread "gym_checkpoint" "urgent" "Morning Routine" \
            "Walk the dog. Then gym.

Reply to this message when you're done — photo or just say 'done'.

Your priorities are waiting on the other side." \
            "conversation_thread" "$THREAD_ID"

        log "Gym checkpoint thread created: $THREAD_ID"
    fi
fi

# 11:00 — Gym fallback: if still pre_gym, fire planner anyway
if in_window "1100" && [[ "$GYM_PHASE" == "pre_gym" ]]; then
    if [[ $(already_sent "gym_fallback") == "no" ]]; then
        log "Gym fallback triggered — no proof by 11:00"
        send "gym_fallback" "urgent" "Gym Fallback" "No gym today? That's OK — life happens.

Firing your priorities now."

        # Trigger morning planner directly
        "$HYDRA_ROOT/daemons/morning-planner.sh" 2>/dev/null &

        # Update phase so we don't keep checking
        python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state['phase'] = 'gym_skipped'
with open('$STATE_FILE','w') as f:
    json.dump(state, f)
" 2>/dev/null || true
    fi
fi

# ============================================================================
# WEEKDAY SCHEDULE (clock-driven)
# ============================================================================

# 09:30 — Water
if in_window "0930"; then
    send "0930" "normal" "Hydration" "Water check."
fi

# 11:00 — Water (in addition to possible fallback above)
if in_window "1100"; then
    send "1100" "normal" "Hydration" "Water check."
fi

# 12:30 — Lunch
if in_window "1230"; then
    send "1230" "urgent" "Lunch" "Close the laptop. Eat real food.

30 minutes minimum. Away from the screen."
fi

# 14:00 — Water
if in_window "1400"; then
    send "1400" "normal" "Hydration" "Water check."
fi

# 15:00 — Movement break
if in_window "1500"; then
    send "1500" "high" "Movement" "Stand up. Walk outside. 15 minutes.

Your code will be there when you get back."
fi

# 16:30 — Water
if in_window "1630"; then
    send "1630" "normal" "Hydration" "Water check."
fi

# 18:30 — Dinner
if in_window "1830"; then
    send "1830" "urgent" "Dinner" "Dinner time. Step away and eat.

You've been at it all day. Refuel."
fi

# 19:30 — Last water
if in_window "1930"; then
    send "1930" "normal" "Hydration" "Last water check of the day."
fi

# 21:30 — Shutdown warning (Friday gets special message)
if in_window "2130"; then
    if [[ "$DAY_OF_WEEK" -eq 5 ]]; then
        send "2130" "urgent" "Friday Shutdown" "Friday shutdown. 30 minutes.

1. Commit your work (even WIP)
2. Write Monday's first task
3. Queue weekend automations for HYDRA
4. Close the terminal

Your week is done."
    else
        send "2130" "urgent" "Shutdown Warning" "Shutdown sequence. 30 minutes.

1. Commit what you have (even WIP)
2. Write tomorrow's first task
3. Queue overnight automations
4. Close the terminal"
    fi
fi

# 22:00 — Hard stop
if in_window "2200"; then
    send "2200" "urgent" "Hard Stop" "Terminal closed. Go be a person.

The overnight shift is running. Nothing is lost."
fi

# 22:20 — Still here check (offset from 22:00 to avoid window overlap)
if in_window "2220"; then
    send "2220" "urgent" "Boundary Check" "You're still here."
fi

log "Wellness check complete (time=$NOW_H:$NOW_M, day=$DAY_NAME, phase=$GYM_PHASE)"
