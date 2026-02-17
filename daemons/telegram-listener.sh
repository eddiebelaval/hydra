#!/bin/bash
# telegram-listener.sh - HYDRA Telegram Command Listener
#
# Long-polling daemon that listens for Telegram messages from Eddie
# and dispatches commands to HYDRA.
#
# Usage: telegram-listener.sh
#
# Runs as launchd daemon with KeepAlive.
# Stores offset in ~/.hydra/state/telegram-offset.txt for persistence.

set -euo pipefail

# ============================================================================
# LOCKFILE (prevent duplicate listeners from KeepAlive restarts)
# ============================================================================

LOCK_DIR="$HOME/.hydra/state/telegram-listener.lockdir"
LOCK_FILE="$LOCK_DIR/pid"

# mkdir is atomic on POSIX — only one process can create it
if mkdir "$LOCK_DIR" 2>/dev/null; then
    # We won the lock — write PID immediately
    echo $$ > "$LOCK_FILE"
else
    # Lock dir exists — give winner 3s to write PID, then check
    sleep 3
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
    # Stale lock (holder died without cleanup) — remove and try once
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Lock race lost on retry. Exiting."
        exit 0
    fi
    echo $$ > "$LOCK_FILE"
fi

# ============================================================================
# CLEANUP TRAP (ensure temp files are removed on any exit)
# ============================================================================

cleanup() {
    # Only remove lock if WE still own it (prevents killing new instance's lock)
    if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
    [[ -n "${updates_dir:-}" ]] && rm -rf "$updates_dir"
}
trap cleanup EXIT

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_TOOLS="$HYDRA_ROOT/tools"
STATE_DIR="$HYDRA_ROOT/state"
OFFSET_FILE="$STATE_DIR/telegram-offset.txt"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-telegram"
LOG_FILE="$LOG_DIR/listener-$(date +%Y-%m-%d).log"

# Load Telegram credentials
TELEGRAM_CONFIG="$HYDRA_ROOT/config/telegram.env"
if [[ -f "$TELEGRAM_CONFIG" ]]; then
    source "$TELEGRAM_CONFIG"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Polling settings
POLL_TIMEOUT=30          # Long poll timeout in seconds
ERROR_BACKOFF_BASE=5     # Base backoff on error (seconds)
ERROR_BACKOFF_MAX=300    # Max backoff (5 minutes)
CURRENT_BACKOFF=0        # Current backoff (resets on success)

mkdir -p "$LOG_DIR" "$STATE_DIR"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

log "Starting HYDRA Telegram Listener"

# Validate configuration
if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ "$TELEGRAM_BOT_TOKEN" == "YOUR_BOT_TOKEN_HERE" ]]; then
    log_error "Telegram bot token not configured. Exiting."
    echo "Error: Configure TELEGRAM_BOT_TOKEN in $TELEGRAM_CONFIG"
    exit 1
fi

