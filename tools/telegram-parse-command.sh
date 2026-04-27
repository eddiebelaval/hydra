#!/bin/bash
# telegram-parse-command.sh - Parse Telegram messages into HYDRA commands
#
# Usage: telegram-parse-command.sh "message text"
#
# Outputs JSON: {"type": "...", "command": "...", "args": [...], "raw": "..."}
#
# Supported commands:
#   status              -> {"type": "status"}
#   tasks               -> {"type": "tasks", "args": []}
#   tasks @forge        -> {"type": "tasks", "args": ["forge"]}
#   standup             -> {"type": "standup"}
#   agents              -> {"type": "agents"}
#   @forge fix auth bug -> {"type": "mention", "args": ["forge", "fix auth bug"]}
#   approve 12          -> {"type": "approve", "args": ["12"]}
#   reject 12 "reason"  -> {"type": "reject", "args": ["12", "reason"]}
#   complete 12         -> {"type": "complete", "args": ["12"]}
#   help                -> {"type": "help"}
#   (unknown)           -> {"type": "unknown", "raw": "..."}

set -euo pipefail

INPUT="${1:-}"

if [[ -z "$INPUT" ]]; then
    echo '{"type": "empty", "raw": ""}'
    exit 0
fi

# Normalize: lowercase, trim whitespace
NORMALIZED=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# JSON escape helper
json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null | sed 's/^"//;s/"$//'
}

RAW_ESCAPED=$(json_escape "$INPUT")

# ============================================================================
# COMMAND MATCHING
# ============================================================================

# greet (hey, hello, yo, sup, we good, are you there)
if [[ "$NORMALIZED" =~ ^(hey|hello|hi|yo|sup|what.s up|whats up|we good|are you there|you there|can you hear me) ]]; then
    echo '{"type": "greet", "command": "greet", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# status (what's going on, how are things, sitrep, overview)
if [[ "$NORMALIZED" == "status" ]] || [[ "$NORMALIZED" == "s" ]] || \
   [[ "$NORMALIZED" =~ (what.s going on|how are things|sitrep|overview|what is going on|what.s happening) ]]; then
    echo '{"type": "status", "command": "status", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# standup (rundown, daily report, daily briefing, give me a rundown)
if [[ "$NORMALIZED" == "standup" ]] || [[ "$NORMALIZED" == "standup today" ]] || \
   [[ "$NORMALIZED" =~ (rundown|daily report|daily briefing|give me a rundown|morning report) ]]; then
    echo '{"type": "standup", "command": "standup", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# agents (who is available, show agents, list agents, who do we have)
if [[ "$NORMALIZED" == "agents" ]] || [[ "$NORMALIZED" == "list agents" ]] || \
   [[ "$NORMALIZED" =~ (who is available|show agents|who do we have|list the agents|show me the agents) ]]; then
    echo '{"type": "agents", "command": "agents", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# help (what can you do, commands, help me)
if [[ "$NORMALIZED" == "help" ]] || [[ "$NORMALIZED" == "h" ]] || [[ "$NORMALIZED" == "?" ]] || \
   [[ "$NORMALIZED" =~ (what can you do|show me commands|help me|what do you do) ]]; then
    echo '{"type": "help", "command": "help", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# costs / spending (how much am I spending, show costs, budget)
if [[ "$NORMALIZED" == "costs" ]] || [[ "$NORMALIZED" == "spending" ]] || [[ "$NORMALIZED" == "budget" ]] || \
   [[ "$NORMALIZED" =~ (how much.*(spend|cost)|show.*cost|what.*spend) ]]; then
    echo '{"type": "costs", "command": "costs", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# notifications (any alerts, what needs attention, pending alerts)
if [[ "$NORMALIZED" =~ ^(any alerts|what needs attention|pending alerts|anything urgent|any notifications) ]]; then
    echo '{"type": "notifications", "command": "notifications", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# log <service> <amount> (cost logging)
if [[ "$NORMALIZED" =~ ^log[[:space:]]+([a-z]+)[[:space:]]+([0-9.]+)$ ]]; then
    SERVICE="${BASH_REMATCH[1]}"
    AMOUNT="${BASH_REMATCH[2]}"
    echo '{"type": "logcost", "command": "logcost", "args": ["'"$SERVICE"'", "'"$AMOUNT"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# llc: -> LLC-Ops compliance scheduler commands
