#!/bin/bash
# mara-poster.sh — MARA's Autonomous Posting Daemon
#
# Fires daily via launchd. Four-phase execution:
#   1. ASSESS: Read MARA triad + execution history, use Claude Sonnet to decide
#      what to post today (or skip). MARA reads the room, not just the schedule.
#   2. PREPARE: Apply time jitter, run warm-up engagement.
#   3. EXECUTE: Post via Playwright, screenshot proof.
#   4. VERIFY: Sonnet reviews screenshot, confirm post is correct.
#
# MARA is an agent, not a cron job. She thinks before she acts.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
MARA_TOOLS="$HYDRA_ROOT/tools/mara"
LOG_DIR="$HOME/Library/Logs/claude-automation/mara-poster"
LOG_FILE="$LOG_DIR/poster-$(date +%Y-%m-%d).log"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
ISO_WEEK=$(date +%V)

DISTRO="$HOME/Development/id8/products/parallax/workspace/distro"
READY_DIR="$DISTRO/ready-to-post"
ARCHIVE_DIR="$READY_DIR/archive"
SCREENSHOTS_DIR="$DISTRO/screenshots"
EXEC_LOG="$DISTRO/execution-log.md"

# Load env
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
fi

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$SCREENSHOTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== MARA poster started ==="

# ============================================================================
# GUARDS
# ============================================================================

# DRY RUN mode (set DRY_RUN=1 to test without posting)
DRY_RUN="${DRY_RUN:-0}"
if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY RUN mode enabled"
fi

# Duplicate prevention
POSTED_FLAG="$HYDRA_ROOT/state/mara-posted-$DATE.flag"
if [[ -f "$POSTED_FLAG" ]]; then
    log "Already posted today. Exiting."
    exit 0
fi

# Weekend check
DOW=$(date +%u)
if [[ "$DOW" -eq 6 || "$DOW" -eq 7 ]]; then
    log "Weekend. No posts."
    exit 0
fi

# Suspension check (if Eddie manually paused MARA)
SUSPEND_FLAG="$HYDRA_ROOT/state/mara-suspended.flag"
if [[ -f "$SUSPEND_FLAG" ]]; then
    log "MARA is suspended. Remove $SUSPEND_FLAG to resume."
    exit 0
fi

# Skip day (anti-bot: skip one random weekday per week)
SKIP_FLAG="$HYDRA_ROOT/state/mara-skip-week-$ISO_WEEK.flag"
if [[ "$DOW" -eq 1 ]] && [[ ! -f "$SKIP_FLAG" ]]; then
    # Monday: pick a random skip day for this week (Tue=2, Wed=3, Thu=4)
    SKIP_DAY=$((RANDOM % 3 + 2))
    echo "$SKIP_DAY" > "$SKIP_FLAG"
    log "Skip day for week $ISO_WEEK: day $SKIP_DAY"
fi

if [[ -f "$SKIP_FLAG" ]]; then
    SKIP_DAY=$(cat "$SKIP_FLAG")
    if [[ "$DOW" == "$SKIP_DAY" ]]; then
        log "Today is skip day (anti-bot). Exiting."
        exit 0
    fi
fi

# ============================================================================
# PHASE 1: ASSESS — Read the room, think, decide
# ============================================================================

log "Phase 1: ASSESS"

# Gather context for Sonnet
MISSION=""
[[ -f "$DISTRO/MISSION.md" ]] && MISSION=$(cat "$DISTRO/MISSION.md")

STATUS=""
[[ -f "$DISTRO/STATUS.md" ]] && STATUS=$(cat "$DISTRO/STATUS.md")

OKRS=""
[[ -f "$DISTRO/OKRs.md" ]] && OKRS=$(head -100 "$DISTRO/OKRs.md")

PLAYBOOK_RULES=""
[[ -f "$DISTRO/PLAYBOOK.md" ]] && PLAYBOOK_RULES=$(head -60 "$DISTRO/PLAYBOOK.md")

