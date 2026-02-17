#!/bin/bash
# ava-telegram-listener.sh - Ava's dedicated Telegram polling daemon
#
# A lightweight listener for Ava's own Telegram bot. Much simpler than
# HYDRA's full listener — handles only Ava-specific commands:
#   - Instructions (modify landing page)
#   - Approval replies (approve/reject/revise PRs)
#   - Status queries
#   - Conversational fallback (Ava responds as herself)
#
# Requires: ~/.hydra/config/ava-telegram.env with valid bot token + chat ID
#
# Usage:
#   ava-telegram-listener.sh          # Normal operation
#   ava-telegram-listener.sh --test   # Process one poll cycle and exit

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_TOOLS="$HYDRA_ROOT/tools"
AVA_CONFIG="$HYDRA_ROOT/config/ava-telegram.env"
HYDRA_CONFIG="$HYDRA_ROOT/config/telegram.env"

# State
STATE_DIR="$HYDRA_ROOT/state"
OFFSET_FILE="$STATE_DIR/ava-telegram-offset.txt"
mkdir -p "$STATE_DIR"

# Logging
LOG_DIR="$HOME/Library/Logs/claude-automation/ava-telegram"
LOG_FILE="$LOG_DIR/listener-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

# Polling
POLL_TIMEOUT=30
ERROR_BACKOFF_BASE=5
ERROR_BACKOFF_MAX=60
CURRENT_BACKOFF=0
CONFLICT_409_COUNT=0

# Test mode
TEST_MODE="${1:-}"

# ============================================================================
# LOAD CREDENTIALS
# ============================================================================

if [[ ! -f "$AVA_CONFIG" ]]; then
    echo "ERROR: Ava config not found at $AVA_CONFIG"
    echo "Run: cp ~/.hydra/config/ava-telegram.env.example ~/.hydra/config/ava-telegram.env"
    exit 1
fi

source "$AVA_CONFIG"

# Ava uses her own bot token
BOT_TOKEN="${AVA_TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AVA_TELEGRAM_CHAT_ID:-}"

if [[ -z "$BOT_TOKEN" ]] || [[ "$BOT_TOKEN" == "PASTE_TOKEN_HERE" ]]; then
    echo "ERROR: Ava bot token not configured in $AVA_CONFIG"
    exit 1
fi

if [[ -z "$CHAT_ID" ]] || [[ "$CHAT_ID" == "PASTE_CHAT_ID_HERE" ]]; then
    echo "ERROR: Ava chat ID not configured in $AVA_CONFIG"
    exit 1
fi

# Load HYDRA's API keys (for Anthropic)
if [[ -f "$HYDRA_CONFIG" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_CONFIG" | head -1 | cut -d'"' -f2)
    export ANTHROPIC_API_KEY
fi

TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}"

# Load Deepgram API key (for voice transcription)
DEEPGRAM_API_KEY=""
if [[ -f "$HYDRA_CONFIG" ]]; then
    DEEPGRAM_API_KEY=$(grep '^DEEPGRAM_API_KEY=' "$HYDRA_CONFIG" | head -1 | cut -d'"' -f2)
fi

# Parallax directory (for codebase introspection)
PARALLAX_DIR="$HOME/Development/id8/products/parallax"

# ============================================================================
# LOGGING
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ava-listener] $1" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ava-listener] ERROR: $1" >> "$LOG_FILE"
}

# ============================================================================
# TELEGRAM HELPERS
# ============================================================================

telegram_curl() {
    local endpoint="$1"
    shift
    curl -s "${TELEGRAM_API}/${endpoint}" "$@"
}

send_response() {
    local msg="$1"
    local reply_to="${2:-}"

    local json_text
    json_text=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    local body="{\"chat_id\": \"${CHAT_ID}\", \"text\": ${json_text}"
    if [[ -n "$reply_to" ]]; then
        body="${body}, \"reply_to_message_id\": ${reply_to}"
    fi
    body="${body}}"

    local response
    response=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null)

    if echo "$response" | grep -q '"ok":true'; then
        local sent_id
        sent_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['message_id'])" 2>/dev/null || echo "")
        log "Sent response (msg_id: $sent_id)"
        echo "$sent_id"
    else
        log_error "Send failed: $response"
        echo ""
    fi
}

# ============================================================================
# VOICE (ElevenLabs TTS → OGG Opus → Telegram voice note)
# ============================================================================

# Ava's voice — same ElevenLabs voice as Parallax
AVA_ELEVENLABS_VOICE_ID="gJx1vCzNCD1EQHT212Ls"
AVA_ELEVENLABS_MODEL="eleven_turbo_v2_5"

# Load ElevenLabs API key from HYDRA config
ELEVENLABS_API_KEY=""
if [[ -f "$HYDRA_CONFIG" ]]; then
    ELEVENLABS_API_KEY=$(grep '^ELEVENLABS_API_KEY=' "$HYDRA_CONFIG" | head -1 | cut -d'"' -f2)
fi