if [[ -z "$TELEGRAM_CHAT_ID" ]] || [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID_HERE" ]]; then
    log_error "Telegram chat ID not configured. Exiting."
    echo "Error: Configure TELEGRAM_CHAT_ID in $TELEGRAM_CONFIG"
    exit 1
fi

# Initialize offset file if not exists
if [[ ! -f "$OFFSET_FILE" ]]; then
    echo "0" > "$OFFSET_FILE"
fi

log "Configuration validated. Chat ID: $TELEGRAM_CHAT_ID"

# ============================================================================
# CONFLICT DETECTION (catch competing Telegram consumers early)
# ============================================================================
# Telegram only allows ONE getUpdates consumer per bot token at a time.
# If OpenClaw, another bot, or a stale process is also polling, we get 409.
# Detect this at startup with a quick non-blocking poll before entering the
# main loop. Three consecutive 409s = another consumer is active.

CONFLICT_COUNT=0
for i in 1 2 3; do
    PROBE=$(telegram_curl "getUpdates?timeout=0&limit=1" -m 5 2>/dev/null || echo '{"ok":false}')
    if echo "$PROBE" | grep -q '"error_code":409'; then
        CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
        sleep 2
    else
        break
    fi
done

if [[ $CONFLICT_COUNT -ge 3 ]]; then
    log_error "CONFLICT: Another process is polling this bot token (3 consecutive 409s)"
    log_error "Check: OpenClaw Telegram plugin, stale listener processes, or webhook"
    log_error "Fix: Disable OpenClaw Telegram in ~/.openclaw/openclaw.json (channels.telegram.enabled: false)"
    # Send alert via macOS notification since Telegram itself is contested
    osascript -e 'display notification "Another process is polling the Telegram bot. Check OpenClaw." with title "HYDRA: Telegram Conflict" sound name "Basso"' 2>/dev/null || true
    # Write conflict marker for health check to detect
    echo "$(date '+%Y-%m-%d %H:%M:%S') CONFLICT: 409 detected at startup" > "$STATE_DIR/telegram-conflict.txt"
    exit 1
fi

# Clear any stale conflict marker on healthy startup
rm -f "$STATE_DIR/telegram-conflict.txt"

# ============================================================================
# RESPONSE SENDER (inline for reliability)
# ============================================================================

# Token-safe curl wrapper: passes URL via stdin so token never appears in ps aux
telegram_curl() {
    local endpoint="$1"
    shift
    local url="${TELEGRAM_API}/${endpoint}"
    printf 'url = "%s"\n' "$url" | curl --config - -s "$@"
}

send_response() {
    local message="$1"
    local reply_to="${2:-}"
    local use_html="${3:-false}"

    if [[ "$use_html" == "true" ]]; then
        # Convert markdown to Telegram HTML
        local formatted=$(printf '%s' "$message" | python3 -c '
import sys, re, html

text = sys.stdin.read()

# Escape HTML entities first
text = html.escape(text)

# Convert markdown to Telegram HTML
# Code blocks (``` ... ```) -> <pre>
text = re.sub(r"```(\w*)\n(.*?)```", r"<pre>\2</pre>", text, flags=re.DOTALL)
# Inline code
text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
# Bold (**text** or __text__)
text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
text = re.sub(r"__(.+?)__", r"<b>\1</b>", text)
# Italic (*text* or _text_) - careful not to match inside words
text = re.sub(r"(?<!\w)\*([^*]+?)\*(?!\w)", r"<i>\1</i>", text)
# Headers (# text) -> bold
text = re.sub(r"^#{1,3}\s+(.+)$", r"<b>\1</b>", text, flags=re.MULTILINE)
# Horizontal rules
text = re.sub(r"^---+$", "---", text, flags=re.MULTILINE)

print(text)
')
        local json_text=$(printf '%s' "$formatted" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        local request_body="{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${json_text}, \"parse_mode\": \"HTML\""
    else
        local json_text=$(printf '%s' "$message" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        local request_body="{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${json_text}"
    fi

    if [[ -n "$reply_to" ]]; then
        request_body="${request_body}, \"reply_to_message_id\": ${reply_to}"
    fi

    request_body="${request_body}}"

    telegram_curl "sendMessage" -X POST \
        -H "Content-Type: application/json" \
        -d "$request_body" 2>/dev/null | grep -q '"ok":true'
}

# ============================================================================
# VOICE TRANSCRIPTION (Local Whisper via whisper.cpp)
# ============================================================================

WHISPER_BIN="${WHISPER_BIN:-$HOME/Development/whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/Development/whisper.cpp/models/ggml-large-v3-turbo.bin}"
DEEPGRAM_API_KEY="${DEEPGRAM_API_KEY:-}"

transcribe_voice() {
    local file_id="$1"

    if [[ ! -x "$WHISPER_BIN" ]]; then
        log_error "whisper-cli not found at $WHISPER_BIN"
        echo ""
        return 1
    fi

    if [[ ! -f "$WHISPER_MODEL" ]]; then
        log_error "Whisper model not found at $WHISPER_MODEL"
        echo ""
        return 1
    fi

    # Step 1: Get file path from Telegram
    local file_info=$(telegram_curl "getFile?file_id=${file_id}" -m 10 2>/dev/null)
    local file_path=$(echo "$file_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null || echo "")

    if [[ -z "$file_path" ]]; then
        log_error "Could not get file path for voice message"
        echo ""
        return 1
    fi

    # Step 2: Download the OGG audio file from Telegram
    local ts=$(date +%s)
    local tmp_ogg="/tmp/hydra-voice-${ts}.ogg"
    local tmp_wav="/tmp/hydra-voice-${ts}.wav"
    local download_url="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${file_path}"
    curl -s -o "$tmp_ogg" "$download_url" 2>/dev/null

    if [[ ! -s "$tmp_ogg" ]]; then
        log_error "Failed to download voice file"
        rm -f "$tmp_ogg"
        echo ""
        return 1
    fi

    # Step 3: Convert OGG to 16kHz mono WAV (what Whisper expects)
    /opt/homebrew/bin/ffmpeg -i "$tmp_ogg" -ar 16000 -ac 1 -f wav "$tmp_wav" -y 2>/dev/null

    if [[ ! -s "$tmp_wav" ]]; then
        log_error "ffmpeg conversion OGG->WAV failed"
        rm -f "$tmp_ogg" "$tmp_wav"
        echo ""
        return 1
    fi

    # Step 4: Transcribe locally via whisper.cpp (Metal GPU)
    local transcript=$("$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -f "$tmp_wav" \
        --no-timestamps \
        -nt \
        --language en \
        -t 4 \
        2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//')

    rm -f "$tmp_ogg" "$tmp_wav"

    if [[ -n "$transcript" ]]; then
        log "Voice transcribed (local whisper): ${transcript:0:80}..."
        echo "$transcript"
        return 0
    else
        log_error "Whisper returned empty transcript"
        echo ""
        return 1
    fi
}

# ============================================================================
# TEXT-TO-SPEECH (Qwen3-MLX local -> ElevenLabs -> Deepgram fallback)
# ============================================================================

QWEN3_TTS_URL="http://127.0.0.1:7860"

clean_text_for_speech() {
    # Strip markdown/HTML formatting for clean TTS input
    printf '%s' "$1" | python3 -c '
import sys, re
text = sys.stdin.read()
text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
text = re.sub(r"`([^`]+)`", r"\1", text)
text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
text = re.sub(r"__(.+?)__", r"\1", text)
text = re.sub(r"(?<!\w)\*([^*]+?)\*(?!\w)", r"\1", text)
text = re.sub(r"^#{1,3}\s+", "", text, flags=re.MULTILINE)
text = re.sub(r"^[-*]\s+", "", text, flags=re.MULTILINE)
text = re.sub(r"^---+$", "", text, flags=re.MULTILINE)
text = re.sub(r"<[^>]+>", "", text)
text = re.sub(r"\|[^\n]+\|", "", text)
text = re.sub(r"\n{3,}", "\n\n", text)
text = text.strip()
print(text[:3000])
'
}

tts_qwen3() {
    local clean_text="$1"
    local wav_file="$2"

    # Call local Qwen3-TTS MLX server — Ryan voice, professional tone
    local response=$(printf '%s' "$clean_text" | python3 -c '
import sys, json, urllib.request, base64

text = sys.stdin.read()
data = json.dumps({
    "text": text,
    "speaker": "Ryan",
    "instruct": "Confident and clear, professional tone",
    "speed": 1.0,
    "response_format": "base64"
}).encode()

try:
    req = urllib.request.Request(
        "http://127.0.0.1:7860/api/v1/custom-voice/generate",
        data=data,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read().decode())
        audio = base64.b64decode(result["audio"])
        sys.stdout.buffer.write(audio)
except Exception as e:
    print(f"QWEN3_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
' > "$wav_file" 2>/dev/null)

    [[ -s "$wav_file" ]]
}

tts_elevenlabs() {
    local clean_text="$1"
    local mp3_file="$2"
    local voice_id="${ELEVENLABS_VOICE_ID:-nPczCjzI2devNBz1zQrb}"

    local json_body=$(printf '%s' "$clean_text" | python3 -c '
import json, sys
text = sys.stdin.read()
print(json.dumps({
    "text": text,
    "model_id": "eleven_turbo_v2_5",
    "voice_settings": {"stability": 0.5, "similarity_boost": 0.75, "style": 0.0}
}))
')

    curl -s -X POST \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        -o "$mp3_file" \
        "https://api.elevenlabs.io/v1/text-to-speech/${voice_id}" 2>/dev/null

    [[ -s "$mp3_file" ]]
}

tts_deepgram() {
    local clean_text="$1"
    local mp3_file="$2"

    local json_body=$(printf '%s' "$clean_text" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))')

    curl -s -X POST \
        -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        -o "$mp3_file" \
        "https://api.deepgram.com/v1/speak?model=aura-orion-en" 2>/dev/null

    [[ -s "$mp3_file" ]]
}

text_to_speech() {
    local text="$1"
    local output_file="$2"

    local clean_text=$(clean_text_for_speech "$text")
    if [[ -z "$clean_text" ]]; then
        return 1
    fi

    local ts=$(date +%s)
    local audio_file=""

    # Try Qwen3-MLX first (local, free), then ElevenLabs, then Deepgram
    local wav_file="/tmp/hydra-tts-${ts}.wav"
    local mp3_file="/tmp/hydra-tts-${ts}.mp3"

    if tts_qwen3 "$clean_text" "$wav_file"; then
        log "TTS via Qwen3-MLX (local, free)"
        audio_file="$wav_file"
    elif [[ -n "${ELEVENLABS_API_KEY:-}" ]] && tts_elevenlabs "$clean_text" "$mp3_file"; then
        log "TTS via ElevenLabs (cloud fallback)"
        audio_file="$mp3_file"
    elif [[ -n "${DEEPGRAM_API_KEY:-}" ]] && tts_deepgram "$clean_text" "$mp3_file"; then
        log "TTS via Deepgram Aura (cloud fallback)"
        audio_file="$mp3_file"
    else
        log_error "All TTS providers failed"
        rm -f "$wav_file" "$mp3_file"
        return 1
    fi

    # Convert to OGG/Opus (required by Telegram voice notes)
    /opt/homebrew/bin/ffmpeg -i "$audio_file" -c:a libopus -b:a 48k -application voip "$output_file" -y 2>/dev/null

    rm -f "$wav_file" "$mp3_file"

    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        log "TTS generated: $(du -h "$output_file" | cut -f1)"
        return 0
    fi

    log_error "ffmpeg conversion to OGG/Opus failed"
    return 1
}

send_voice_note() {
    local audio_file="$1"
    local reply_to="${2:-}"

    local curl_cmd="curl -s -X POST https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVoice \
        -F chat_id=${TELEGRAM_CHAT_ID} \
        -F voice=@${audio_file}"

    if [[ -n "$reply_to" ]]; then
        curl_cmd="$curl_cmd -F reply_to_message_id=${reply_to}"
    fi

    local result=$(eval "$curl_cmd" 2>/dev/null)
    rm -f "$audio_file"

    echo "$result" | grep -q '"ok":true'
}

# ============================================================================
# CTO BRAIN (Claude Sonnet for technical questions)
# ============================================================================

ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
TECHNICAL_BRAIN_FILE="$HYDRA_ROOT/TECHNICAL_BRAIN.md"
JOURNEY_FILE="$HYDRA_ROOT/JOURNEY.md"
SOUL_FILE="$HYDRA_ROOT/SOUL.md"
GOALS_FILE="$HYDRA_ROOT/GOALS.md"

ask_cto_brain() {
    local question="$1"

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        log_error "ANTHROPIC_API_KEY not configured for CTO brain"
        echo "CTO brain not configured. Add ANTHROPIC_API_KEY to telegram.env."
        return 1
    fi

    # Load technical knowledge
    local system_context=""
    if [[ -f "$TECHNICAL_BRAIN_FILE" ]]; then
        system_context=$(cat "$TECHNICAL_BRAIN_FILE")
    else
        system_context="You are MILO, Eddie Belaval's CTO voice for id8Labs. Answer technical questions about their systems."
    fi

    # Call Claude Sonnet API with soul + technical brain + journey + goals context
    local response=$(python3 << PYEOF
import json, urllib.request, sys, os

parts = []
# Soul first — sets identity and voice
if os.path.exists("$SOUL_FILE"):
    parts.append(open("$SOUL_FILE").read())
# Technical brain — how things work
if os.path.exists("$TECHNICAL_BRAIN_FILE"):
    parts.append(open("$TECHNICAL_BRAIN_FILE").read())
# Journey — why we built them
if os.path.exists("$JOURNEY_FILE"):
    parts.append("\\n\\n---\\n# THE ID8LABS JOURNEY (narrative context)\\n---\\n" + open("$JOURNEY_FILE").read())
# Goals — where we're headed
if os.path.exists("$GOALS_FILE"):
    parts.append("\\n\\n---\\n# GOALS & PRIORITIES (strategic context)\\n---\\n" + open("$GOALS_FILE").read())
system = "\\n".join(parts) if parts else "You are MILO, CTO voice for id8Labs."

question = """$question"""

data = json.dumps({
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 1024,
    "system": system,
    "messages": [{"role": "user", "content": question}]
}).encode()

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": "$ANTHROPIC_API_KEY",
            "anthropic-version": "2023-06-01"
        }
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        if text:
            print(text)
        else:
            # API returned OK but no text — print the raw result for debugging
            print(f"[empty response] {json.dumps(result)[:200]}", file=sys.stderr)
except Exception as e:
    # Print to BOTH stderr (for logs) and stdout (so bash captures it for user)
    print(f"Error: {e}", file=sys.stderr)
PYEOF
)

    if [[ -n "$response" ]]; then
        # Telegram has a 4096 char limit per message
        if [[ ${#response} -gt 4000 ]]; then
            response="${response:0:3990}..."
        fi
        echo "$response"
        return 0
    else
        log_error "CTO brain returned empty response for: ${question:0:80}"
        echo "Sorry, I couldn't process that question right now. (API may have timed out — try again)"
        return 1
    fi
}

# ============================================================================
# INPUT VALIDATION
# ============================================================================

# Validate that a string looks like a UUID (or UUID prefix): alphanumeric + hyphens only
validate_task_id() {
    local id="$1"
    if [[ "$id" =~ ^[a-zA-Z0-9-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# SQL-safe escaping for text fields (doubles single quotes, strips control chars)
sql_escape_text() {
        printf '%s' "$1" | sed "s/'/''/g" | tr -dc '[:print:][:space:]'
}

# ============================================================================
# COMMAND DISPATCHER
# ============================================================================

dispatch_command() {
    local cmd_type="$1"
    local cmd_args="$2"
    local raw_message="$3"
    local message_id="$4"

    log "Dispatching: type=$cmd_type args=$cmd_args"

    local response=""

    case "$cmd_type" in
        status)
            response=$("$HYDRA_TOOLS/hydra-cli.sh" status 2>&1 | head -30 | sed 's/\x1b\[[0-9;]*m//g')
            ;;

        tasks)
            local agent=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$agent" ]]; then
                response=$("$HYDRA_TOOLS/hydra-cli.sh" tasks "$agent" 2>&1 | head -25 | sed 's/\x1b\[[0-9;]*m//g')
            else
                response=$("$HYDRA_TOOLS/hydra-cli.sh" tasks 2>&1 | head -25 | sed 's/\x1b\[[0-9;]*m//g')
            fi
            ;;

        standup)
            response=$("$HYDRA_TOOLS/hydra-cli.sh" standup 2>&1 | head -40 | sed 's/\x1b\[[0-9;]*m//g')
            ;;

        agents)
            response=$("$HYDRA_TOOLS/hydra-cli.sh" agents 2>&1 | head -20 | sed 's/\x1b\[[0-9;]*m//g')
            ;;

        notifications)
            response=$("$HYDRA_TOOLS/hydra-cli.sh" notifications 2>&1 | head -20 | sed 's/\x1b\[[0-9;]*m//g')
            ;;

        costs|spending|budget)
            response=$("$HYDRA_TOOLS/hydra-costs.sh" telegram 2>&1)
            ;;

        logcost)
            # Handle "log anthropic 5.00" or just args ["anthropic", "5.00"]
            local service=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            local amount=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[1] if len(args)>1 else '')" 2>/dev/null || echo "")
            if [[ -n "$service" ]] && [[ -n "$amount" ]]; then
                "$HYDRA_TOOLS/hydra-costs.sh" log "$service" "$amount" 2>&1
                response="Logged: $service = \$$amount

$("$HYDRA_TOOLS/hydra-costs.sh" telegram 2>&1)"
            else
                response="Usage: log <service> <amount>
Example: log anthropic 5.00

Services: anthropic, vercel, perplexity, openai"
            fi
            ;;

        journal|note)
            # Append a note to JOURNEY.md via journey-append.sh
            local note_text=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$note_text" ]]; then
                local append_result=$("$HYDRA_TOOLS/journey-append.sh" --polish "$note_text" 2>&1)
                response="Journal entry added.

$append_result"
                # Log activity
                local activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
                sqlite3 "$HYDRA_DB" "INSERT INTO activities (id, activity_type, entity_type, entity_id, description) VALUES ('$activity_id', 'journal_entry', 'system', 'journey', 'Eddie added journal note via Telegram');" 2>/dev/null
            else
                response="Usage: note: <your note text>
Example: note: shipped the brain updater feature"
            fi
            ;;

        activity)
            local limit=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '10')" 2>/dev/null || echo "10")
            response=$("$HYDRA_TOOLS/hydra-cli.sh" activity "$limit" 2>&1 | head -30 | sed 's/\x1b\[[0-9;]*m//g')
            ;;

        approve)
            local task_id=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$task_id" ]]; then
                if ! validate_task_id "$task_id"; then
                    response="Invalid task ID format: $task_id"
                    break
                fi
                # Find task by partial ID
                local full_id=$(sqlite3 "$HYDRA_DB" "SELECT id FROM tasks WHERE id LIKE '${task_id}%' LIMIT 1;" 2>/dev/null || echo "")
                if [[ -n "$full_id" ]]; then
                    sqlite3 "$HYDRA_DB" "UPDATE tasks SET status = 'in_progress' WHERE id = '$full_id';" 2>/dev/null
                    local task_title=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id = '$full_id';" 2>/dev/null || echo "Unknown")
                    response="Approved: ${full_id:0:8}...
Task: $task_title
Status: in_progress"

                    # Log activity
                    local activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
                    sqlite3 "$HYDRA_DB" "INSERT INTO activities (id, activity_type, entity_type, entity_id, description) VALUES ('$activity_id', 'task_approved', 'task', '$full_id', 'Eddie approved task via Telegram');" 2>/dev/null
                else
                    response="Task not found: $task_id"
                fi
            else
                response="Usage: approve <task-id>"
            fi
            ;;

        reject)
            local task_id=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            local reason=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[1] if len(args)>1 else 'Rejected by Eddie')" 2>/dev/null || echo "Rejected by Eddie")
            if [[ -n "$task_id" ]]; then
                if ! validate_task_id "$task_id"; then
                    response="Invalid task ID format: $task_id"
                    break
                fi
                local full_id=$(sqlite3 "$HYDRA_DB" "SELECT id FROM tasks WHERE id LIKE '${task_id}%' LIMIT 1;" 2>/dev/null || echo "")
                if [[ -n "$full_id" ]]; then
                    local safe_reason=$(sql_escape_text "$reason")
                    sqlite3 "$HYDRA_DB" "UPDATE tasks SET status = 'blocked', blocked_reason = '$safe_reason' WHERE id = '$full_id';" 2>/dev/null
                    local task_title=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id = '$full_id';" 2>/dev/null || echo "Unknown")
                    response="Rejected: ${full_id:0:8}...
Task: $task_title
Reason: $reason"

                    local activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
                    sqlite3 "$HYDRA_DB" "INSERT INTO activities (id, activity_type, entity_type, entity_id, description) VALUES ('$activity_id', 'task_rejected', 'task', '$full_id', 'Eddie rejected task via Telegram');" 2>/dev/null
                else
                    response="Task not found: $task_id"
                fi
            else
                response="Usage: reject <task-id> [reason]"
            fi
            ;;

        complete)
            local task_id=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$task_id" ]]; then
                if ! validate_task_id "$task_id"; then
                    response="Invalid task ID format: $task_id"
                    break
                fi
                local full_id=$(sqlite3 "$HYDRA_DB" "SELECT id FROM tasks WHERE id LIKE '${task_id}%' LIMIT 1;" 2>/dev/null || echo "")
                if [[ -n "$full_id" ]]; then
                    sqlite3 "$HYDRA_DB" "UPDATE tasks SET status = 'completed', completed_at = datetime('now') WHERE id = '$full_id';" 2>/dev/null
                    local task_title=$(sqlite3 "$HYDRA_DB" "SELECT title FROM tasks WHERE id = '$full_id';" 2>/dev/null || echo "Unknown")
                    response="Completed: ${full_id:0:8}...