WEEKLY_PLAN=""
[[ -f "$DISTRO/WEEKLY_PLAN.md" ]] && WEEKLY_PLAN=$(cat "$DISTRO/WEEKLY_PLAN.md")

# Recent execution history
RECENT_POSTS=""
[[ -f "$EXEC_LOG" ]] && RECENT_POSTS=$(tail -20 "$EXEC_LOG")

# Available content files
AVAILABLE_FILES=""
for f in "$READY_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    FNAME=$(basename "$f")
    # Get first 2 lines (title + platform)
    HEADER=$(head -3 "$f" | tr '\n' ' ')
    AVAILABLE_FILES+="- $FNAME: $HEADER"$'\n'
done

if [[ -z "$AVAILABLE_FILES" ]]; then
    log "No content files in ready-to-post/. Nothing to do."
    exit 0
fi

# Build Sonnet prompt
ASSESS_PROMPT="You are MARA, the marketing agent for Parallax (tryparallax.space).

TODAY: $DATE ($DAY_NAME)

YOUR MISSION:
$MISSION

CURRENT STATUS:
$STATUS

OKRs (targets):
$OKRS

POSTING RULES (from PLAYBOOK):
$PLAYBOOK_RULES

THIS WEEK'S PLAN:
$WEEKLY_PLAN

RECENT POSTS (execution log):
$RECENT_POSTS

AVAILABLE CONTENT FILES (in ready-to-post/):
$AVAILABLE_FILES