if [[ "$NORMALIZED" =~ ^llc[[:space:]]*:[[:space:]]*(.*) ]]; then
    LLC_ARGS="${BASH_REMATCH[1]}"
    LLC_ESCAPED=$(json_escape "$LLC_ARGS")
    echo '{"type": "llc", "command": "llc", "args": ["'"$LLC_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# note: / journal: / jot: -> journal entry (append to JOURNEY.md)
if [[ "$NORMALIZED" =~ ^(note|journal|jot)[[:space:]]*:[[:space:]]*(.*) ]]; then
    NOTE_TEXT="${BASH_REMATCH[2]}"
    NOTE_ESCAPED=$(json_escape "$NOTE_TEXT")
    echo '{"type": "journal", "command": "journal", "args": ["'"$NOTE_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# tasks - natural language (what is forge working on, show forge tasks)
if [[ "$NORMALIZED" =~ (what is|what.s)[[:space:]]+(milo|forge|scout|pulse)[[:space:]]+(working on|doing) ]]; then
    AGENT="${BASH_REMATCH[2]}"
    echo '{"type": "tasks", "command": "tasks", "args": ["'"$AGENT"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# tasks [agent]
if [[ "$NORMALIZED" =~ ^tasks?($|[[:space:]]) ]]; then
    # Extract optional agent filter
    AGENT=""
    if [[ "$NORMALIZED" =~ @([a-z]+) ]]; then
        AGENT="${BASH_REMATCH[1]}"
    elif [[ "$NORMALIZED" =~ tasks?[[:space:]]+([a-z]+)$ ]]; then
        AGENT="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$AGENT" ]]; then
        echo '{"type": "tasks", "command": "tasks", "args": ["'"$AGENT"'"], "raw": "'"$RAW_ESCAPED"'"}'
    else
        echo '{"type": "tasks", "command": "tasks", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    fi
    exit 0
fi

# approve <id>
if [[ "$NORMALIZED" =~ ^approve[[:space:]]+([a-f0-9-]+) ]]; then
    TASK_ID="${BASH_REMATCH[1]}"
    echo '{"type": "approve", "command": "approve", "args": ["'"$TASK_ID"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# reject <id> ["reason"]
if [[ "$NORMALIZED" =~ ^reject[[:space:]]+([a-f0-9-]+)(.*)$ ]]; then
    TASK_ID="${BASH_REMATCH[1]}"
    REASON=$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
    REASON_ESCAPED=$(json_escape "$REASON")
    echo '{"type": "reject", "command": "reject", "args": ["'"$TASK_ID"'", "'"$REASON_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# complete <id>
if [[ "$NORMALIZED" =~ ^(complete|done|finish)[[:space:]]+([a-f0-9-]+) ]]; then
    TASK_ID="${BASH_REMATCH[2]}"
    echo '{"type": "complete", "command": "complete", "args": ["'"$TASK_ID"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# activity [n]
if [[ "$NORMALIZED" =~ ^activity([[:space:]]+([0-9]+))?$ ]]; then
    LIMIT="${BASH_REMATCH[2]:-10}"
    echo '{"type": "activity", "command": "activity", "args": ["'"$LIMIT"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# notifications
if [[ "$NORMALIZED" == "notifications" ]] || [[ "$NORMALIZED" == "notif" ]] || [[ "$NORMALIZED" == "notifs" ]]; then
    echo '{"type": "notifications", "command": "notifications", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# @mention at start -> route to agent
if [[ "$INPUT" =~ ^@([a-zA-Z]+)[[:space:]]+(.*) ]]; then
    AGENT=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    MESSAGE="${BASH_REMATCH[2]}"
    MESSAGE_ESCAPED=$(json_escape "$MESSAGE")

    # Validate agent name
    if [[ "$AGENT" =~ ^(milo|forge|scout|pulse|all)$ ]]; then
        echo '{"type": "mention", "command": "route", "args": ["'"$AGENT"'", "'"$MESSAGE_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
        exit 0
    fi
fi

# Check for @mention anywhere in message (route message)
if [[ "$INPUT" =~ @(milo|forge|scout|pulse|all) ]]; then
    echo '{"type": "route", "command": "route", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# briefing
if [[ "$NORMALIZED" == "briefing" ]] || [[ "$NORMALIZED" == "brief" ]] || [[ "$NORMALIZED" == "morning" ]]; then
    echo '{"type": "briefing", "command": "briefing", "args": [], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# ask / technical questions (CTO brain)