Task: $task_title"

                    local activity_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
                    sqlite3 "$HYDRA_DB" "INSERT INTO activities (id, activity_type, entity_type, entity_id, description) VALUES ('$activity_id', 'task_completed', 'task', '$full_id', 'Eddie marked task complete via Telegram');" 2>/dev/null
                else
                    response="Task not found: $task_id"
                fi
            else
                response="Usage: complete <task-id>"
            fi
            ;;

        mention|route)
            # Route message with @mentions
            "$HYDRA_TOOLS/hydra-route-message.sh" --channel telegram --sender user --content "$raw_message" 2>/dev/null
            local agent=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$agent" ]]; then
                response="Message routed to @$agent"
            else
                response="Message routed (check for @mentions)"
            fi
            ;;

        briefing)
            response="Generating briefing...
(Check MacDown or notification)"
            "$HYDRA_ROOT/daemons/daily-briefing.sh" 2>/dev/null &
            ;;

        ask|explain|technical|howdoes)
            # CTO Brain: Answer technical questions via Claude Sonnet
            send_response "Thinking..." "$message_id"
            local question="$raw_message"
            local cto_answer=$(ask_cto_brain "$question")
            # Send text with HTML formatting
            send_response "$cto_answer" "$message_id" "true"
            log "CTO brain response sent (HTML)"
            # Generate and send voice note (async, non-blocking)
            (
                local voice_file="/tmp/hydra-cto-voice-$(date +%s).ogg"
                if text_to_speech "$cto_answer" "$voice_file"; then
                    send_voice_note "$voice_file" "$message_id"
                    log "CTO voice note sent"
                else
                    log "TTS skipped (generation failed)"
                fi
            ) &
            return 0
            ;;

        llc)
            # LLC-Ops compliance scheduler
            local llc_raw=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else 'help')" 2>/dev/null || echo "help")
            response=$("$HYDRA_TOOLS/hydra-llc-ops.sh" $llc_raw 2>&1 | head -40)
            ;;

        parallax)
            # Parallax project monitoring
            local subcmd=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else 'status')" 2>/dev/null || echo "status")
            response=$("$HYDRA_TOOLS/parallax-monitor.sh" "$subcmd" 2>&1 | head -40)
            ;;

        health)
            # System health summary
            response=$("$HYDRA_TOOLS/hydra-health-summary.sh" brief 2>&1)
            ;;

        plan)
            # Morning planner: if args provided, store priorities directly
            local plan_args=$(echo "$cmd_args" | python3 -c "import sys,json; args=json.load(sys.stdin); print(args[0] if args else '')" 2>/dev/null || echo "")
            if [[ -n "$plan_args" ]]; then
                # Direct priority input — route to planner reply handler
                "$HYDRA_TOOLS/telegram-handle-planning-reply.sh" "$plan_args" 2>/dev/null &
                response="Got it! Storing your priorities..."
            else
                # Trigger morning planner prompt
                "$HYDRA_ROOT/daemons/morning-planner.sh" 2>/dev/null &
                response="Generating priority suggestions..."
            fi
            ;;

        chat)
            # Conversational messages — route to CTO brain for a real response
            send_response "..." "$message_id"
            local chat_answer=$(ask_cto_brain "$raw_message")
            send_response "$chat_answer" "$message_id" "true"
            log "Chat response sent via CTO brain (HTML)"
            # Generate voice note async
            (
                local voice_file="/tmp/hydra-chat-voice-$(date +%s).ogg"
                if text_to_speech "$chat_answer" "$voice_file"; then
                    send_voice_note "$voice_file" "$message_id"
                    log "Chat voice note sent"
                fi
            ) &
            return 0
            ;;

        help|greet)
            response="Hey Eddie! I understand natural language now.

