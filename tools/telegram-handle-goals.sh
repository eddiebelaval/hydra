#!/bin/bash
# telegram-handle-goals.sh - Handle goal commands from Telegram
#
# Usage: telegram-handle-goals.sh <action> [args...]
#
# Actions:
#   list                              -> show all active goals by horizon
#   add <horizon> <description>       -> create new goal
#   update <keyword> <progress> [note] -> update goal progress
#   drop <keyword>                    -> mark goal as dropped
#   achieved <keyword>                -> mark goal as achieved
#   revise <keyword> <new_desc>       -> revise goal description

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
NOTIFY="$HOME/.hydra/daemons/notify-eddie.sh"
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%Y-W%V)
MONTH=$(date +%Y-%m)
QUARTER="Q$(( ($(date +%-m) - 1) / 3 + 1 ))-$(date +%Y)"

ACTION="${1:-list}"
shift || true

# Helper: find goal by keyword match (fuzzy search on description)
find_goal() {
    local keyword="$1"
    sqlite3 "$HYDRA_DB" "
        SELECT id, horizon, description, progress, status
        FROM goals
        WHERE LOWER(description) LIKE '%$(echo "$keyword" | tr '[:upper:]' '[:lower:]')%'
        AND status IN ('active', 'carried')
        LIMIT 1;
    " 2>/dev/null
}