INSTRUCTIONS:
1. Read the situation. You may be waking up after days of no activity. Don't panic-post everything.
2. Look at what's been posted recently and what hasn't.
3. Identify which content files are STALE (date-specific references that have passed, e.g. 'monday-mar10' content on March 27).
4. Decide: what is the ONE best post to publish today that serves the mission? Or should you skip today?
5. Consider platform rotation (don't post to the same platform twice in a row).
6. Consider the anti-bot rules: vary the posting pattern, don't be predictable.

Return ONLY a JSON object (no markdown, no explanation):
{
  \"action\": \"post\" | \"skip\",
  \"file\": \"filename.md or null\",
  \"platform\": \"x\" | \"linkedin\" | null,
  \"reasoning\": \"2-3 sentence explanation of your decision\",
  \"retire_files\": [\"list of stale filenames to archive\"],
  \"next_priority\": \"what should be posted next after this\"
}"

# Call Claude Sonnet
log "Calling Claude Sonnet for assessment..."

ASSESS_RESPONSE=$(python3 << PYEOF
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY")
if not api_key:
    # Try loading from .env files
    for env_file in [
        os.path.expanduser("~/.hydra/config/telegram.env"),
        os.path.expanduser("~/.env"),
    ]:
        if os.path.exists(env_file):
            with open(env_file) as f:
                for line in f:
                    if line.startswith("ANTHROPIC_API_KEY="):
                        api_key = line.strip().split("=", 1)[1].strip('"').strip("'")
                        break
        if api_key:
            break

if not api_key:
    print(json.dumps({"error": "No ANTHROPIC_API_KEY found"}))
    sys.exit(1)

prompt = """$ASSESS_PROMPT"""

data = json.dumps({
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 500,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=data,
    headers={
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01"
    }
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read())
        text = result["content"][0]["text"]
        # Try to parse as JSON (Sonnet might wrap in backticks)
        text = text.strip()
        if text.startswith("\`\`\`"):
            text = text.split("\n", 1)[1].rsplit("\`\`\`", 1)[0].strip()
        parsed = json.loads(text)
        print(json.dumps(parsed))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)
PYEOF
)

log "Sonnet response: $ASSESS_RESPONSE"

# Parse the response
ACTION=$(echo "$ASSESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('action','skip'))")
TARGET_FILE=$(echo "$ASSESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('file','') or '')")
PLATFORM=$(echo "$ASSESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('platform','') or '')")
REASONING=$(echo "$ASSESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reasoning','No reasoning provided'))")
RETIRE_FILES=$(echo "$ASSESS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('retire_files',[])))")

# Retire stale files
if [[ -n "$RETIRE_FILES" ]]; then
    while IFS= read -r rf; do
        [[ -z "$rf" ]] && continue
        if [[ -f "$READY_DIR/$rf" ]]; then
            mv "$READY_DIR/$rf" "$ARCHIVE_DIR/$rf"
            log "Retired stale file: $rf"
        fi
    done <<< "$RETIRE_FILES"
fi

# If action is skip, log and exit
if [[ "$ACTION" != "post" ]]; then
    log "Sonnet decided to SKIP today. Reason: $REASONING"

    # Log the skip to execution log
    echo "| $DATE | $(date +%H:%M) | SKIP | -- | skipped | $REASONING | -- |" >> "$EXEC_LOG"

    # Notify Eddie
    "$NOTIFY" "info" "MARA" "Skipping today's post. $REASONING" 2>/dev/null || true

    touch "$POSTED_FLAG"
    exit 0
fi

# Validate we have a target file
if [[ -z "$TARGET_FILE" ]] || [[ ! -f "$READY_DIR/$TARGET_FILE" ]]; then
    log "ERROR: Sonnet selected file '$TARGET_FILE' but it doesn't exist."
    "$NOTIFY" "urgent" "MARA" "Posting failed: selected file '$TARGET_FILE' not found in ready-to-post/" 2>/dev/null || true
    exit 1
fi

CONTENT_FILE="$READY_DIR/$TARGET_FILE"
log "Sonnet selected: $TARGET_FILE for $PLATFORM. Reason: $REASONING"

# ============================================================================
# PHASE 2: PREPARE — Jitter + warm-up
# ============================================================================

log "Phase 2: PREPARE"

# Time jitter (0-180 minutes)
JITTER=$((RANDOM % 181))
log "Applying jitter: $JITTER minutes"

if [[ "$DRY_RUN" != "1" ]] && [[ "$JITTER" -gt 0 ]]; then
    sleep $((JITTER * 60))
fi

# Warm-up (X only, not for LinkedIn)
WARMUP_DONE=0
if [[ "$PLATFORM" == "x" ]]; then
    log "Running warm-up engagement..."
    WARMUP_ARGS="--screenshot $SCREENSHOTS_DIR/warmup-$DATE.png"
    [[ "$DRY_RUN" == "1" ]] && WARMUP_ARGS+=" --dry-run"

    cd "$MARA_TOOLS"
    WARMUP_RESULT=$(node mara-warmup-x.js $WARMUP_ARGS 2>&1) || true
    WARMUP_OK=$(echo "$WARMUP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',False))" 2>/dev/null || echo "False")

    if [[ "$WARMUP_OK" == "True" ]]; then
        WARMUP_DONE=1
        log "Warm-up complete. Liked some posts."
    else
        log "Warm-up failed (non-critical): $WARMUP_RESULT"
    fi

    # Wait 15-30 min between warm-up and posting
    if [[ "$DRY_RUN" != "1" ]]; then
        WARMUP_WAIT=$((RANDOM % 16 + 15))
        log "Waiting $WARMUP_WAIT minutes after warm-up..."
        sleep $((WARMUP_WAIT * 60))
    fi
fi

# ============================================================================
# PHASE 3: EXECUTE — Post via Playwright
# ============================================================================

log "Phase 3: EXECUTE"

SCREENSHOT_PATH="$SCREENSHOTS_DIR/post-$DATE-$PLATFORM.png"
POST_ARGS="--content $CONTENT_FILE --screenshot $SCREENSHOT_PATH"
[[ "$DRY_RUN" == "1" ]] && POST_ARGS+=" --dry-run"

cd "$MARA_TOOLS"

POST_RESULT=""
POST_SUCCESS="false"

if [[ "$PLATFORM" == "x" ]]; then
    POST_RESULT=$(node mara-post-x.js $POST_ARGS 2>&1) || true
elif [[ "$PLATFORM" == "linkedin" ]]; then
    POST_RESULT=$(node mara-post-linkedin.js $POST_ARGS 2>&1) || true
else
    log "ERROR: Unknown platform $PLATFORM"
    "$NOTIFY" "urgent" "MARA" "Unknown platform: $PLATFORM" 2>/dev/null || true
    exit 1
fi

POST_SUCCESS=$(echo "$POST_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('success',False)))" 2>/dev/null || echo "False")
POST_ERROR=$(echo "$POST_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','') or '')" 2>/dev/null || echo "unknown error")

log "Post result: success=$POST_SUCCESS, error=$POST_ERROR"

if [[ "$POST_SUCCESS" != "True" ]]; then
    log "ERROR: Posting failed. $POST_ERROR"

    # Log failure
    echo "| $DATE | $(date +%H:%M) | $PLATFORM | $TARGET_FILE | FAILED | $POST_ERROR | -- |" >> "$EXEC_LOG"

    # Log to DB
    ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO mara_posts (id, date, platform, content_file, status, jitter_minutes, warmup_done, error, sonnet_reasoning)
        VALUES ('$ACTIVITY_ID', '$DATE', '$PLATFORM', '$TARGET_FILE', 'failed', $JITTER, $WARMUP_DONE, '$(echo "$POST_ERROR" | sed "s/'/''/g")', '$(echo "$REASONING" | sed "s/'/''/g")');
    " 2>/dev/null || true

    # Notify Eddie
    "$NOTIFY" "urgent" "MARA" "Posting FAILED to $PLATFORM: $POST_ERROR" 2>/dev/null || true
    exit 1
fi

# ============================================================================
# PHASE 4: VERIFY — Confirm the post looks right
# ============================================================================

log "Phase 4: VERIFY"

# Log success
ACTUAL_TIME=$(date '+%H:%M')
echo "| $DATE | $ACTUAL_TIME | $PLATFORM | $TARGET_FILE | POSTED | $REASONING | $SCREENSHOT_PATH |" >> "$EXEC_LOG"

# Log to DB
ACTIVITY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
sqlite3 "$HYDRA_DB" "
    INSERT INTO mara_posts (id, date, platform, content_file, post_type, actual_time, jitter_minutes, warmup_done, status, screenshot_path, sonnet_reasoning)
    VALUES ('$ACTIVITY_ID', '$DATE', '$PLATFORM', '$TARGET_FILE', 'single', '$ACTUAL_TIME', $JITTER, $WARMUP_DONE, 'posted', '$SCREENSHOT_PATH', '$(echo "$REASONING" | sed "s/'/''/g")');
" 2>/dev/null || true

# Log activity
sqlite3 "$HYDRA_DB" "
    INSERT INTO activities (id, activity_type, entity_type, entity_id, description)
    VALUES ('$(python3 -c "import uuid; print(str(uuid.uuid4()))")', 'mara_post', 'content', '$TARGET_FILE', 'Posted to $PLATFORM: $TARGET_FILE');
" 2>/dev/null || true

# Notify Eddie with reasoning and screenshot
NOTIFY_MSG="MARA posted to $PLATFORM

File: $TARGET_FILE
Reasoning: $REASONING
Jitter: ${JITTER}m | Warmup: $([[ $WARMUP_DONE -eq 1 ]] && echo 'yes' || echo 'no')
Screenshot: $SCREENSHOT_PATH"

if [[ -f "$SCREENSHOT_PATH" ]]; then
    "$NOTIFY" "info" "MARA" "$NOTIFY_MSG" "$SCREENSHOT_PATH" 2>/dev/null || true
else
    "$NOTIFY" "info" "MARA" "$NOTIFY_MSG" 2>/dev/null || true
fi

# Mark as done for today
touch "$POSTED_FLAG"

log "=== MARA poster complete. Posted $TARGET_FILE to $PLATFORM ==="