Try asking me things like:
- \"what's going on?\" (status)
- \"what's forge working on?\" (tasks)
- \"give me a rundown\" (standup)
- \"any alerts?\" (notifications)
- \"approve the auth task\"
- \"@forge check the bug\"
- \"how does HYDRA work?\" (CTO brain)
- \"explain the director builder pattern\" (CTO brain)
- \"note: shipped feature X\" (journal)
- \"how is parallax doing\" (project monitor)
- \"llc: status\" (LLC compliance)
- \"health check\" (system monitoring)
- \"plan my day\" (morning planner)
- \"1. Ship X 2. Review Y 3. Fix Z\" (set priorities)
- \"ava update the hero text\" (Ava modifies her landing page)
- \"ava status\" (check Ava's open PRs)

Or just talk to me like a co-founder -- I'll respond."
            ;;

        unknown)
            # Even unknowns get routed to CTO brain — HYDRA should always respond thoughtfully
            send_response "..." "$message_id"
            local unknown_answer=$(ask_cto_brain "$raw_message")
            send_response "$unknown_answer" "$message_id" "true"
            log "Unknown -> CTO brain response sent (HTML)"
            (
                local voice_file="/tmp/hydra-unknown-voice-$(date +%s).ogg"
                if text_to_speech "$unknown_answer" "$voice_file"; then
                    send_voice_note "$voice_file" "$message_id"
                fi
            ) &
            return 0
            ;;

        ava)
            send_response "Ava is working on it..." "$message_id"
            "$HYDRA_TOOLS/ava-autonomy.sh" instruction "$raw_message" "$message_id" 2>/dev/null &
            return 0
            ;;

        ava_status)
            response=$("$HYDRA_TOOLS/ava-autonomy.sh" status 2>&1 | head -30)
            ;;

        empty)
            return 0  # Ignore empty messages
            ;;

        *)
            response="Unhandled command type: $cmd_type"
            ;;
    esac

    # EVENT BUFFER: Log response summary for Observer
    if [[ -n "$response" ]]; then
        local EVENT_BUFFER="$HYDRA_ROOT/state/event-buffer.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESPONSE: ${response:0:200}" >> "$EVENT_BUFFER" 2>/dev/null || true
    fi

    # Send response back
    if [[ -n "$response" ]]; then
        if send_response "$response" "$message_id"; then
            log "Response sent successfully"
        else
            log_error "Failed to send response"
        fi
    fi
}