# Match: "how does X work", "what is X", "explain X", "why did we X", "what stack", "architecture"
if [[ "$NORMALIZED" =~ ^(how\ does|how\ do|what\ is|what\ are|what\ stack|explain|why\ did|tell\ me\ about|describe|what.s\ the\ architecture) ]] || \
   [[ "$NORMALIZED" =~ (architecture|technical|stack|pattern|how.*work|how.*built|how.*communicate) ]] || \
   [[ "$NORMALIZED" =~ (journey|story|what.*happened|how.*get\ here|what.*built|timeline|history|milestone) ]]; then
    echo '{"type": "ask", "command": "ask", "args": ["'"$RAW_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# goals / goal commands
# "goals" or "show goals" -> list goals
if [[ "$NORMALIZED" == "goals" ]] || [[ "$NORMALIZED" == "show goals" ]] || [[ "$NORMALIZED" == "my goals" ]] || \
   [[ "$NORMALIZED" =~ ^(what are my goals|where am i|how.*(goals|tracking|progress)) ]]; then
    echo '{"type": "goals", "command": "goals", "args": ["list"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# "goal add <horizon>: <description>" or "new goal: <description>"
if [[ "$NORMALIZED" =~ ^(goal add|new goal|add goal)[[:space:]]*(quarterly|monthly|weekly)?[[:space:]]*:?[[:space:]]*(.*) ]]; then
    GHORIZON="${BASH_REMATCH[2]:-monthly}"
    GDESC="${BASH_REMATCH[3]}"
    GDESC_ESCAPED=$(json_escape "$GDESC")
    echo '{"type": "goals", "command": "goals", "args": ["add", "'"$GHORIZON"'", "'"$GDESC_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# "goal update <keyword>: <progress>% [note]" or "goal <keyword> = <progress>%"
if [[ "$NORMALIZED" =~ ^goal[[:space:]]+(update|set|progress)[[:space:]]+(.*)[[:space:]]*[:=][[:space:]]*([0-9]+)%?(.*)$ ]]; then
    GKEYWORD="${BASH_REMATCH[2]}"
    GPROGRESS="${BASH_REMATCH[3]}"
    GNOTE="${BASH_REMATCH[4]}"
    GKEYWORD_ESCAPED=$(json_escape "$GKEYWORD")
    GNOTE_ESCAPED=$(json_escape "$(echo "$GNOTE" | sed 's/^[[:space:]]*//')")
    echo '{"type": "goals", "command": "goals", "args": ["update", "'"$GKEYWORD_ESCAPED"'", "'"$GPROGRESS"'", "'"$GNOTE_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# "goal drop <keyword>" or "drop goal <keyword>"
if [[ "$NORMALIZED" =~ ^(goal drop|drop goal)[[:space:]]+(.*) ]]; then
    GKEYWORD="${BASH_REMATCH[2]}"
    GKEYWORD_ESCAPED=$(json_escape "$GKEYWORD")
    echo '{"type": "goals", "command": "goals", "args": ["drop", "'"$GKEYWORD_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# "goal done <keyword>" or "achieved <keyword>"
if [[ "$NORMALIZED" =~ ^(goal done|goal achieved|achieved|goal complete)[[:space:]]+(.*) ]]; then
    GKEYWORD="${BASH_REMATCH[2]}"
    GKEYWORD_ESCAPED=$(json_escape "$GKEYWORD")
    echo '{"type": "goals", "command": "goals", "args": ["achieved", "'"$GKEYWORD_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# "goal change <keyword>: <new description>"
if [[ "$NORMALIZED" =~ ^goal[[:space:]]+(change|revise|rename)[[:space:]]+(.*)[[:space:]]*[:>-]+[[:space:]]*(.*) ]]; then
    GOLD="${BASH_REMATCH[2]}"
    GNEW="${BASH_REMATCH[3]}"
    GOLD_ESCAPED=$(json_escape "$GOLD")
    GNEW_ESCAPED=$(json_escape "$GNEW")
    echo '{"type": "goals", "command": "goals", "args": ["revise", "'"$GOLD_ESCAPED"'", "'"$GNEW_ESCAPED"'"], "raw": "'"$RAW_ESCAPED"'"}'
    exit 0
fi

# Unknown command
echo '{"type": "unknown", "command": null, "args": [], "raw": "'"$RAW_ESCAPED"'"}'
exit 0