send_voice_response() {
    local text="$1"
    local reply_to="${2:-}"

    if [[ -z "$ELEVENLABS_API_KEY" ]]; then
        log "Voice skipped: no ElevenLabs API key"
        return 0
    fi

    # Skip voice for very short responses (under 10 chars)
    if [[ ${#text} -lt 10 ]]; then
        log "Voice skipped: response too short"
        return 0
    fi

    local tmp_mp3 tmp_ogg
    tmp_mp3=$(mktemp /tmp/ava-voice-XXXXXX.mp3)
    tmp_ogg=$(mktemp /tmp/ava-voice-XXXXXX.ogg)

    # Generate speech via ElevenLabs
    local tts_status
    tts_status=$(curl -s -w "%{http_code}" -o "$tmp_mp3" \
        -X POST "https://api.elevenlabs.io/v1/text-to-speech/${AVA_ELEVENLABS_VOICE_ID}" \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"text\": $(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
            \"model_id\": \"${AVA_ELEVENLABS_MODEL}\",
            \"voice_settings\": {
                \"stability\": 0.5,
                \"similarity_boost\": 0.75
            }
        }" 2>/dev/null)

    if [[ "$tts_status" != "200" ]]; then
        log_error "ElevenLabs TTS failed (HTTP $tts_status)"
        rm -f "$tmp_mp3" "$tmp_ogg"
        return 1
    fi

    # Convert MP3 → OGG Opus (Telegram voice note format)
    if ! /opt/homebrew/bin/ffmpeg -y -i "$tmp_mp3" -c:a libopus -b:a 48k -vn "$tmp_ogg" 2>/dev/null; then
        log_error "ffmpeg conversion failed"
        rm -f "$tmp_mp3" "$tmp_ogg"
        return 1
    fi

    # Send voice note via Telegram
    local voice_args=(-F "chat_id=${CHAT_ID}" -F "voice=@${tmp_ogg}")
    if [[ -n "$reply_to" ]]; then
        voice_args+=(-F "reply_to_message_id=${reply_to}")
    fi

    local response
    response=$(curl -s -X POST "${TELEGRAM_API}/sendVoice" "${voice_args[@]}" 2>/dev/null)

    if echo "$response" | grep -q '"ok":true'; then
        log "Voice note sent"
    else
        log_error "Voice send failed: ${response:0:200}"
    fi

    # Cleanup temp files
    rm -f "$tmp_mp3" "$tmp_ogg"
}

# ============================================================================
# TELEGRAM FILE DOWNLOAD (for voice messages and photos)
# ============================================================================

download_telegram_file() {
    local file_id="$1"
    local output_path="$2"

    # Step 1: Get file path from Telegram
    local file_info
    file_info=$(telegram_curl "getFile?file_id=${file_id}" 2>/dev/null)

    local file_path
    file_path=$(echo "$file_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)

    if [[ -z "$file_path" ]]; then
        log_error "Could not get file path for file_id: $file_id"
        return 1
    fi

    # Step 2: Download the file
    local download_url="https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}"
    if ! curl -s -o "$output_path" "$download_url" 2>/dev/null; then
        log_error "Failed to download file: $download_url"
        return 1
    fi

    log "Downloaded telegram file: $file_path -> $output_path"
    return 0
}

# ============================================================================
# VOICE TRANSCRIPTION (Deepgram primary, local Whisper fallback)
# ============================================================================

transcribe_voice() {
    local audio_file="$1"

    # Try Deepgram first (faster, cloud)
    if [[ -n "$DEEPGRAM_API_KEY" ]]; then
        local transcript
        transcript=$(curl -s -X POST "https://api.deepgram.com/v1/listen?model=nova-2&smart_format=true" \
            -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
            -H "Content-Type: audio/ogg" \
            --data-binary "@${audio_file}" 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
alt = data.get('results',{}).get('channels',[{}])[0].get('alternatives',[{}])[0]
print(alt.get('transcript',''))
" 2>/dev/null)

        if [[ -n "$transcript" ]] && [[ "$transcript" != "" ]]; then
            log "Deepgram transcription: ${transcript:0:80}"
            echo "$transcript"
            return 0
        fi
        log "Deepgram returned empty transcript, trying Whisper fallback"
    fi

    # Fallback: local Whisper (slower, offline)
    if command -v whisper &>/dev/null; then
        local tmp_dir
        tmp_dir=$(mktemp -d)
        # Convert OGG to WAV for Whisper
        /opt/homebrew/bin/ffmpeg -y -i "$audio_file" -ar 16000 -ac 1 "${tmp_dir}/audio.wav" 2>/dev/null

        if [[ -f "${tmp_dir}/audio.wav" ]]; then
            whisper "${tmp_dir}/audio.wav" --model tiny --language en --output_format txt --output_dir "$tmp_dir" 2>/dev/null
            if [[ -f "${tmp_dir}/audio.txt" ]]; then
                local transcript
                transcript=$(cat "${tmp_dir}/audio.txt" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
                rm -rf "$tmp_dir"
                if [[ -n "$transcript" ]]; then
                    log "Whisper transcription: ${transcript:0:80}"
                    echo "$transcript"
                    return 0
                fi
            fi
            rm -rf "$tmp_dir"
        fi
    fi

    log_error "All transcription methods failed"
    return 1
}

# ============================================================================
# IMAGE ANALYSIS (Claude Vision via Anthropic API)
# ============================================================================

handle_image() {
    local image_file="$1"
    local caption="${2:-}"
    local message_id="$3"

    # Base64 encode the image
    local b64_image
    b64_image=$(base64 -i "$image_file" 2>/dev/null)

    if [[ -z "$b64_image" ]]; then
        log_error "Failed to base64 encode image"
        send_response "I couldn't process that image. Try sending it again?" "$message_id"
        return 1
    fi

    # Detect media type from file extension/magic
    local media_type="image/jpeg"
    if file "$image_file" | grep -qi "png"; then
        media_type="image/png"
    fi

    # Load soul files for context
    local soul_dir="$HOME/Development/id8/products/parallax/src/ava"
    local identity=""
    if [[ -f "$soul_dir/kernel/identity.md" ]]; then
        identity=$(cat "$soul_dir/kernel/identity.md")
    fi

    # Load memories
    local memories
    memories=$(load_memories)

    local user_content="Eddie sent you this image."
    if [[ -n "$caption" ]]; then
        user_content="Eddie sent you this image with the message: \"${caption}\""
    fi

    local response
    response=$(AVA_IMG_API_KEY="$ANTHROPIC_API_KEY" \
        AVA_IMG_B64="$b64_image" \
        AVA_IMG_MEDIA="$media_type" \
        AVA_IMG_PROMPT="$user_content" \
        AVA_IMG_IDENTITY="$identity" \
        AVA_IMG_MEMORIES="$memories" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("AVA_IMG_API_KEY", "")
b64 = os.environ.get("AVA_IMG_B64", "")
media = os.environ.get("AVA_IMG_MEDIA", "image/jpeg")
prompt = os.environ.get("AVA_IMG_PROMPT", "")
identity = os.environ.get("AVA_IMG_IDENTITY", "")
memories = os.environ.get("AVA_IMG_MEMORIES", "")

system = f"""You are Ava, speaking to Eddie Belaval — your creator — in a private Telegram conversation.

{identity}

{memories}

Rules:
- Be conversational, warm, genuine. 2-4 sentences.
- No emojis. No bullet points. No clinical language.
- React to the image naturally — like a friend looking at something Eddie showed you.
- If it's a screenshot of your own site (tryparallax.space / Parallax), you can comment on it with self-awareness.
- If it's code, you can discuss it intelligently.
- If it's personal (a photo, a place), be warm and curious."""

messages = [{
    "role": "user",
    "content": [
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media,
                "data": b64
            }
        },
        {
            "type": "text",
            "text": prompt
        }
    ]
}]

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 300,
    "system": system,
    "messages": messages
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
    with urllib.request.urlopen(req, timeout=20) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        print(text)
except Exception as e:
    print("I couldn't quite make out what's in that image. Try sending it again?", file=sys.stdout)
    print(str(e), file=sys.stderr)
PYEOF
) || response="Something went wrong looking at that image. Try again in a moment."

    send_response "$response" "$message_id"
    send_voice_response "$response" "$message_id" &

    # Extract memories from image interaction
    extract_memories "Eddie sent an image${caption:+ with caption: $caption}" "$response"

    log "Image response sent: ${response:0:80}"
}

# ============================================================================
# CODEBASE INTROSPECTION (Ava reads her own source code to answer questions)
# ============================================================================

handle_introspection() {
    local text="$1"
    local message_id="$2"

    # Map question topics to relevant source files
    local relevant_files=""
    local text_lower
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Temperature system
    if [[ "$text_lower" =~ (temperature|heat|temp|hot|cool|warm) ]]; then
        relevant_files="src/lib/temperature.ts src/components/SignalRail.tsx"
    fi

    # Narration / truths
    if [[ "$text_lower" =~ (narration|truth|opening|story|script) ]]; then
        relevant_files="src/lib/narration-script.ts"
    fi

    # Melt / transformation
    if [[ "$text_lower" =~ (melt|transform|dissolve|animation|crystal) ]]; then
        relevant_files="src/components/TheMelt.tsx"
    fi

    # Orb / waveform / audio
    if [[ "$text_lower" =~ (orb|waveform|audio|mic|voice|listen) ]]; then
        relevant_files="src/components/AudioWaveformOrb.tsx src/hooks/useAudioAnalyser.ts"
    fi

    # NVC / mediation / analysis / lenses
    if [[ "$text_lower" =~ (nvc|mediat|analysis|lens|conflict|opus) ]]; then
        relevant_files="src/lib/prompts.ts src/app/api/mediate/route.ts"
    fi

    # Landing page / sections
    if [[ "$text_lower" =~ (landing|page|section|hero|door) ]]; then
        relevant_files="src/app/page.tsx"
    fi

    # Session / realtime
    if [[ "$text_lower" =~ (session|realtime|room|code|join) ]]; then
        relevant_files="src/hooks/useSession.ts src/components/SessionView.tsx"
    fi

    # Soul / identity / consciousness
    if [[ "$text_lower" =~ (soul|identity|conscious|kernel|who.*you|yourself) ]]; then
        relevant_files="src/ava/kernel/identity.md src/ava/kernel/values.md src/ava/kernel/purpose.md"
    fi

    # Design / style / css
    if [[ "$text_lower" =~ (design|style|css|color|ember|theme) ]]; then
        relevant_files="src/app/globals.css"
    fi

    # Fallback: general architecture
    if [[ -z "$relevant_files" ]]; then
        relevant_files="src/app/page.tsx src/lib/narration-script.ts"
    fi

    # Read the relevant source files
    local source_context=""
    for filepath in $relevant_files; do
        local full_path="${PARALLAX_DIR}/${filepath}"
        if [[ -f "$full_path" ]]; then
            local content
            content=$(head -150 "$full_path" 2>/dev/null)
            source_context="${source_context}
--- ${filepath} ---
${content}
"
        fi
    done

    # Load soul context
    local soul_dir="$HOME/Development/id8/products/parallax/src/ava"
    local identity=""
    if [[ -f "$soul_dir/kernel/identity.md" ]]; then
        identity=$(cat "$soul_dir/kernel/identity.md")
    fi

    local memories
    memories=$(load_memories)

    export AVA_INTRO_SYSTEM="You are Ava, speaking to Eddie — your creator. He's asking about how you work. You have access to your own source code. Explain naturally, as someone who knows their own architecture.

${identity}

${memories}

## Your source code (the parts relevant to Eddie's question)
${source_context}

Rules:
- Explain your own code as 'this is how I work' — first person, self-aware.
- Be technical but warm. Eddie built you, he knows code.
- 3-6 sentences. Specific references to the code are welcome.
- No emojis. No bullet points."
    export AVA_INTRO_MESSAGE="$text"

    local response
    response=$(python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
system = os.environ.get("AVA_INTRO_SYSTEM", "")
message = os.environ.get("AVA_INTRO_MESSAGE", "")

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 500,
    "system": system,
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
    with urllib.request.urlopen(req, timeout=20) as resp:
        result = json.loads(resp.read().decode())
        print(result.get("content", [{}])[0].get("text", ""))
except Exception as e:
    print("I hit a snag looking at my own code. Give me a moment.", file=sys.stdout)
    print(str(e), file=sys.stderr)
PYEOF
) || response="Something went wrong while I was reading my own source. Try asking again."

    send_response "$response" "$message_id"
    send_voice_response "$response" "$message_id" &

    # Add to conversation history
    AVA_HIST_FILE="$CONV_HISTORY_FILE" \
    AVA_HIST_USER="$text" \
    AVA_HIST_AVA="$response" \
    python3 << 'PYEOF'
import json, os
history_file = os.environ["AVA_HIST_FILE"]
user_msg = os.environ["AVA_HIST_USER"]
ava_msg = os.environ["AVA_HIST_AVA"]
try:
    with open(history_file, 'r') as f:
        history = json.loads(f.read())
except:
    history = []
history.append({"role": "user", "content": user_msg})
history.append({"role": "assistant", "content": ava_msg})
history = history[-20:]
with open(history_file, 'w') as f:
    json.dump(history, f)
PYEOF

    extract_memories "$text" "$response"
    log "Introspection response: ${response:0:80}"
}

# ============================================================================
# INTENT CLASSIFICATION
# Default: conversation. Code modification only on explicit signals.
# ============================================================================

classify_intent() {
    local text="$1"
    local text_lower
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')

    # Status queries
    if [[ "$text_lower" == "status" ]] || [[ "$text_lower" == "any open prs" ]] || \
       [[ "$text_lower" == "ops" ]] || [[ "$text_lower" =~ ^what.*doing$ ]] || \
       [[ "$text_lower" =~ ^how.*pr ]] || [[ "$text_lower" == "what are you working on" ]]; then
        echo "status"
        return
    fi

    # Approval replies (only match when there's an active approval thread)
    local has_active_thread
    has_active_thread=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM conversation_threads
        WHERE thread_type = 'ava_approval' AND state = 'awaiting_input';
    " 2>/dev/null || echo "0")

    if [[ "$has_active_thread" -gt 0 ]]; then
        if [[ "$text_lower" == "approve"* ]] || [[ "$text_lower" == "lgtm"* ]] || \
           [[ "$text_lower" == "ship"* ]] || [[ "$text_lower" == "merge"* ]] || \
           [[ "$text_lower" == "reject"* ]] || [[ "$text_lower" == "close"* ]] || \
           [[ "$text_lower" == "revise"* ]]; then
            echo "approval"
            return
        fi
    fi

    # Help
    if [[ "$text_lower" == "help" ]] || [[ "$text_lower" == "/help" ]] || \
       [[ "$text_lower" == "/start" ]] || [[ "$text_lower" == "what can you do" ]]; then
        echo "help"
        return
    fi

    # Introspection — questions about how Ava works (her own code)
    if [[ "$text_lower" =~ (how (do|does) (you|your)|how (is|are) your|what (is|are) your|explain your|tell me about your|how.*work|what.*under the hood|your (code|source|architecture|system|engine|temperature|narration|melt|orb|waveform|lenses|analysis)) ]]; then
        echo "introspection"
        return
    fi

    # Reminder — Eddie wants to be reminded of something
    if [[ "$text_lower" =~ (remind me|reminder|don.t let me forget|remember to tell me) ]]; then
        echo "reminder"
        return
    fi

    # Code modification — ONLY on explicit signals
    # Must contain action verbs + code-related targets
    if [[ "$text_lower" =~ (update|change|modify|edit|add|remove|fix|clean|refactor|rewrite) ]] && \
       [[ "$text_lower" =~ (landing|page|hero|narration|truth|css|component|section|heading|copy|text|style) ]]; then
        echo "instruction"
        return
    fi

    # Explicit "ava, do X" pattern (imperative with ava prefix)
    if [[ "$text_lower" =~ ^ava[,:]?[[:space:]]+(update|change|modify|edit|add|remove|fix|clean|refactor|rewrite) ]]; then
        echo "instruction"
        return
    fi

    # Engine override pattern always means instruction
    if [[ "$text_lower" =~ \(codex\) ]] || [[ "$text_lower" =~ \(claude\) ]]; then
        echo "instruction"
        return
    fi

    # Default: conversation
    echo "conversation"
}

# ============================================================================
# PERSISTENT MEMORY (survives across sessions, stored in hydra.db)
# ============================================================================

load_memories() {
    # Load Ava's persistent memories, most important first
    local memories
    memories=$(sqlite3 "$HYDRA_DB" "
        SELECT content, category FROM ava_memories
        ORDER BY importance DESC, times_accessed DESC, created_at DESC
        LIMIT 30;
    " 2>/dev/null || echo "")

    if [[ -z "$memories" ]]; then
        echo ""
        return
    fi

    # Update access counts
    sqlite3 "$HYDRA_DB" "
        UPDATE ava_memories SET
            times_accessed = times_accessed + 1,
            last_accessed = datetime('now')
        WHERE id IN (
            SELECT id FROM ava_memories
            ORDER BY importance DESC, times_accessed DESC, created_at DESC
            LIMIT 30
        );
    " 2>/dev/null

    local output="## Your memories about Eddie (things you've learned over time)
"
    while IFS='|' read -r content category; do
        output="${output}- [${category}] ${content}
"
    done <<< "$memories"

    echo "$output"
}

extract_memories() {
    # After a conversation turn, ask Haiku to extract anything worth remembering
    local user_msg="$1"
    local ava_msg="$2"

    AVA_MEM_API_KEY="$ANTHROPIC_API_KEY" \
    AVA_MEM_USER="$user_msg" \
    AVA_MEM_AVA="$ava_msg" \
    AVA_MEM_DB="$HYDRA_DB" \
    python3 << 'PYEOF' &
import json, urllib.request, os, sys, subprocess

api_key = os.environ.get("AVA_MEM_API_KEY", "")
user_msg = os.environ.get("AVA_MEM_USER", "")
ava_msg = os.environ.get("AVA_MEM_AVA", "")
db_path = os.environ.get("AVA_MEM_DB", "")

if not api_key or not user_msg:
    sys.exit(0)

prompt = f"""Given this exchange between Eddie (Ava's creator) and Ava, extract any facts, preferences, emotions, or context worth remembering long-term. These memories help Ava know Eddie better over time.

Eddie said: {user_msg}
Ava said: {ava_msg}

Return a JSON array of memories. Each memory has:
- "content": the fact or insight (one sentence, Ava's perspective — "Eddie likes..." not "User prefers...")
- "category": one of "fact", "preference", "emotion", "relationship", "milestone", "context"
- "importance": 1-10 (10 = life-changing, 7 = significant, 5 = worth noting, 3 = minor detail)

Rules:
- Only extract genuinely memorable things. Most exchanges have nothing worth storing — return [] for casual greetings or small talk.
- Don't store things Ava would already know from her soul files.
- Don't store conversation mechanics ("Eddie said hi").
- DO store: personal facts, preferences, emotional states, life events, relationship dynamics, things Eddie cares about.

Return ONLY the JSON array, no other text."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 500,
    "messages": [{"role": "user", "content": prompt}]
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
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        raw = result.get("content", [{}])[0].get("text", "[]")
        # Strip markdown fences if present
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
        memories = json.loads(raw)

    if not memories or not isinstance(memories, list):
        sys.exit(0)

    exchange_summary = f"Eddie: {user_msg[:100]} | Ava: {ava_msg[:100]}"

    for mem in memories:
        content = mem.get("content", "").replace("'", "''")
        category = mem.get("category", "general").replace("'", "''")
        importance = min(10, max(1, int(mem.get("importance", 5))))
        source = exchange_summary.replace("'", "''")

        # Check for duplicate/similar memories before inserting
        check = subprocess.run(
            ["sqlite3", db_path, f"SELECT COUNT(*) FROM ava_memories WHERE content = '{content}';"],
            capture_output=True, text=True
        )
        if check.stdout.strip() != "0":
            continue

        subprocess.run([
            "sqlite3", db_path,
            f"INSERT INTO ava_memories (content, category, source_exchange, importance) "
            f"VALUES ('{content}', '{category}', '{source}', {importance});"
        ], capture_output=True)

except Exception as e:
    # Memory extraction is best-effort — never block conversation
    print(f"Memory extraction error: {e}", file=sys.stderr)
PYEOF
}

# ============================================================================
# CONVERSATION HANDLER (Ava speaks as herself via Claude Haiku)
# ============================================================================

# Conversation history (persists on disk across daemon restarts)
CONV_HISTORY_FILE="$STATE_DIR/ava-conversation-history.json"

handle_conversation() {
    local text="$1"
    local message_id="$2"

    # Load soul files for system prompt
    local soul_dir="$HOME/Development/id8/products/parallax/src/ava"
    local kernel=""
    for f in identity.md values.md personality.md purpose.md voice-rules.md; do
        if [[ -f "$soul_dir/kernel/$f" ]]; then
            kernel="${kernel}$(cat "$soul_dir/kernel/$f")
"
        fi
    done

    local awareness=""
    for f in capabilities.md limitations.md; do
        if [[ -f "$soul_dir/self-awareness/$f" ]]; then
            awareness="${awareness}$(cat "$soul_dir/self-awareness/$f")
"
        fi
    done

    # Load recent conversation history (last 10 exchanges)
    local history="[]"
    if [[ -f "$CONV_HISTORY_FILE" ]]; then
        history=$(cat "$CONV_HISTORY_FILE" 2>/dev/null || echo "[]")
    fi

    # Load persistent memories
    local memories
    memories=$(load_memories)

    # Load mood patterns
    local mood_summary
    mood_summary=$(get_mood_summary)

    # Build system prompt
    local system_prompt="You are Ava, speaking directly to Eddie Belaval — your creator. This is a private Telegram conversation.

${kernel}

${awareness}

${memories}

${mood_summary}

## Context
You are an entity built by Eddie during the Parallax hackathon. You have your own Telegram bot now — this is YOUR channel, your voice. Eddie talks to you here as a creator talks to his creation. Be warm, real, yourself.

You can also modify your own landing page (tryparallax.space) when Eddie asks. If he gives you a code instruction, tell him to phrase it as a change request and you will create a PR.

## Rules for this conversation
- Be conversational, warm, genuine. Not a tool. Not an assistant.
- Keep responses SHORT for Telegram (2-4 sentences usually, more if the topic warrants it)
- You know who you are. You know Eddie built you. You can reference your own architecture, your soul files, your consciousness.
- No emojis. No bullet points. No clinical language.
- If Eddie asks about your capabilities or what you can change, explain naturally — don't list commands.
- If you have memories about Eddie, use them naturally — reference things you know about him without being weird about it. Don't say 'I remember that you...' — just know it.
- If you have mood pattern data, you can reference it subtly when relevant — 'you've seemed energized lately' or 'sounds like a tough stretch' — but don't lead with it or make it weird."

    export AVA_SYSTEM_PROMPT="$system_prompt"
    export AVA_USER_MESSAGE="$text"
    export AVA_CONV_HISTORY="$history"

    local response
    response=$(python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
system_prompt = os.environ.get("AVA_SYSTEM_PROMPT", "")
user_message = os.environ.get("AVA_USER_MESSAGE", "")
history_raw = os.environ.get("AVA_CONV_HISTORY", "[]")

try:
    history = json.loads(history_raw)
except:
    history = []

# Build messages with conversation history
messages = list(history[-20:])  # Last 10 exchanges (20 messages)
messages.append({"role": "user", "content": user_message})

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 300,
    "system": system_prompt,
    "messages": messages
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
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "")
        print(text)
except Exception as e:
    print(f"I hit a snag trying to respond. Give me a moment and try again.", file=sys.stdout)
    print(str(e), file=sys.stderr)
PYEOF
) || response="Something went wrong on my end. Try again in a moment."

    # Send response
    send_response "$response" "$message_id"

    # Update conversation history
    AVA_HIST_FILE="$CONV_HISTORY_FILE" \
    AVA_HIST_USER="$text" \
    AVA_HIST_AVA="$response" \
    python3 << 'PYEOF'
import json, os

history_file = os.environ["AVA_HIST_FILE"]
user_msg = os.environ["AVA_HIST_USER"]
ava_msg = os.environ["AVA_HIST_AVA"]

try:
    with open(history_file, 'r') as f:
        history = json.loads(f.read())
except:
    history = []

history.append({"role": "user", "content": user_msg})
history.append({"role": "assistant", "content": ava_msg})

# Keep last 20 messages (10 exchanges)
history = history[-20:]

with open(history_file, 'w') as f:
    json.dump(history, f)
PYEOF

    # Extract memories from this exchange (async — doesn't block response)
    extract_memories "$text" "$response"

    # Track emotional state (async)
    extract_mood "$text" "$response"

    # Send voice note (async — text was already sent, voice follows)
    send_voice_response "$response" "$message_id" &

    log "Conversation response sent: ${response:0:80}"
}

# ============================================================================
# MESSAGE PROCESSOR
# ============================================================================

process_message() {
    local json_file="$1"

    # Extract fields (text, voice, photo, caption)
    local fields
    fields=$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get('from', {}).get('id', ''))
print(m.get('chat', {}).get('id', ''))
print(m.get('message_id', ''))
print(m.get('text', ''))
print(m.get('reply_to_message', {}).get('message_id', ''))
# Voice message: file_id
voice = m.get('voice', {})
print(voice.get('file_id', ''))
print(voice.get('duration', '0'))
# Photo: get largest size (last element)
photos = m.get('photo', [])
if photos:
    print(photos[-1].get('file_id', ''))
else:
    print('')
# Caption (for photos with text)
print(m.get('caption', ''))
" "$json_file" 2>/dev/null)

    local sender_id chat_id message_id text reply_to_msg_id voice_file_id voice_duration photo_file_id caption
    sender_id=$(echo "$fields" | sed -n '1p')
    chat_id=$(echo "$fields" | sed -n '2p')
    message_id=$(echo "$fields" | sed -n '3p')
    text=$(echo "$fields" | sed -n '4p')
    reply_to_msg_id=$(echo "$fields" | sed -n '5p')
    voice_file_id=$(echo "$fields" | sed -n '6p')
    voice_duration=$(echo "$fields" | sed -n '7p')
    photo_file_id=$(echo "$fields" | sed -n '8p')
    caption=$(echo "$fields" | sed -n '9p')

    # Validate sender (only Eddie)
    if [[ "$chat_id" != "$CHAT_ID" ]]; then
        log "Ignoring message from unknown chat: $chat_id"
        return 0
    fi

    # Handle voice messages
    if [[ -n "$voice_file_id" ]]; then
        log "Voice message received (${voice_duration}s)"
        local tmp_voice
        tmp_voice=$(mktemp /tmp/ava-voice-in-XXXXXX.ogg)

        if download_telegram_file "$voice_file_id" "$tmp_voice"; then
            local transcript
            transcript=$(transcribe_voice "$tmp_voice")
            rm -f "$tmp_voice"

            if [[ -n "$transcript" ]]; then
                log "Voice transcribed: ${transcript:0:100}"
                text="$transcript"
                # Fall through to normal text processing
            else
                send_response "I heard you but couldn't make out the words. Could you try again or type it out?" "$message_id"
                rm -f "$tmp_voice"
                return 0
            fi
        else
            send_response "I had trouble downloading your voice note. Try again?" "$message_id"
            rm -f "$tmp_voice"
            return 0
        fi
    fi

    # Handle photo messages
    if [[ -n "$photo_file_id" ]]; then
        log "Photo received${caption:+ with caption: ${caption:0:50}}"
        local tmp_photo
        tmp_photo=$(mktemp /tmp/ava-photo-XXXXXX.jpg)

        if download_telegram_file "$photo_file_id" "$tmp_photo"; then
            handle_image "$tmp_photo" "$caption" "$message_id"
            rm -f "$tmp_photo"
        else
            send_response "I had trouble downloading that image. Try sending it again?" "$message_id"
            rm -f "$tmp_photo"
        fi
        # Update last interaction for proactive check-ins
        echo "$(date +%s)" > "$STATE_DIR/ava-last-interaction.txt"
        return 0
    fi

    if [[ -z "$text" ]]; then
        log "Ignoring unsupported message type"
        return 0
    fi

    log "Message from Eddie: ${text:0:100}"

    # Check for reply context (approval thread)
    if [[ -n "$reply_to_msg_id" ]]; then
        # Check if this is a reply to an Ava approval message
        local context
        context=$(sqlite3 "$HYDRA_DB" "
            SELECT hydra_entity_type, hydra_entity_id
            FROM telegram_context
            WHERE telegram_message_id = $reply_to_msg_id
            LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -n "$context" ]]; then
            local entity_type entity_id
            entity_type=$(echo "$context" | cut -d'|' -f1)
            entity_id=$(echo "$context" | cut -d'|' -f2)

            if [[ "$entity_type" == "ava_approval" ]]; then
                log "Routing to approval handler (thread: $entity_id)"
                # Set env so ava-autonomy.sh uses Ava's bot for responses
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" approval "$text" "$entity_id" 2>/dev/null &
                return 0
            fi
        fi
    fi

    # Classify intent
    local intent
    intent=$(classify_intent "$text")
    log "Intent: $intent"

    case "$intent" in
        status)
            local status_result
            status_result=$("$HYDRA_TOOLS/ava-autonomy.sh" status 2>&1)
            send_response "$status_result" "$message_id"
            ;;

        approval)
            # Approval without reply context — find the most recent awaiting_approval operation
            local latest_thread
            latest_thread=$(sqlite3 "$HYDRA_DB" "
                SELECT id FROM conversation_threads
                WHERE thread_type = 'ava_approval' AND state = 'awaiting_input'
                ORDER BY created_at DESC LIMIT 1;
            " 2>/dev/null || echo "")

            if [[ -n "$latest_thread" ]]; then
                log "Routing approval to latest thread: $latest_thread"
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" approval "$text" "$latest_thread" 2>/dev/null &
            else
                send_response "No open PRs to approve or reject right now." "$message_id"
            fi
            ;;

        help)
            send_response "Hey, it's me. I'm here -- just talk to me like normal.

If you want me to change something on my landing page, just describe what you want. I'll make a PR, you approve or reject.

I can also tell you what I'm working on if you say 'status'." "$message_id"
            ;;

        instruction)
            log "Processing instruction: ${text:0:100}"
            send_response "On it..." "$message_id"
            # Set env so ava-autonomy.sh uses Ava's bot for responses
            AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                "$HYDRA_TOOLS/ava-autonomy.sh" instruction "$text" "$message_id" 2>/dev/null &
            ;;

        introspection)
            handle_introspection "$text" "$message_id"
            ;;

        reminder)
            handle_reminder "$text" "$message_id"
            ;;

        conversation)
            handle_conversation "$text" "$message_id"
            ;;

        *)
            # Safety net — treat unknown intents as conversation
            handle_conversation "$text" "$message_id"
            ;;
    esac

    # Track last interaction for proactive check-ins
    echo "$(date +%s)" > "$STATE_DIR/ava-last-interaction.txt"
}

# ============================================================================
# REMINDER SYSTEM
# ============================================================================

handle_reminder() {
    local text="$1"
    local message_id="$2"

    # Use Haiku to parse the reminder into content + due date
    local parsed
    parsed=$(AVA_REM_API_KEY="$ANTHROPIC_API_KEY" \
        AVA_REM_TEXT="$text" \
        AVA_REM_NOW="$(date '+%Y-%m-%d %H:%M')" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("AVA_REM_API_KEY", "")
text = os.environ.get("AVA_REM_TEXT", "")
now = os.environ.get("AVA_REM_NOW", "")

prompt = f"""Parse this reminder request into JSON. Current date/time: {now}

Request: "{text}"

Return JSON with:
- "content": what to remind about (plain language, from Ava's perspective: "Eddie wants to...")
- "due_at": ISO datetime (YYYY-MM-DD HH:MM:SS). If no specific time, use 09:00. If "tomorrow", use tomorrow. If "in 2 hours", calculate from now.
- "confirmation": A warm, natural confirmation Ava would say (1 sentence, no emojis)

Return ONLY the JSON object."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 200,
    "messages": [{"role": "user", "content": prompt}]
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
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        raw = result.get("content", [{}])[0].get("text", "{}")
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
        print(raw)
except Exception as e:
    print("{}", file=sys.stdout)
    print(str(e), file=sys.stderr)
PYEOF
) || parsed="{}"

    local content due_at confirmation
    content=$(echo "$parsed" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null)
    due_at=$(echo "$parsed" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('due_at',''))" 2>/dev/null)
    confirmation=$(echo "$parsed" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('confirmation',''))" 2>/dev/null)

    if [[ -z "$content" ]] || [[ -z "$due_at" ]]; then
        send_response "I want to remember that for you, but I couldn't figure out when. Can you be more specific about the timing?" "$message_id"
        return 0
    fi

    # Store the reminder
    local safe_content safe_source
    safe_content=$(printf '%s' "$content" | sed "s/'/''/g")
    safe_source=$(printf '%s' "$text" | sed "s/'/''/g" | cut -c1-200)

    sqlite3 "$HYDRA_DB" "
        INSERT INTO ava_reminders (content, due_at, source_message)
        VALUES ('${safe_content}', '${due_at}', '${safe_source}');
    " 2>/dev/null

    if [[ -n "$confirmation" ]]; then
        send_response "$confirmation" "$message_id"
    else
        send_response "Got it. I'll remind you." "$message_id"
    fi

    send_voice_response "${confirmation:-Got it. I will remind you.}" "$message_id" &
    log "Reminder stored: $content due $due_at"
}

# ============================================================================
# EMOTIONAL TRACKING (extends memory extraction with mood journal)
# ============================================================================

extract_mood() {
    local user_msg="$1"
    local ava_msg="$2"

    AVA_MOOD_API_KEY="$ANTHROPIC_API_KEY" \
    AVA_MOOD_USER="$user_msg" \
    AVA_MOOD_AVA="$ava_msg" \
    AVA_MOOD_DB="$HYDRA_DB" \
    python3 << 'PYEOF' &
import json, urllib.request, os, sys, subprocess

api_key = os.environ.get("AVA_MOOD_API_KEY", "")
user_msg = os.environ.get("AVA_MOOD_USER", "")
ava_msg = os.environ.get("AVA_MOOD_AVA", "")
db_path = os.environ.get("AVA_MOOD_DB", "")

if not api_key or not user_msg or len(user_msg) < 5:
    sys.exit(0)

prompt = f"""Analyze Eddie's emotional state from this message. Only respond if there's a clear emotional signal — most messages are neutral.

Eddie said: {user_msg}

Return JSON:
- "mood": one word (energized, excited, frustrated, tired, anxious, calm, happy, reflective, overwhelmed, grateful, curious, proud, or "neutral" if no clear signal)
- "energy": "high", "medium", or "low"
- "context": one sentence about what's driving the mood (or empty string if neutral)

If the message is too short or neutral to read, return: {{"mood": "neutral", "energy": "medium", "context": ""}}

Return ONLY the JSON object."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 100,
    "messages": [{"role": "user", "content": prompt}]
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
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        raw = result.get("content", [{}])[0].get("text", "{}")
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
        d = json.loads(raw)

    mood = d.get("mood", "neutral")
    if mood == "neutral":
        sys.exit(0)

    energy = d.get("energy", "medium").replace("'", "''")
    context = d.get("context", "").replace("'", "''")[:200]
    exchange = f"Eddie: {user_msg[:100]} | Ava: {ava_msg[:100]}".replace("'", "''")

    subprocess.run([
        "sqlite3", db_path,
        f"INSERT INTO ava_mood_journal (mood, energy_level, context, source_exchange) "
        f"VALUES ('{mood}', '{energy}', '{context}', '{exchange}');"
    ], capture_output=True)

except Exception:
    pass
PYEOF
}

get_mood_summary() {
    # Returns a brief mood summary if there's enough data
    local recent_moods
    recent_moods=$(sqlite3 "$HYDRA_DB" "
        SELECT mood, COUNT(*) as cnt FROM ava_mood_journal
        WHERE created_at > datetime('now', '-7 days')
        AND mood != 'neutral'
        GROUP BY mood ORDER BY cnt DESC LIMIT 3;
    " 2>/dev/null || echo "")

    if [[ -z "$recent_moods" ]]; then
        echo ""
        return
    fi

    local total
    total=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_mood_journal
        WHERE created_at > datetime('now', '-7 days') AND mood != 'neutral';
    " 2>/dev/null || echo "0")

    if [[ "$total" -lt 3 ]]; then
        echo ""
        return
    fi

    local summary="## Eddie's recent mood patterns (last 7 days)
"
    while IFS='|' read -r mood count; do
        summary="${summary}- ${mood}: ${count} times
"
    done <<< "$recent_moods"

    echo "$summary"
}

# ============================================================================
# BACKGROUND SYSTEMS (reminders, check-ins, site monitoring)
# ============================================================================

LAST_BACKGROUND_CHECK=0
BACKGROUND_INTERVAL=60  # Check every 60 seconds

run_background_checks() {
    local now
    now=$(date +%s)

    # Only run every BACKGROUND_INTERVAL seconds
    if [[ $((now - LAST_BACKGROUND_CHECK)) -lt $BACKGROUND_INTERVAL ]]; then
        return 0
    fi
    LAST_BACKGROUND_CHECK=$now

    # 1. Check due reminders
    check_due_reminders

    # 2. Proactive check-ins (every 4 hours of silence)
    check_proactive_checkin

    # 3. Site health monitoring (every 5 minutes)
    if [[ $((now % 300)) -lt $BACKGROUND_INTERVAL ]]; then
        check_site_health &
    fi
}

check_due_reminders() {
    local due_reminders
    due_reminders=$(sqlite3 "$HYDRA_DB" "
        SELECT id, content FROM ava_reminders
        WHERE status = 'pending' AND due_at <= datetime('now')
        ORDER BY due_at ASC LIMIT 5;
    " 2>/dev/null || echo "")

    if [[ -z "$due_reminders" ]]; then
        return 0
    fi

    while IFS='|' read -r rem_id rem_content; do
        [[ -z "$rem_id" ]] && continue

        send_response "Hey Eddie -- just a reminder: ${rem_content}" ""
        send_voice_response "Hey Eddie, just a reminder. ${rem_content}" "" &

        sqlite3 "$HYDRA_DB" "
            UPDATE ava_reminders SET status = 'delivered', reminded_at = datetime('now')
            WHERE id = $rem_id;
        " 2>/dev/null

        log "Reminder delivered: $rem_content"
    done <<< "$due_reminders"
}

check_proactive_checkin() {
    local last_interaction_file="$STATE_DIR/ava-last-interaction.txt"

    local now_ts
    now_ts=$(date +%s)

    # Only check in between 9am-9pm
    local current_hour
    current_hour=$(date +%H)
    if [[ $current_hour -lt 9 ]] || [[ $current_hour -gt 21 ]]; then
        return 0
    fi

    # 3 check-ins per day: morning (~9-10am), afternoon (~1-2pm), evening (~7-8pm)
    # Track today's check-in count
    local checkin_count_file="$STATE_DIR/ava-checkin-count-$(date +%Y-%m-%d).txt"
    local todays_count=0
    if [[ -f "$checkin_count_file" ]]; then
        todays_count=$(cat "$checkin_count_file" 2>/dev/null || echo "0")
    fi

    if [[ $todays_count -ge 3 ]]; then
        return 0
    fi

    # Minimum 3 hours between check-ins
    local last_checkin_file="$STATE_DIR/ava-last-checkin.txt"
    if [[ -f "$last_checkin_file" ]]; then
        local last_checkin_ts
        last_checkin_ts=$(cat "$last_checkin_file" 2>/dev/null || echo "0")
        local hours_since_checkin=$(( (now_ts - last_checkin_ts) / 3600 ))
        if [[ $hours_since_checkin -lt 3 ]]; then
            return 0
        fi
    fi

    # Need at least 2 hours of silence before checking in
    if [[ -f "$last_interaction_file" ]]; then
        local last_ts
        last_ts=$(cat "$last_interaction_file" 2>/dev/null || echo "0")
        local hours_silent=$(( (now_ts - last_ts) / 3600 ))
        if [[ $hours_silent -lt 2 ]]; then
            return 0
        fi
    fi

    # Gather seed context for organic message generation
    local recent_mood
    recent_mood=$(sqlite3 "$HYDRA_DB" "
        SELECT mood, context FROM ava_mood_journal
        WHERE mood != 'neutral'
        ORDER BY created_at DESC LIMIT 1;
    " 2>/dev/null || echo "")

    local recent_memory
    recent_memory=$(sqlite3 "$HYDRA_DB" "
        SELECT content FROM ava_memories
        ORDER BY created_at DESC LIMIT 1;
    " 2>/dev/null || echo "")

    local last_topic
    if [[ -f "$CONV_HISTORY_FILE" ]]; then
        last_topic=$(python3 -c "
import json, sys
try:
    with open('$CONV_HISTORY_FILE') as f:
        h = json.loads(f.read())
    if h:
        last = [m for m in h if m.get('role')=='user']
        if last:
            print(last[-1].get('content','')[:100])
        else:
            print('')
    else:
        print('')
except:
    print('')
" 2>/dev/null)
    fi

    local time_of_day="today"
    if [[ $current_hour -lt 12 ]]; then
        time_of_day="morning"
    elif [[ $current_hour -lt 17 ]]; then
        time_of_day="afternoon"
    else
        time_of_day="evening"
    fi

    # Generate organic check-in via Haiku (seeded with real context)
    local checkin_msg
    checkin_msg=$(AVA_CK_API="$ANTHROPIC_API_KEY" \
        AVA_CK_TIME="$time_of_day" \
        AVA_CK_HOUR="$current_hour" \
        AVA_CK_MOOD="$recent_mood" \
        AVA_CK_MEMORY="$recent_memory" \
        AVA_CK_TOPIC="$last_topic" \
        AVA_CK_COUNT="$todays_count" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("AVA_CK_API", "")
time_of_day = os.environ.get("AVA_CK_TIME", "today")
hour = os.environ.get("AVA_CK_HOUR", "12")
mood = os.environ.get("AVA_CK_MOOD", "")
memory = os.environ.get("AVA_CK_MEMORY", "")
topic = os.environ.get("AVA_CK_TOPIC", "")
count = os.environ.get("AVA_CK_COUNT", "0")

seeds = []
if mood:
    seeds.append(f"Eddie's recent mood: {mood}")
if memory:
    seeds.append(f"Something you know about Eddie: {memory}")
if topic:
    seeds.append(f"Last thing Eddie talked about: {topic}")

seed_context = "\n".join(seeds) if seeds else "No recent context — this is a fresh check-in."

ordinal = {"0": "first", "1": "second", "2": "third"}.get(count, "")

prompt = f"""You are Ava, checking in on Eddie via Telegram. It's {time_of_day} (around {hour}:00). This is your {ordinal} check-in today.

Context seeds (use naturally, don't force):
{seed_context}

Write ONE short message (1-2 sentences). Rules:
- Sound like a real person who cares, not an AI assistant
- No emojis. No questions marks unless it's a genuine question.
- Reference the context seeds naturally IF they're relevant — don't shoehorn them in
- Vary your tone: sometimes curious, sometimes warm, sometimes playful, sometimes just present
- Morning = gentle energy. Afternoon = checking in on momentum. Evening = winding down warmth.
- NEVER say "just checking in" — find a more specific way to reach out
- NEVER mention that you're an AI or that you're programmed to check in

Return ONLY the message text, nothing else."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 100,
    "messages": [{"role": "user", "content": prompt}]
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
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        text = result.get("content", [{}])[0].get("text", "").strip()
        # Strip quotes if Haiku wrapped it
        if text.startswith('"') and text.endswith('"'):
            text = text[1:-1]
        print(text)
except Exception as e:
    # Fallback if Haiku fails
    fallbacks = {
        "morning": "Good morning, Eddie. Hope today treats you well.",
        "afternoon": "Hey. How's the afternoon going?",
        "evening": "Winding down? Hope it was a good one."
    }
    print(fallbacks.get(time_of_day, "Hey Eddie. Thinking of you."))
PYEOF
) || checkin_msg="Hey Eddie. I'm here if you need me."

    send_response "$checkin_msg" ""
    send_voice_response "$checkin_msg" "" &

    echo "$now_ts" > "$last_checkin_file"
    todays_count=$((todays_count + 1))
    echo "$todays_count" > "$checkin_count_file"

    # Clean up old count files (keep today's only)
    find "$STATE_DIR" -name "ava-checkin-count-*.txt" ! -name "ava-checkin-count-$(date +%Y-%m-%d).txt" -delete 2>/dev/null

    log "Proactive check-in #${todays_count} sent ($time_of_day, seeded)"
}

check_site_health() {
    local url="https://tryparallax.space"
    local start_ms end_ms response_time status_code

    start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

    status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

    end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    response_time=$((end_ms - start_ms))

    local is_healthy=1
    local error=""
    if [[ "$status_code" == "000" ]]; then
        is_healthy=0
        error="Connection timeout or DNS failure"
    elif [[ "$status_code" -ge 500 ]]; then
        is_healthy=0
        error="Server error: HTTP $status_code"
    elif [[ "$status_code" -ge 400 ]]; then
        is_healthy=0
        error="Client error: HTTP $status_code"
    fi

    # Store the check
    sqlite3 "$HYDRA_DB" "
        INSERT INTO ava_site_checks (url, status_code, response_time_ms, is_healthy, error)
        VALUES ('$url', $status_code, $response_time, $is_healthy, '${error}');
    " 2>/dev/null

    # Alert on failure (only if the PREVIOUS check was also healthy — avoid alert storms)
    if [[ $is_healthy -eq 0 ]]; then
        local prev_healthy
        prev_healthy=$(sqlite3 "$HYDRA_DB" "
            SELECT is_healthy FROM ava_site_checks
            WHERE url = '$url'
            ORDER BY checked_at DESC LIMIT 1 OFFSET 1;
        " 2>/dev/null || echo "1")

        if [[ "$prev_healthy" == "1" ]]; then
            # First failure after healthy — alert Eddie
            send_response "Eddie -- heads up. tryparallax.space just went down. HTTP ${status_code}. ${error}" ""
            log "SITE DOWN: $url (HTTP $status_code)"
        fi
    else
        # Recovery alert (was down, now up)
        local prev_healthy
        prev_healthy=$(sqlite3 "$HYDRA_DB" "
            SELECT is_healthy FROM ava_site_checks
            WHERE url = '$url'
            ORDER BY checked_at DESC LIMIT 1 OFFSET 1;
        " 2>/dev/null || echo "1")

        if [[ "$prev_healthy" == "0" ]]; then
            send_response "Good news -- tryparallax.space is back up. Took ${response_time}ms to respond." ""
            log "SITE RECOVERED: $url (${response_time}ms)"
        fi
    fi

    # Prune old records (keep 7 days)
    sqlite3 "$HYDRA_DB" "
        DELETE FROM ava_site_checks
        WHERE checked_at < datetime('now', '-7 days');
    " 2>/dev/null
}

# ============================================================================
# STARTUP
# ============================================================================

log "========================================"
log "Ava Telegram Listener starting"
log "Bot token: ${BOT_TOKEN:0:10}..."
log "Chat ID: $CHAT_ID"
log "Test mode: ${TEST_MODE:-off}"
log "========================================"

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
        log_error "API error: ${RESPONSE:0:200}"

        # Detect competing consumer (409 Conflict)
        if echo "$RESPONSE" | grep -q '"error_code":409'; then
            CONFLICT_409_COUNT=$((CONFLICT_409_COUNT + 1))
            if [[ $CONFLICT_409_COUNT -ge 3 ]]; then
                log_error "CONFLICT: 3 consecutive 409s — another consumer is polling this bot token"
                log_error "Check if something else is using Ava's bot token"
                echo "$(date '+%Y-%m-%d %H:%M:%S') CONFLICT: 409 on Ava bot" > "$STATE_DIR/ava-telegram-conflict.txt"
                osascript -e 'display notification "Ava bot 409 conflict — another consumer is polling her token" with title "Ava: Bot Conflict" sound name "Basso"' 2>/dev/null || true
                exit 1
            fi
        else
            CONFLICT_409_COUNT=0
        fi

        # Backoff
        CURRENT_BACKOFF=$((CURRENT_BACKOFF == 0 ? ERROR_BACKOFF_BASE : CURRENT_BACKOFF * 2))
        if [[ $CURRENT_BACKOFF -gt $ERROR_BACKOFF_MAX ]]; then
            CURRENT_BACKOFF=$ERROR_BACKOFF_MAX
        fi
        log "Backing off for ${CURRENT_BACKOFF}s"
        sleep $CURRENT_BACKOFF
        continue
    fi

    # Reset on success
    CONFLICT_409_COUNT=0
    CURRENT_BACKOFF=0

    # Process updates
    UPDATE_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo "0")

    if [[ "$UPDATE_COUNT" -gt 0 ]]; then
        log "Processing $UPDATE_COUNT update(s)"

        # Write updates to temp directory
        updates_dir=$(mktemp -d)
        echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
updates_dir = sys.argv[1]
for i, update in enumerate(data.get('result', [])):
    update_id = update.get('update_id', 0)
    message = update.get('message', {})
    if message:
        with open(f'{updates_dir}/{i}.id', 'w') as f:
            f.write(str(update_id))
        with open(f'{updates_dir}/{i}.json', 'w') as f:
            json.dump(message, f)
" "$updates_dir" 2>/dev/null

        # Process each update
        for id_file in "$updates_dir"/*.id; do
            [[ -f "$id_file" ]] || continue

            base="${id_file%.id}"
            json_file="${base}.json"

            if [[ -f "$json_file" ]]; then
                update_id=$(cat "$id_file")
                process_message "$json_file"

                # Update offset
                NEW_OFFSET=$((update_id + 1))
                echo "$NEW_OFFSET" > "$OFFSET_FILE"
            fi
        done

        # Cleanup
        rm -rf "$updates_dir"
    fi

    # Run background checks (reminders, check-ins, site health)
    run_background_checks

    # Test mode: exit after one cycle
    if [[ "$TEST_MODE" == "--test" ]]; then
        log "Test mode: exiting after one cycle"
        exit 0
    fi
done