# ============================================================================
# MESSAGE PROCESSOR
# ============================================================================

process_message_file() {
    local json_file="$1"

    # Extract all fields in one Python call (efficient + no escaping issues)
    # Note: Use sys.argv for file path to avoid shell escaping issues
    local fields=$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get('from', {}).get('id', ''))
print(m.get('chat', {}).get('id', ''))
print(m.get('message_id', ''))
print(m.get('text', ''))
print(m.get('reply_to_message', {}).get('message_id', ''))
print(m.get('voice', {}).get('file_id', '') if 'voice' in m else '')
" "$json_file" 2>/dev/null)

    # Parse fields (one per line)
    local from_id=$(echo "$fields" | sed -n '1p')
    local chat_id=$(echo "$fields" | sed -n '2p')
    local message_id=$(echo "$fields" | sed -n '3p')
    local text=$(echo "$fields" | sed -n '4p')
    local reply_to_msg_id=$(echo "$fields" | sed -n '5p')
    local voice_file_id=$(echo "$fields" | sed -n '6p')

    log "Message from chat_id=$chat_id user=$from_id: ${text:0:50}..."

    # EVENT BUFFER: Capture full message for Observer memory system
    local EVENT_BUFFER="$HYDRA_ROOT/state/event-buffer.log"

    # AUTH GATE: Only process messages from configured chat
    if [[ "$chat_id" != "$TELEGRAM_CHAT_ID" ]]; then
        log "Ignoring message from unauthorized chat: $chat_id"
        return 0
    fi

    # Handle voice messages: transcribe then process as text
    if [[ -n "$voice_file_id" ]] && [[ -z "$text" ]]; then
        log "Voice message detected (file_id: ${voice_file_id:0:20}...)"
        send_response "Transcribing voice..." "$message_id"
        text=$(transcribe_voice "$voice_file_id")
        if [[ -z "$text" ]]; then
            send_response "Sorry, I couldn't transcribe that voice message. Try again or type your message." "$message_id"
            return 0
        fi
        log "Voice transcribed to: ${text:0:80}..."
    fi

    # Skip empty/non-text messages (photos, stickers, etc.)
    if [[ -z "$text" ]]; then
        log "Skipping non-text/non-voice message"
        return 0
    fi

    # Check for reply context — route conversation thread replies to handlers
    if [[ -n "$reply_to_msg_id" ]]; then
        local context=$(sqlite3 "$HYDRA_DB" "SELECT hydra_entity_type, hydra_entity_id FROM telegram_context WHERE telegram_message_id = $reply_to_msg_id LIMIT 1;" 2>/dev/null || echo "")
        if [[ -n "$context" ]]; then
            local entity_type=$(echo "$context" | cut -d'|' -f1)
            local entity_id=$(echo "$context" | cut -d'|' -f2)
            log "Reply context found: $entity_type/$entity_id"

            # Route conversation thread replies to specialized handlers
            if [[ "$entity_type" == "conversation_thread" ]]; then
                local thread_info=$(sqlite3 "$HYDRA_DB" "
                    SELECT thread_type, state FROM conversation_threads
                    WHERE id = '$entity_id' LIMIT 1;
                " 2>/dev/null || echo "")

                if [[ -n "$thread_info" ]]; then
                    local thread_type=$(echo "$thread_info" | cut -d'|' -f1)
                    local thread_state=$(echo "$thread_info" | cut -d'|' -f2)

                    if [[ "$thread_state" == "awaiting_input" ]]; then
                        log "Routing to conversation handler: $thread_type (thread: $entity_id)"

                        # EVENT BUFFER: Log before routing
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] TELEGRAM: $text" >> "$HYDRA_ROOT/state/event-buffer.log" 2>/dev/null || true
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DISPATCH: conversation_reply -> $thread_type/$entity_id" >> "$HYDRA_ROOT/state/event-buffer.log" 2>/dev/null || true

                        case "$thread_type" in
                            morning_planner)
                                "$HYDRA_TOOLS/telegram-handle-planning-reply.sh" "$text" "$entity_id" 2>/dev/null &
                                ;;
                            evening_review)
                                "$HYDRA_TOOLS/telegram-handle-review-reply.sh" "$text" "$entity_id" 2>/dev/null &
                                ;;
                            ava_approval)
                                "$HYDRA_TOOLS/ava-autonomy.sh" approval "$text" "$entity_id" 2>/dev/null &
                                ;;
                            *)
                                log "Unknown thread type: $thread_type"
                                ;;
                        esac
                        return 0  # Skip normal NL parsing
                    else
                        log "Thread $entity_id in state '$thread_state' (not awaiting_input), falling through to NL parser"
                    fi
                fi
            fi
        fi
    fi

    # Parse command (natural language via Ollama, falls back to rigid parsing)
    local parsed=$("$HYDRA_TOOLS/telegram-parse-natural.sh" "$text" 2>/dev/null || echo '{"type":"unknown"}')
    local cmd_type=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','unknown'))" 2>/dev/null || echo "unknown")
    local cmd_args=$(echo "$parsed" | python3 -c "import sys,json; import json as j; print(j.dumps(json.load(sys.stdin).get('args',[])))" 2>/dev/null || echo "[]")

    # EVENT BUFFER: Log inbound message + dispatch type for Observer
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TELEGRAM: $text" >> "$EVENT_BUFFER" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DISPATCH: $cmd_type -> $cmd_args" >> "$EVENT_BUFFER" 2>/dev/null || true

    # Dispatch
    dispatch_command "$cmd_type" "$cmd_args" "$text" "$message_id"
}

