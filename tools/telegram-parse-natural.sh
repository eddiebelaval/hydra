#!/bin/bash
# telegram-parse-natural.sh - Natural Language Command Parser for HYDRA
#
# Uses Claude Haiku to interpret natural language messages and convert
# them to structured HYDRA commands.
#
# Usage: telegram-parse-natural.sh "what's forge working on?"
# Output: {"type": "tasks", "args": ["@forge"], "confidence": "high"}
#
# Falls back to rigid parsing if Haiku is unavailable.

set -euo pipefail

INPUT="${1:-}"

if [[ -z "$INPUT" ]]; then
    echo '{"type": "empty", "args": [], "confidence": "high"}'
    exit 0
fi

# Load Anthropic API key from telegram.env
HYDRA_ENV="$HOME/.hydra/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" | head -1 | cut -d'"' -f2)
fi

# Try Claude Haiku first
parse_with_haiku() {
    local message="$1"

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        return 1
    fi

    export HAIKU_MESSAGE="$message"
    local response=$(python3 << 'PYEOF'
import json, urllib.request, sys, os

message = os.environ.get("HAIKU_MESSAGE", "")
api_key = os.environ.get("ANTHROPIC_API_KEY", "")

system_prompt = """You are a command parser for HYDRA, Eddie's AI co-founder system. Parse messages into commands.

IMPORTANT: Eddie talks to HYDRA like a co-founder — casual, conversational, sometimes just sharing thoughts or reacting. When in doubt between "unknown" and "chat", ALWAYS choose "chat". The "unknown" type should almost NEVER be used.

Available commands:
- status: System overview (what is going on, status, how are things)
- tasks: List tasks. Optional agent filter. (show tasks, what is forge doing -> tasks with args ["@forge"])
- standup: Daily standup report (standup, daily report, rundown, briefing)
- agents: List agents (who is available, list agents, show agents)
- notifications: Pending alerts (any alerts, notifications, what needs attention)
- activity: Recent activity. Optional count. (what happened, recent activity, activity 20 -> args ["20"])
- approve: Approve a task by ID or description (approve the auth task, approve 12ab)
- reject: Reject a task with optional reason (reject that migration, reject 12ab not ready)
- complete: Mark task done (mark auth done, complete 12ab)
- mention: Route to agent (@forge fix the bug, tell forge to check auth)
- briefing: Generate detailed report (full briefing, generate report)
- help: Show help (help, what can you do, commands)
- costs: Show spending/costs (costs, spending, how much am I spending, budget, show me costs)
- logcost: Log a cost (log anthropic 5.00, record vercel 2.50) -> args should be [service, amount]
- journal: Append a note to the journey/session log (note: shipped feature X, journal: fixed the auth bug, jot: realized we need caching) -> args should be [note_text]
- llc: LLC compliance, deadlines, filings, documents (llc: status, llc: deadlines, llc: complete <id>, any llc stuff due soon, show compliance deadlines, what are my llc deadlines) -> args should be the sub-command string e.g. ["status"], ["deadlines"], ["complete d120"], ["detail 427e"]
- parallax: Parallax project monitoring — status, github activity, deployments, pipeline stage, health checks (how is parallax doing, parallax status, check parallax deploy, parallax github, what stage is parallax on, is parallax up, parallax health, show me parallax) -> args should be the subcommand e.g. ["status"], ["github"], ["deploy"], ["pipeline"], ["health"]
- health: System health status, monitoring, heartbeat results (health check, system status, how is hydra doing, any issues, system health, is everything running, heartbeat)
- ava: Instructions for Ava to modify the Parallax landing page, narration, or components (ava update the hero, ava change the narration, tell ava to fix the opening, ava add a section, @ava update the truth pool). The instruction text after "ava" is the args. -> args should be [full instruction text]
- ava_status: Check status of Ava's open PRs and operations (ava status, how's ava's PR, what is ava doing, ava ops)
- plan: Set daily priorities, morning planning, what should I focus on (plan my day, set priorities, what should I work on today, top 3, my priorities, planning) -> args should be priority text if provided e.g. ["1. Ship demo 2. Review PR 3. Homer auth"]
- ask: Technical questions, architecture, code, how things work, the journey/story, history, strategy questions, opinions about projects, "what do you think about X", sharing findings that need a response (how does X work, explain Y, what should we do about Z, what do you think of this, look at this finding, tell me about the journey)
- chat: Conversational messages, reactions, praise, casual talk, sharing news/updates, thinking out loud, following up on something, anything that doesn't fit another command but deserves a thoughtful response. This is a CATCH-ALL for anything conversational. Use this liberally. (nice work, that's awesome, we lost 50 bucks, check this out, I was thinking about X, fuck yeah, we should do X someday, look what I found)
- greet: Short greetings and meta-questions ONLY (hey, hello, you there, we good). NOT longer messages that start with hey.
- unknown: ONLY for truly incomprehensible or accidental messages (keyboard mash, single punctuation, totally garbled text). Almost never used.

Respond with ONLY valid JSON, no explanation:
{"type": "command_name", "args": ["arg1", "arg2"], "confidence": "high|medium|low"}

Examples:
User: yo whats up
{"type": "status", "args": [], "confidence": "high"}

User: what is forge working on
{"type": "tasks", "args": ["@forge"], "confidence": "high"}

User: approve that auth fix
{"type": "approve", "args": ["auth"], "confidence": "medium"}

User: show me the last 5 things that happened
{"type": "activity", "args": ["5"], "confidence": "high"}

User: @oracle check the database
{"type": "mention", "args": ["@oracle", "check the database"], "confidence": "high"}

User: banana sandwich
{"type": "unknown", "args": [], "confidence": "high"}

User: hey are you there
{"type": "greet", "args": [], "confidence": "high"}

User: how much am I spending
{"type": "costs", "args": [], "confidence": "high"}

User: log anthropic 5.00
{"type": "logcost", "args": ["anthropic", "5.00"], "confidence": "high"}

User: record vercel 2.50
{"type": "logcost", "args": ["vercel", "2.50"], "confidence": "high"}

User: how does the director builder pattern work
{"type": "ask", "args": ["how does the director builder pattern work"], "confidence": "high"}

User: explain how HYDRA agents communicate
{"type": "ask", "args": ["explain how HYDRA agents communicate"], "confidence": "high"}

User: what stack does Homer use
{"type": "ask", "args": ["what stack does Homer use"], "confidence": "high"}

User: tell me about the journey
{"type": "ask", "args": ["tell me about the journey"], "confidence": "high"}

User: what happened in January
{"type": "ask", "args": ["what happened in January"], "confidence": "high"}

User: how did we get here
{"type": "ask", "args": ["how did we get here"], "confidence": "high"}

User: what have we built so far
{"type": "ask", "args": ["what have we built so far"], "confidence": "high"}

User: tell me the id8labs story
{"type": "ask", "args": ["tell me the id8labs story"], "confidence": "high"}

User: why did we choose supabase
{"type": "ask", "args": ["why did we choose supabase"], "confidence": "high"}

User: note: shipped the brain auto-updater today
{"type": "journal", "args": ["shipped the brain auto-updater today"], "confidence": "high"}

User: jot: realized caching needs rethinking
{"type": "journal", "args": ["realized caching needs rethinking"], "confidence": "high"}

User: journal: fixed IDOR bug in Homer agents endpoint
{"type": "journal", "args": ["fixed IDOR bug in Homer agents endpoint"], "confidence": "high"}

User: llc: status
{"type": "llc", "args": ["status"], "confidence": "high"}

User: llc: deadlines
{"type": "llc", "args": ["deadlines"], "confidence": "high"}

User: llc: complete d120
{"type": "llc", "args": ["complete d120"], "confidence": "high"}

User: llc: snooze 355c 7
{"type": "llc", "args": ["snooze 355c 7"], "confidence": "high"}

User: llc: detail 427e
{"type": "llc", "args": ["detail 427e"], "confidence": "high"}

User: what are my llc deadlines
{"type": "llc", "args": ["deadlines"], "confidence": "high"}

User: any llc stuff due soon
{"type": "llc", "args": ["status"], "confidence": "high"}

User: show my compliance deadlines
{"type": "llc", "args": ["deadlines"], "confidence": "high"}

User: how is parallax doing
{"type": "parallax", "args": ["status"], "confidence": "high"}

User: parallax github
{"type": "parallax", "args": ["github"], "confidence": "high"}

User: check parallax deploy
{"type": "parallax", "args": ["deploy"], "confidence": "high"}

User: what stage is parallax on
{"type": "parallax", "args": ["pipeline"], "confidence": "high"}

User: is parallax up
{"type": "parallax", "args": ["health"], "confidence": "high"}

User: show me parallax
{"type": "parallax", "args": ["status"], "confidence": "high"}

User: parallax status
{"type": "parallax", "args": ["status"], "confidence": "high"}

User: health check
{"type": "health", "args": [], "confidence": "high"}

User: is everything running
{"type": "health", "args": [], "confidence": "high"}

User: system health
{"type": "health", "args": [], "confidence": "high"}

User: any issues with hydra
{"type": "health", "args": [], "confidence": "high"}

User: plan my day
{"type": "plan", "args": [], "confidence": "high"}

User: what should I focus on today
{"type": "plan", "args": [], "confidence": "high"}

User: set priorities
{"type": "plan", "args": [], "confidence": "high"}

User: 1. Ship demo 2. Review PR 3. Homer auth
{"type": "plan", "args": ["1. Ship demo 2. Review PR 3. Homer auth"], "confidence": "high"}

User: my top 3 today are ship parallax, review rune, fix homer
{"type": "plan", "args": ["ship parallax, review rune, fix homer"], "confidence": "high"}

User: nice work. you're getting some badass upgrades
{"type": "chat", "args": ["nice work. you're getting some badass upgrades"], "confidence": "high"}

User: fuck yeah that's awesome dude
{"type": "chat", "args": ["fuck yeah that's awesome dude"], "confidence": "high"}

User: it's funded Richard we lost 50 bucks actually no we made money
{"type": "chat", "args": ["it's funded Richard we lost 50 bucks actually no we made money"], "confidence": "high"}

User: I was thinking we should probably focus more on Homer
{"type": "chat", "args": ["I was thinking we should probably focus more on Homer"], "confidence": "high"}

User: MAJOR FINDING - Agentic Wallets from Coinbase could change everything
{"type": "chat", "args": ["MAJOR FINDING - Agentic Wallets from Coinbase could change everything"], "confidence": "high"}

User: that's not right. I've spent at least 50 bucks so far
{"type": "chat", "args": ["that's not right. I've spent at least 50 bucks so far"], "confidence": "high"}

User: the personas are fine but the voice needs work
{"type": "chat", "args": ["the personas are fine but the voice needs work"], "confidence": "high"}

User: we should work on deepstack when the market is better
{"type": "chat", "args": ["we should work on deepstack when the market is better"], "confidence": "high"}

User: hi! hey my task for the day is set to Homer can we work on it
{"type": "chat", "args": ["hi! hey my task for the day is set to Homer can we work on it"], "confidence": "high"}

User: what do you think about adding a payments feature
{"type": "ask", "args": ["what do you think about adding a payments feature"], "confidence": "high"}

User: should we pivot from B2B to B2C for Homer
{"type": "ask", "args": ["should we pivot from B2B to B2C for Homer"], "confidence": "high"}

User: ava add a new truth to the opening pool
{"type": "ava", "args": ["add a new truth to the opening pool"], "confidence": "high"}

User: tell ava to update the hero section
{"type": "ava", "args": ["update the hero section"], "confidence": "high"}

User: ava (codex) clean up the landing page CSS
{"type": "ava", "args": ["(codex) clean up the landing page CSS"], "confidence": "high"}

User: @ava change the narration script opening
{"type": "ava", "args": ["change the narration script opening"], "confidence": "high"}

User: ava status
{"type": "ava_status", "args": [], "confidence": "high"}

User: what is ava doing
{"type": "ava_status", "args": [], "confidence": "high"}

User: how's ava's PR
{"type": "ava_status", "args": [], "confidence": "high"}

User: asdfghjk
{"type": "unknown", "args": [], "confidence": "high"}"""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 100,
    "system": system_prompt,
    "messages": [{"role": "user", "content": message}]
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
    with urllib.request.urlopen(req, timeout=5) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        print(text)
except Exception as e:
    print("", file=sys.stderr)
PYEOF
)

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Try to extract JSON from response
    local parsed=$(echo "$response" | python3 -c "
import sys, json, re

text = sys.stdin.read()

# Try to find JSON in the response
json_match = re.search(r'\{[^{}]*\}', text)
if json_match:
    try:
        data = json.loads(json_match.group())
        if 'type' in data:
            if 'args' not in data:
                data['args'] = []
            if 'confidence' not in data:
                data['confidence'] = 'medium'
            print(json.dumps(data))
    except:
        pass
" 2>/dev/null)

    if [[ -n "$parsed" ]]; then
        echo "$parsed"
        return 0
    fi

    return 1
}

# Fallback to the rigid parser
parse_rigid() {
    local message="$1"
    ~/.hydra/tools/telegram-parse-command.sh "$message"
}

# Main logic: Haiku first, rigid parser fallback
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
result=$(parse_with_haiku "$INPUT" 2>/dev/null) || result=""

# Check if Haiku returned a valid result
if [[ -n "$result" ]]; then
    result_type=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || echo "")

    # If Haiku says "unknown", try rigid parser as fallback
    if [[ "$result_type" == "unknown" ]]; then
        rigid_result=$(parse_rigid "$INPUT" 2>/dev/null)
        rigid_type=$(echo "$rigid_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || echo "")

        # Use rigid result if it's not unknown
        if [[ "$rigid_type" != "unknown" ]] && [[ -n "$rigid_type" ]]; then
            echo "$rigid_result"
            exit 0
        fi
    fi

    echo "$result"
else
    # Haiku failed entirely, use rigid parsing
    parse_rigid "$INPUT"
fi