case "$ACTION" in
    list)
        MSG="Your Goals\n\n"

        # Quarterly
        Q_GOALS=$(sqlite3 "$HYDRA_DB" "
            SELECT description || ' [' || progress || '%] (' || status || ')'
            FROM goals WHERE horizon = 'quarterly' AND status IN ('active','carried')
            ORDER BY progress DESC;
        " 2>/dev/null || echo "")
        if [[ -n "$Q_GOALS" ]]; then
            MSG+="QUARTERLY ($QUARTER)\n"
            while IFS= read -r line; do
                MSG+="  $line\n"
            done <<< "$Q_GOALS"
            MSG+="\n"
        fi

        # Monthly
        M_GOALS=$(sqlite3 "$HYDRA_DB" "
            SELECT description || ' [' || progress || '%] (' || status || ')'
            FROM goals WHERE horizon = 'monthly' AND period = '$MONTH' AND status IN ('active','carried')
            ORDER BY progress DESC;
        " 2>/dev/null || echo "")
        if [[ -n "$M_GOALS" ]]; then
            MSG+="MONTHLY ($MONTH)\n"
            while IFS= read -r line; do
                MSG+="  $line\n"
            done <<< "$M_GOALS"
            MSG+="\n"
        fi

        # Weekly
        W_GOALS=$(sqlite3 "$HYDRA_DB" "
            SELECT description || ' [' || progress || '%] (' || status || ')'
            FROM goals WHERE horizon = 'weekly' AND period = '$WEEK' AND status IN ('active','carried')
            ORDER BY progress DESC;
        " 2>/dev/null || echo "")
        if [[ -n "$W_GOALS" ]]; then
            MSG+="WEEKLY ($WEEK)\n"
            while IFS= read -r line; do
                MSG+="  $line\n"
            done <<< "$W_GOALS"
        fi

        if [[ "$MSG" == "Your Goals\n\n" ]]; then
            MSG+="No active goals set."
        fi

        echo -e "$MSG"
        ;;

    add)
        HORIZON="${1:-monthly}"
        shift || true
        DESC="$*"

        if [[ -z "$DESC" ]]; then
            echo "Usage: goal add <horizon>: <description>"
            exit 1
        fi

        # Auto-derive period
        case "$HORIZON" in
            quarterly) PERIOD="$QUARTER" ;;
            monthly) PERIOD="$MONTH" ;;
            weekly) PERIOD="$WEEK" ;;
            *) PERIOD="$MONTH"; HORIZON="monthly" ;;
        esac

        GOAL_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goals (id, horizon, period, description, status, progress, category)
            VALUES ('$GOAL_ID', '$HORIZON', '$PERIOD', '$(echo "$DESC" | sed "s/'/''/g")', 'active', 0, 'product');
        "

        # Log check-in
        CHECKIN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
            VALUES ('$CHECKIN_ID', '$GOAL_ID', '$DATE', 0, 'Goal created via Telegram', 'telegram');
        "

        echo "Added $HORIZON goal: $DESC"
        ;;

    update)
        KEYWORD="${1:-}"
        PROGRESS="${2:-}"
        shift 2 || true
        NOTE="$*"

        if [[ -z "$KEYWORD" ]] || [[ -z "$PROGRESS" ]]; then
            echo "Usage: goal update <keyword>: <progress>% [note]"
            exit 1
        fi

        RESULT=$(find_goal "$KEYWORD")
        if [[ -z "$RESULT" ]]; then
            echo "No active goal matching '$KEYWORD'"
            exit 1
        fi

        GOAL_ID=$(echo "$RESULT" | cut -d'|' -f1)
        OLD_DESC=$(echo "$RESULT" | cut -d'|' -f3)
        OLD_PROGRESS=$(echo "$RESULT" | cut -d'|' -f4)

        sqlite3 "$HYDRA_DB" "UPDATE goals SET progress = $PROGRESS WHERE id = '$GOAL_ID';"

        # Log check-in
        CHECKIN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        NOTE_ESCAPED=$(echo "${NOTE:-Progress update via Telegram}" | sed "s/'/''/g")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
            VALUES ('$CHECKIN_ID', '$GOAL_ID', '$DATE', $PROGRESS, '$NOTE_ESCAPED', 'telegram');
        "

        echo "Updated: $OLD_DESC ($OLD_PROGRESS% -> $PROGRESS%)"
        ;;

    drop)
        KEYWORD="$*"
        RESULT=$(find_goal "$KEYWORD")
        if [[ -z "$RESULT" ]]; then
            echo "No active goal matching '$KEYWORD'"
            exit 1
        fi

        GOAL_ID=$(echo "$RESULT" | cut -d'|' -f1)
        OLD_DESC=$(echo "$RESULT" | cut -d'|' -f3)

        sqlite3 "$HYDRA_DB" "UPDATE goals SET status = 'dropped' WHERE id = '$GOAL_ID';"

        CHECKIN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
            VALUES ('$CHECKIN_ID', '$GOAL_ID', '$DATE', NULL, 'Dropped via Telegram', 'telegram');
        "

        echo "Dropped: $OLD_DESC"
        ;;

    achieved)
        KEYWORD="$*"
        RESULT=$(find_goal "$KEYWORD")
        if [[ -z "$RESULT" ]]; then
            echo "No active goal matching '$KEYWORD'"
            exit 1
        fi

        GOAL_ID=$(echo "$RESULT" | cut -d'|' -f1)
        OLD_DESC=$(echo "$RESULT" | cut -d'|' -f3)

        sqlite3 "$HYDRA_DB" "UPDATE goals SET status = 'achieved', progress = 100, achieved_at = datetime('now') WHERE id = '$GOAL_ID';"

        CHECKIN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
            VALUES ('$CHECKIN_ID', '$GOAL_ID', '$DATE', 100, 'Achieved via Telegram', 'telegram');
        "

        echo "Achieved: $OLD_DESC"
        ;;

    revise)
        KEYWORD="${1:-}"
        shift || true
        NEW_DESC="$*"

        if [[ -z "$KEYWORD" ]] || [[ -z "$NEW_DESC" ]]; then
            echo "Usage: goal change <keyword>: <new description>"
            exit 1
        fi

        RESULT=$(find_goal "$KEYWORD")
        if [[ -z "$RESULT" ]]; then
            echo "No active goal matching '$KEYWORD'"
            exit 1
        fi

        GOAL_ID=$(echo "$RESULT" | cut -d'|' -f1)
        OLD_DESC=$(echo "$RESULT" | cut -d'|' -f3)

        NEW_DESC_ESCAPED=$(echo "$NEW_DESC" | sed "s/'/''/g")
        sqlite3 "$HYDRA_DB" "UPDATE goals SET description = '$NEW_DESC_ESCAPED', status = 'revised' WHERE id = '$GOAL_ID';"

        # Create new active goal with revised-from link
        NEW_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
        HORIZON=$(echo "$RESULT" | cut -d'|' -f2)
        sqlite3 "$HYDRA_DB" "
            INSERT INTO goals (id, horizon, period, description, status, progress, revised_from)
            SELECT '$NEW_ID', horizon, period, '$NEW_DESC_ESCAPED', 'active', progress, '$GOAL_ID'
            FROM goals WHERE id = '$GOAL_ID';
        "

        echo "Revised: '$OLD_DESC' -> '$NEW_DESC'"
        ;;

    *)
        echo "Unknown goal action: $ACTION
Commands: goals, goal add, goal update, goal drop, goal done, goal change"
        ;;
esac