# ============================================================================
# MAIN POLLING LOOP
# ============================================================================

log "Entering main loop"

while true; do
    # Read current offset
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

    # Long poll for updates
    RESPONSE=$(telegram_curl "getUpdates?offset=${OFFSET}&timeout=${POLL_TIMEOUT}" -m $((POLL_TIMEOUT + 5)) 2>/dev/null || echo '{"ok":false}')

    # Check for API errors
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        log_error "API error or timeout: ${RESPONSE:0:100}"

        # Detect competing consumer (409 Conflict)
        if echo "$RESPONSE" | grep -q '"error_code":409'; then
            CONFLICT_409_COUNT=$((${CONFLICT_409_COUNT:-0} + 1))
            if [[ $CONFLICT_409_COUNT -ge 5 ]]; then
                log_error "CONFLICT: 5 consecutive 409s — another consumer is polling this bot"
                log_error "Exiting to trigger conflict detection on restart"
                echo "$(date '+%Y-%m-%d %H:%M:%S') CONFLICT: 409 storm during operation" > "$STATE_DIR/telegram-conflict.txt"
                osascript -e 'display notification "Telegram 409 conflict detected. Check OpenClaw." with title "HYDRA: Bot Conflict" sound name "Basso"' 2>/dev/null || true
                exit 1
            fi
        else
            CONFLICT_409_COUNT=0
        fi

        # Exponential backoff
        CURRENT_BACKOFF=$((CURRENT_BACKOFF == 0 ? ERROR_BACKOFF_BASE : CURRENT_BACKOFF * 2))
        if [[ $CURRENT_BACKOFF -gt $ERROR_BACKOFF_MAX ]]; then
            CURRENT_BACKOFF=$ERROR_BACKOFF_MAX
        fi

        log "Backing off for ${CURRENT_BACKOFF}s"
        sleep $CURRENT_BACKOFF
        continue
    fi

    # Reset conflict counter on success
    CONFLICT_409_COUNT=0

    # Reset backoff on success
    CURRENT_BACKOFF=0

    # Process updates
    UPDATE_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo "0")

    if [[ "$UPDATE_COUNT" -gt 0 ]]; then
        log "Processing $UPDATE_COUNT update(s)"

        # Write updates to temp directory (avoids shell JSON mangling)
        updates_dir=$(mktemp -d)
        echo "$RESPONSE" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
updates_dir = sys.argv[1]
for i, update in enumerate(data.get('result', [])):
    update_id = update.get('update_id', 0)
    message = update.get('message', {})
    if message:
        # Write update_id to .id file, message JSON to .json file
        with open(f'{updates_dir}/{i}.id', 'w') as f:
            f.write(str(update_id))
        with open(f'{updates_dir}/{i}.json', 'w') as f:
            json.dump(message, f)
" "$updates_dir" 2>/dev/null

        # Process each update from temp files
        for id_file in "$updates_dir"/*.id; do
            # Skip if glob didn't match (literal *.id)
            [[ -f "$id_file" ]] || continue

            base="${id_file%.id}"
            json_file="${base}.json"

            if [[ -f "$json_file" ]]; then
                update_id=$(cat "$id_file")

                # Process message (pass JSON file path)
                process_message_file "$json_file"

                # Update offset (processed update_id + 1)
                NEW_OFFSET=$((update_id + 1))
                echo "$NEW_OFFSET" > "$OFFSET_FILE"
                log "Offset updated to $NEW_OFFSET"
            fi
        done

        # Cleanup temp directory
        rm -rf "$updates_dir"
    fi
done
