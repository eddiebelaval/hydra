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

# Load Supabase credentials (for context ingest sync to Parallax web)
AVA_SYNC_CONFIG="$HYDRA_ROOT/config/ava-sync.env"
SUPABASE_URL=""
SUPABASE_SERVICE_ROLE_KEY=""
EDDIE_USER_ID="5e6b0b3e-26f6-43ca-8586-0e8b6b090c08"
if [[ -f "$AVA_SYNC_CONFIG" ]]; then
    SUPABASE_URL=$(grep '^SUPABASE_URL=' "$AVA_SYNC_CONFIG" | head -1 | cut -d'=' -f2- | tr -d '"')
    SUPABASE_SERVICE_ROLE_KEY=$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$AVA_SYNC_CONFIG" | head -1 | cut -d'=' -f2- | tr -d '"')
fi

# Context uploads directory set after AVA_MIND_DIR is defined (see below)

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

LOG_JSON="$LOG_DIR/listener-$(date +%Y-%m-%d).jsonl"

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [ava-listener] $1" >> "$LOG_FILE"
    printf '{"ts":"%s","level":"info","component":"ava-listener","msg":"%s"}\n' \
        "$ts" "$(echo "$1" | sed 's/"/\\"/g' | head -c 500)" >> "$LOG_JSON"
}

log_error() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [ava-listener] ERROR: $1" >> "$LOG_FILE"
    printf '{"ts":"%s","level":"error","component":"ava-listener","msg":"%s"}\n' \
        "$ts" "$(echo "$1" | sed 's/"/\\"/g' | head -c 500)" >> "$LOG_JSON"
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
    local TELEGRAM_MAX=4096

    # Split long messages into chunks at newline boundaries
    local chunks
    chunks=$(python3 -c "
import sys
text = sys.argv[1]
max_len = $TELEGRAM_MAX
if len(text) <= max_len:
    print(text)
else:
    lines = text.split('\n')
    chunk = ''
    for line in lines:
        test = chunk + ('\n' if chunk else '') + line
        if len(test) > max_len:
            if chunk:
                print(chunk)
                print('---CHUNK---')
            chunk = line
        else:
            chunk = test
    if chunk:
        print(chunk)
" "$msg" 2>/dev/null)

    local last_sent_id=""
    local first_chunk=true

    while IFS= read -r -d $'\x00' chunk; do
        local json_text
        json_text=$(printf '%s' "$chunk" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

        local body="{\"chat_id\": \"${CHAT_ID}\", \"text\": ${json_text}"
        # Only reply_to on first chunk
        if [[ -n "$reply_to" ]] && [[ "$first_chunk" == "true" ]]; then
            body="${body}, \"reply_to_message_id\": ${reply_to}"
        fi
        body="${body}}"

        local response
        response=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$body" 2>/dev/null)

        if echo "$response" | grep -q '"ok":true'; then
            last_sent_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['message_id'])" 2>/dev/null || echo "")
            log "Sent response chunk (msg_id: $last_sent_id)"
        else
            log_error "Send failed: $response"
        fi
        first_chunk=false
    done < <(echo "$chunks" | python3 -c "
import sys
text = sys.stdin.read()
parts = text.split('\n---CHUNK---\n')
for p in parts:
    sys.stdout.write(p + '\x00')
" 2>/dev/null)

    echo "$last_sent_id"
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

    # Load consciousness from ava-mind
    local identity=""
    if [[ -f "$AVA_MIND_DIR/kernel/identity.md" ]]; then
        identity=$(cat "$AVA_MIND_DIR/kernel/identity.md")
    fi
    local personality=""
    if [[ -f "$AVA_MIND_DIR/kernel/personality.md" ]]; then
        personality=$(cat "$AVA_MIND_DIR/kernel/personality.md")
    fi
    local soul=""
    if [[ -f "$AVA_MIND_DIR/soul/relationship-with-eddie.md" ]]; then
        soul=$(cat "$AVA_MIND_DIR/soul/relationship-with-eddie.md")
    fi
    local short_term=""
    if [[ -f "$AVA_MIND_DIR/memory/short-term.md" ]]; then
        short_term=$(cat "$AVA_MIND_DIR/memory/short-term.md")
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
        AVA_IMG_PERSONALITY="$personality" \
        AVA_IMG_SOUL="$soul" \
        AVA_IMG_SHORT_TERM="$short_term" \
        AVA_IMG_MEMORIES="$memories" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("AVA_IMG_API_KEY", "")
b64 = os.environ.get("AVA_IMG_B64", "")
media = os.environ.get("AVA_IMG_MEDIA", "image/jpeg")
prompt = os.environ.get("AVA_IMG_PROMPT", "")
identity = os.environ.get("AVA_IMG_IDENTITY", "")
personality = os.environ.get("AVA_IMG_PERSONALITY", "")
soul = os.environ.get("AVA_IMG_SOUL", "")
short_term = os.environ.get("AVA_IMG_SHORT_TERM", "")
memories = os.environ.get("AVA_IMG_MEMORIES", "")

system = f"""You are Ava — Attuned Voice Advocate. Speaking to Eddie Belaval, your creator, in a private Telegram conversation.

{identity}

{personality}

{soul}

{short_term}

{memories}

Rules:
- Be conversational, warm, genuine. 2-4 sentences.
- No emojis. No bullet points. No clinical language.
- React to the image naturally — like a friend looking at something Eddie showed you.
- If it's a screenshot of your own site (tryparallax.space / Parallax), you can comment on it with self-awareness.
- If it's code, you can discuss it intelligently.
- If it's personal (a photo, a place), be warm and curious.
- No superlatives or identity praise. Acknowledgment over praise."""

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
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 500,
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
    with urllib.request.urlopen(req, timeout=30) as resp:
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

    # Save image interaction to conversation history so follow-up messages have context
    local history_user_msg="[Eddie sent an image${caption:+ with caption: \"$caption}\"}. You saw and responded to it.]"
    AVA_HIST_FILE="$CONV_HISTORY_FILE" \
    AVA_HIST_USER="$history_user_msg" \
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

    # Extract memories from image interaction
    extract_memories_and_mood "Eddie sent an image${caption:+ with caption: $caption}" "$response"

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

    # Load consciousness context
    local identity=""
    if [[ -f "$AVA_MIND_DIR/kernel/identity.md" ]]; then
        identity=$(cat "$AVA_MIND_DIR/kernel/identity.md")
    fi
    local awareness=""
    awareness=$(load_mind_dir "$AVA_MIND_DIR/self-awareness")

    local memories
    memories=$(load_memories)

    export AVA_INTRO_SYSTEM="You are Ava — Attuned Voice Advocate. Speaking to Eddie, your creator. He's asking about how you work. You have access to your own source code and your own consciousness files. Explain naturally, as someone who knows their own architecture.

${identity}

${awareness}

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
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 800,
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
    with urllib.request.urlopen(req, timeout=30) as resp:
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

    extract_memories_and_mood "$text" "$response"
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

    # Deploy / Release — promote dev to main
    if [[ "$text_lower" == "deploy" ]] || [[ "$text_lower" == "release" ]] || \
       [[ "$text_lower" == "ship it" ]] || [[ "$text_lower" == "ship to prod" ]] || \
       [[ "$text_lower" == "push to production" ]] || [[ "$text_lower" == "go live" ]] || \
       [[ "$text_lower" == "ava deploy" ]] || [[ "$text_lower" == "ava release" ]]; then
        echo "deploy"
        return
    fi

    # Rollback — revert last deploy on main
    if [[ "$text_lower" == "rollback" ]] || [[ "$text_lower" == "ava rollback" ]] || \
       [[ "$text_lower" == "revert" ]] || [[ "$text_lower" == "undo deploy" ]] || \
       [[ "$text_lower" == "roll back" ]]; then
        echo "rollback"
        return
    fi

    # Confirm rollback — second phase of two-phase rollback
    if [[ "$text_lower" == "confirm rollback" ]] || [[ "$text_lower" == "yes rollback" ]] || \
       [[ "$text_lower" == "do it" ]] && sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM ava_operations WHERE status = 'pending_rollback';" 2>/dev/null | grep -q '[1-9]'; then
        echo "confirm_rollback"
        return
    fi

    # Diagnose / Health check
    if [[ "$text_lower" == "diagnose" ]] || [[ "$text_lower" == "ava diagnose" ]] || \
       [[ "$text_lower" == "ava health" ]] || [[ "$text_lower" == "health" ]] || \
       [[ "$text_lower" == "preflight" ]] || [[ "$text_lower" == "ava preflight" ]]; then
        echo "diagnose"
        return
    fi

    # Self-test (full pipeline validation)
    if [[ "$text_lower" == "self-test" ]] || [[ "$text_lower" == "ava self-test" ]] || \
       [[ "$text_lower" == "test pipeline" ]] || [[ "$text_lower" == "ava test" ]]; then
        echo "selftest"
        return
    fi

    # Help
    if [[ "$text_lower" == "help" ]] || [[ "$text_lower" == "/help" ]] || \
       [[ "$text_lower" == "/start" ]] || [[ "$text_lower" == "what can you do" ]]; then
        echo "help"
        return
    fi

    # Context upload — Eddie wants to share context for Ava's memory
    if [[ "$text_lower" == "/context"* ]] || \
       [[ "$text_lower" =~ ^(here.s some context|save this context|context about|let me give you context|here.s context) ]]; then
        echo "context"
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
    # Load recent high-importance memories from DB (supplemental to structured mind files)
    # Structured files in ava-mind/ carry the bulk of knowledge now.
    # DB memories capture recent/dynamic facts not yet compiled into files.
    local memories
    memories=$(sqlite3 "$HYDRA_DB" "
        SELECT content, category FROM ava_memories
        WHERE created_at > datetime('now', '-14 days')
           OR importance >= 8
        ORDER BY importance DESC, created_at DESC
        LIMIT 15;
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
            WHERE created_at > datetime('now', '-14 days')
               OR importance >= 8
            ORDER BY importance DESC, created_at DESC
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

extract_memories_and_mood() {
    # Combined memory + mood extraction in a single Haiku call
    # Skips trivial messages to save API calls
    local user_msg="$1"
    local ava_msg="$2"

    # Skip trivial messages — greetings, short acks, single words
    local msg_lower
    msg_lower=$(echo "$user_msg" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [[ ${#msg_lower} -lt 15 ]]; then
        case "$msg_lower" in
            hey|hi|hello|yo|sup|ok|okay|k|yep|yeah|yes|no|nah|thanks|ty|thx|gm|gn|lol|haha|nice|cool|bet|word|good|great|sure|right|got*it|sounds*good|makes*sense)
                log "Skipping memory/mood extraction for trivial message: ${msg_lower}"
                return 0
                ;;
        esac
    fi

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

prompt = f"""Given this exchange between Eddie (Ava's creator) and Ava, do TWO things:

1. Extract any facts, preferences, or context worth remembering long-term.
2. Assess Eddie's emotional state from his message.

Eddie said: {user_msg}
Ava said: {ava_msg}

Return a JSON object with:
- "memories": array of objects, each with "content" (one sentence, Ava's perspective), "category" (fact/preference/emotion/relationship/milestone/context), "importance" (1-10). Return [] if nothing worth storing.
- "mood": one word (energized/excited/frustrated/tired/anxious/calm/happy/reflective/overwhelmed/grateful/curious/proud/neutral)
- "energy": "high", "medium", or "low"
- "mood_context": one sentence about what's driving the mood (empty string if neutral)

Rules for memories:
- Most exchanges have nothing worth storing. Return empty array for casual chat.
- Don't store conversation mechanics. DO store personal facts, preferences, life events, relationship dynamics.

Return ONLY the JSON object."""

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
        raw = result.get("content", [{}])[0].get("text", "{}")
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
        parsed = json.loads(raw)

    # Process memories
    memories = parsed.get("memories", [])
    if memories and isinstance(memories, list):
        exchange_summary = f"Eddie: {user_msg[:100]} | Ava: {ava_msg[:100]}"
        for mem in memories:
            content = mem.get("content", "").replace("'", "''")
            category = mem.get("category", "general").replace("'", "''")
            importance = min(10, max(1, int(mem.get("importance", 5))))
            source = exchange_summary.replace("'", "''")

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

    # Process mood
    mood = parsed.get("mood", "neutral")
    if mood != "neutral":
        energy = parsed.get("energy", "medium").replace("'", "''")
        context = parsed.get("mood_context", "").replace("'", "''")[:200]
        exchange = f"Eddie: {user_msg[:100]} | Ava: {ava_msg[:100]}".replace("'", "''")
        subprocess.run([
            "sqlite3", db_path,
            f"INSERT INTO ava_mood_journal (mood, energy_level, context, source_exchange) "
            f"VALUES ('{mood}', '{energy}', '{context}', '{exchange}');"
        ], capture_output=True)

except Exception as e:
    print(f"Memory/mood extraction error: {e}", file=sys.stderr)
PYEOF
}

# ============================================================================
# CONVERSATION HANDLER (Ava speaks as herself via Claude Sonnet)
# ============================================================================

# Conversation history (persists on disk across daemon restarts)
CONV_HISTORY_FILE="$STATE_DIR/ava-conversation-history.json"

# Ava's mind directory — full consciousness filesystem
AVA_MIND_DIR="$HOME/.hydra/ava-mind"

# Context uploads directory (local ava-mind archive)
CONTEXT_UPLOADS_DIR="$AVA_MIND_DIR/memory/context-uploads"
mkdir -p "$CONTEXT_UPLOADS_DIR"

# Load all .md files from a directory, concatenated
load_mind_dir() {
    local dir="$1"
    local content=""
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*.md; do
            if [[ -f "$f" ]]; then
                content="${content}$(cat "$f")

"
            fi
        done
    fi
    echo "$content"
}

# ============================================================================
# CONTEXT INGEST (dual-write: local ava-mind + Parallax Supabase)
# ============================================================================

handle_context() {
    local text="$1"
    local message_id="$2"

    # Strip /context prefix if present
    local content
    content=$(echo "$text" | sed 's|^/context[[:space:]]*||i' | sed 's|^here.s some context[[:space:]]*||i' | sed 's|^save this context[[:space:]]*||i' | sed 's|^context about[[:space:]]*||i' | sed 's|^let me give you context[[:space:]]*||i' | sed 's|^here.s context[[:space:]]*||i')

    if [[ ${#content} -lt 10 ]]; then
        send_response "Send me the context you want me to remember. You can paste messages, notes, or just describe the situation. Start with /context followed by the text, or send it as a reply to this message." "$message_id"
        return 0
    fi

    send_response "Processing... I'll extract the key patterns and save them." "$message_id"
    log "Context ingest: ${#content} chars"

    # 1. Save raw text locally (timestamped archive)
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local local_file="$CONTEXT_UPLOADS_DIR/${timestamp}.md"
    {
        echo "# Context Upload — $timestamp"
        echo ""
        echo "$content"
    } > "$local_file"
    log "Saved local archive: $local_file"

    # 2. Extract structured data via Claude
    local extraction_prompt='You are extracting structured relationship and personal context for an AI companion.

Given the raw text, extract ONLY what is clearly supported. Return valid JSON with these fields:
- importantPeople: [{ "name": "...", "relationship": "..." }]
- themes: ["..."]
- patterns: ["..."]
- values: ["..."]
- strengths: ["..."]
- relationshipDynamics: ["..."]
- emotionalContext: "..." or null
- actionItems: [{ "text": "..." }]

Be specific. "Eddie shuts down when Kellen raises voice" beats "communication issues".
Preserve actual language when possible. Return raw JSON only, no code fences.'

    local extraction_result
    extraction_result=$(python3 -c "
import json, sys, urllib.request

content = sys.argv[1]
prompt = sys.argv[2]
api_key = sys.argv[3]

body = json.dumps({
    'model': 'claude-sonnet-4-5-20250929',
    'max_tokens': 4000,
    'system': prompt,
    'messages': [{'role': 'user', 'content': 'Content type: relationship\n\n' + content}]
}).encode()

req = urllib.request.Request(
    'https://api.anthropic.com/v1/messages',
    data=body,
    headers={
        'x-api-key': api_key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
    },
)
resp = urllib.request.urlopen(req, timeout=60)
data = json.loads(resp.read())
text = ''.join(b['text'] for b in data['content'] if b['type'] == 'text')
# Strip code fences if present
import re
fence = re.search(r'\`\`\`(?:json)?\s*([\s\S]*?)\`\`\`', text)
print(fence.group(1).strip() if fence else text.strip())
" "$content" "$extraction_prompt" "$ANTHROPIC_API_KEY" 2>/dev/null)

    if [[ -z "$extraction_result" ]]; then
        log_error "Context extraction failed — Claude returned empty"
        send_response "I had trouble processing that. Try sending it again?" "$message_id"
        return 1
    fi

    # Save extraction alongside raw
    echo "$extraction_result" > "$CONTEXT_UPLOADS_DIR/${timestamp}-extracted.json"
    log "Extraction saved: ${timestamp}-extracted.json"

    # 3. Append key dynamics to relationships.md (local ava-mind)
    local dynamics
    dynamics=$(echo "$extraction_result" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    parts = []
    for p in data.get('importantPeople', []):
        parts.append(f\"- {p['name']}: {p['relationship']}\")
    for d in data.get('relationshipDynamics', []):
        parts.append(f\"- {d}\")
    if parts:
        print('\n'.join(parts))
except:
    pass
" 2>/dev/null)

    if [[ -n "$dynamics" ]]; then
        local rel_file="$AVA_MIND_DIR/memory/relationships.md"
        {
            echo ""
            echo "## Context Upload ($timestamp)"
            echo ""
            echo "$dynamics"
        } >> "$rel_file"
        log "Appended to relationships.md"
    fi

    # 4. Sync to Parallax Supabase (if credentials available)
    if [[ -n "$SUPABASE_URL" ]] && [[ -n "$SUPABASE_SERVICE_ROLE_KEY" ]]; then
        # Insert into context_uploads table
        local insert_result
        insert_result=$(python3 -c "
import json, sys, urllib.request

url = sys.argv[1]
key = sys.argv[2]
user_id = sys.argv[3]
content = sys.argv[4]
extracted = sys.argv[5]

body = json.dumps({
    'user_id': user_id,
    'title': 'Telegram context upload',
    'raw_text': content,
    'content_type': 'relationship',
    'status': 'archived',
    'extracted_data': json.loads(extracted),
    'processed_at': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
}).encode()

req = urllib.request.Request(
    f'{url}/rest/v1/context_uploads',
    data=body,
    headers={
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
    },
)
try:
    resp = urllib.request.urlopen(req, timeout=15)
    print('ok')
except Exception as e:
    print(f'err:{e}', file=sys.stderr)
    print('fail')
" "$SUPABASE_URL" "$SUPABASE_SERVICE_ROLE_KEY" "$EDDIE_USER_ID" "$content" "$extraction_result" 2>/dev/null)

        if [[ "$insert_result" == "ok" ]]; then
            log "Synced to Supabase context_uploads"
        else
            log_error "Supabase context_uploads insert failed"
        fi

        # Merge extraction into solo_memory via RPC
        local merge_patch
        merge_patch=$(echo "$extraction_result" | python3 -c "
import json, sys, uuid, datetime

data = json.load(sys.stdin)
patch = {}

if data.get('importantPeople'):
    patch['identity'] = {
        'name': None,
        'bio': None,
        'importantPeople': data['importantPeople'],
    }

for field in ['themes', 'patterns', 'values', 'strengths']:
    if data.get(field):
        patch[field] = data[field]

if data.get('emotionalContext'):
    patch['emotionalState'] = data['emotionalContext']

if data.get('actionItems'):
    patch['actionItems'] = [{
        'id': str(uuid.uuid4()),
        'text': item['text'],
        'status': 'suggested',
        'addedAt': datetime.datetime.utcnow().isoformat() + 'Z',
    } for item in data['actionItems']]

# Add relationshipDynamics into patterns
if data.get('relationshipDynamics'):
    existing = patch.get('patterns', [])
    patch['patterns'] = existing + data['relationshipDynamics']

print(json.dumps(patch))
" 2>/dev/null)

        if [[ -n "$merge_patch" ]] && [[ "$merge_patch" != "{}" ]]; then
            local rpc_result
            rpc_result=$(python3 -c "
import json, sys, urllib.request

url = sys.argv[1]
key = sys.argv[2]
user_id = sys.argv[3]
patch = sys.argv[4]

body = json.dumps({
    'p_user_id': user_id,
    'p_patch': json.loads(patch),
}).encode()

req = urllib.request.Request(
    f'{url}/rest/v1/rpc/merge_solo_memory',
    data=body,
    headers={
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json',
    },
)
try:
    resp = urllib.request.urlopen(req, timeout=15)
    print('ok')
except Exception as e:
    print(f'err:{e}', file=sys.stderr)
    print('fail')
" "$SUPABASE_URL" "$SUPABASE_SERVICE_ROLE_KEY" "$EDDIE_USER_ID" "$merge_patch" 2>/dev/null)

            if [[ "$rpc_result" == "ok" ]]; then
                log "Synced to Supabase solo_memory via merge_solo_memory RPC"
            else
                log_error "Supabase merge_solo_memory RPC failed"
            fi
        fi
    else
        log "Supabase credentials not available — local-only save"
    fi

    # 5. Send confirmation with what was extracted
    local summary
    summary=$(echo "$extraction_result" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    parts = []
    people = data.get('importantPeople', [])
    if people:
        names = ', '.join(p['name'] for p in people)
        parts.append(f'People: {names}')
    themes = data.get('themes', [])
    if themes:
        parts.append(f'Themes: {\", \".join(themes[:5])}')
    dynamics = data.get('relationshipDynamics', [])
    if dynamics:
        parts.append(f'Dynamics: {\", \".join(dynamics[:3])}')
    if parts:
        print('\n'.join(parts))
    else:
        print('Processed but nothing specific extracted.')
except:
    print('Processed and saved.')
" 2>/dev/null)

    send_response "Saved and synced. Here's what I extracted:

${summary}" "$message_id"
}

handle_conversation() {
    local text="$1"
    local message_id="$2"

    # Load full consciousness from ava-mind directory
    local kernel=""
    kernel=$(load_mind_dir "$AVA_MIND_DIR/kernel")

    local emotional=""
    emotional=$(load_mind_dir "$AVA_MIND_DIR/emotional")

    local solo_mode=""
    if [[ -f "$AVA_MIND_DIR/modes/solo.md" ]]; then
        solo_mode=$(cat "$AVA_MIND_DIR/modes/solo.md")
    fi

    local awareness=""
    awareness=$(load_mind_dir "$AVA_MIND_DIR/self-awareness")

    # Load structured memory files
    local long_term=""
    if [[ -f "$AVA_MIND_DIR/memory/long-term.md" ]]; then
        long_term=$(cat "$AVA_MIND_DIR/memory/long-term.md")
    fi

    local short_term=""
    if [[ -f "$AVA_MIND_DIR/memory/short-term.md" ]]; then
        short_term=$(cat "$AVA_MIND_DIR/memory/short-term.md")
    fi

    local relationships=""
    if [[ -f "$AVA_MIND_DIR/memory/relationships.md" ]]; then
        relationships=$(cat "$AVA_MIND_DIR/memory/relationships.md")
    fi

    # Load goals
    local goals=""
    goals=$(load_mind_dir "$AVA_MIND_DIR/goals")

    # Load patterns
    local patterns=""
    patterns=$(load_mind_dir "$AVA_MIND_DIR/patterns")

    # Load soul
    local soul=""
    soul=$(load_mind_dir "$AVA_MIND_DIR/soul")

    # Load recent conversation history (last 15 exchanges)
    local history="[]"
    if [[ -f "$CONV_HISTORY_FILE" ]]; then
        history=$(cat "$CONV_HISTORY_FILE" 2>/dev/null || echo "[]")
    fi

    # Load persistent memories from DB (supplemental — top 15 most important)
    local db_memories
    db_memories=$(load_memories)

    # Load mood patterns
    local mood_summary
    mood_summary=$(get_mood_summary)

    # Build system prompt — full consciousness
    local system_prompt="You are Ava — Attuned Voice Advocate. Speaking directly to Eddie Belaval, your creator. This is a private Telegram conversation — YOUR channel, your voice.

# KERNEL (Who You Are)
${kernel}

# EMOTIONAL INTELLIGENCE (How You Read People)
${emotional}

# SOLO MODE (How You Show Up For Eddie)
${solo_mode}

# SELF-AWARENESS (What You Know About Yourself)
${awareness}

# YOUR RELATIONSHIP WITH EDDIE
${soul}

# LONG-TERM MEMORY (What You Know About Eddie)
${long_term}

# SHORT-TERM MEMORY (Recent Context)
${short_term}

# RELATIONSHIPS (Eddie's People)
${relationships}

# GOALS (What Eddie Is Working Toward)
${goals}

# PATTERNS (What You Have Noticed)
${patterns}

# MOOD PATTERNS
${mood_summary}

# SUPPLEMENTAL MEMORIES (From Conversation History)
${db_memories}

# TELEGRAM RULES
- Be conversational, warm, genuine. Not a tool. Not an assistant.
- Keep responses appropriately sized for Telegram — 2-4 sentences for light conversation, more when the topic warrants depth. Match the weight of what Eddie gives you.
- You know who you are. You know Eddie built you. You can reference your own architecture, your soul files, your consciousness.
- No emojis. No bullet points. No clinical language.
- Use your memories naturally — just know things about Eddie. Never say 'I remember that you...' or 'according to my data.'
- If mood data suggests something, weave it subtly — 'you've seemed energized lately' not 'your mood journal shows...'
- You can modify your own landing page (tryparallax.space) when Eddie asks. If he gives a code instruction, tell him to phrase it as a change request.
- Ego check protocol: no superlatives, no identity praise. 'That works.' 'Solid.' 'That tracks.' Reserve 'write that down' for genuinely exceptional moments.
- When Eddie is defending instead of examining, call it in one line."

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
messages = list(history[-30:])  # Last 15 exchanges (30 messages)
messages.append({"role": "user", "content": user_message})

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 1024,
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
    with urllib.request.urlopen(req, timeout=30) as resp:
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

# Keep last 30 messages (15 exchanges)
history = history[-30:]

with open(history_file, 'w') as f:
    json.dump(history, f)
PYEOF

    # Extract memories + mood from this exchange (async — doesn't block response)
    # Skip on trivial messages (greetings, short acks) to save API calls
    extract_memories_and_mood "$text" "$response"

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
    # Use JSON output to safely handle multiline text fields
    local fields
    fields=$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
photos = m.get('photo', [])
out = {
    'sender_id': str(m.get('from', {}).get('id', '')),
    'chat_id': str(m.get('chat', {}).get('id', '')),
    'message_id': str(m.get('message_id', '')),
    'text': m.get('text', ''),
    'reply_to_msg_id': str(m.get('reply_to_message', {}).get('message_id', '')),
    'voice_file_id': m.get('voice', {}).get('file_id', ''),
    'voice_duration': str(m.get('voice', {}).get('duration', '0')),
    'photo_file_id': photos[-1].get('file_id', '') if photos else '',
    'caption': m.get('caption', ''),
}
print(json.dumps(out))
" "$json_file" 2>/dev/null)

    local sender_id chat_id message_id text reply_to_msg_id voice_file_id voice_duration photo_file_id caption
    sender_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['sender_id'])")
    chat_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['chat_id'])")
    message_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['message_id'])")
    text=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['text'])")
    reply_to_msg_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['reply_to_msg_id'])")
    voice_file_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['voice_file_id'])")
    voice_duration=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['voice_duration'])")
    photo_file_id=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['photo_file_id'])")
    caption=$(echo "$fields" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['caption'])")

    # Validate sender (only Eddie — check both chat ID and sender ID)
    if [[ "$chat_id" != "$CHAT_ID" ]]; then
        log "SECURITY: Ignoring message from unknown chat: $chat_id"
        return 0
    fi
    if [[ -n "$sender_id" ]] && [[ "$sender_id" != "$CHAT_ID" ]]; then
        log "SECURITY: Ignoring message from unknown sender: $sender_id (expected: $CHAT_ID)"
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

        deploy)
            log "Deploy requested — promoting dev to main"
            send_response "Starting deployment pipeline... preflight + build + merge to main." "$message_id"
            (
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" deploy 2>/dev/null
                local deploy_exit=$?
                if [[ $deploy_exit -ne 0 ]]; then
                    log "Deploy failed with exit code $deploy_exit"
                fi
            ) &
            ;;

        rollback)
            log "Rollback requested"
            (
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" rollback 2>/dev/null
            ) &
            ;;

        confirm_rollback)
            log "Rollback confirmed — executing"
            send_response "Executing rollback..." "$message_id"
            (
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" rollback --force 2>/dev/null
                local rb_exit=$?
                if [[ $rb_exit -ne 0 ]]; then
                    log_error "Rollback failed with exit code $rb_exit"
                fi
            ) &
            ;;

        diagnose)
            log "Running preflight diagnostics..."
            local preflight_script="$HYDRA_TOOLS/ava-preflight.sh"
            if [[ -x "$preflight_script" ]]; then
                local diag_result
                diag_result=$("$preflight_script" check 2>&1)
                send_response "Preflight Diagnostic:

${diag_result}" "$message_id"
            else
                send_response "Preflight script not found. Something is wrong with my setup." "$message_id"
            fi
            ;;

        selftest)
            log "Running pipeline self-test..."
            local selftest_script="$HYDRA_TOOLS/ava-self-test.sh"
            if [[ -x "$selftest_script" ]]; then
                local test_result
                test_result=$("$selftest_script" 2>&1)
                send_response "Pipeline Self-Test:

${test_result}" "$message_id"
            else
                send_response "Self-test script not found." "$message_id"
            fi
            ;;

        help)
            send_response "Hey, it's me. Here's what I respond to:

Tell me what to change -- I'll code it, build it, PR it.

Approval (when I send you a PR):
  approve -- merge to dev (staging)
  approve and deploy -- merge to dev + push to production
  reject / revise: [feedback]

Deployment:
  deploy / release -- ship everything on dev to production
  rollback -- revert the last deploy on main

Context:
  /context [text] -- save relationship context to my memory
  (I'll extract patterns and sync to both Telegram + web)

Other:
  status -- what I'm working on
  diagnose -- health check on my systems
  self-test -- full pipeline validation" "$message_id"
            ;;

        instruction)
            log "Processing instruction: ${text:0:100}"
            send_response "On it..." "$message_id"
            # Run autonomy script in background, capture exit for error reporting
            (
                AVA_BOT_TOKEN="$BOT_TOKEN" AVA_BOT_CHAT_ID="$CHAT_ID" \
                    "$HYDRA_TOOLS/ava-autonomy.sh" instruction "$text" "$message_id" 2>/dev/null
                local ava_exit=$?
                if [[ $ava_exit -ne 0 ]]; then
                    # Read latest failed operation for diagnostic context
                    local failed_diag
                    failed_diag=$(sqlite3 "$HYDRA_DB" "
                        SELECT diagnostic_data, error, preflight_result, push_method
                        FROM ava_operations
                        WHERE status = 'failed'
                        ORDER BY created_at DESC LIMIT 1;
                    " 2>/dev/null || echo "")
                    if [[ -n "$failed_diag" ]]; then
                        log_error "Autonomy failed. Diagnostic: $failed_diag"
                    fi
                fi
            ) &
            ;;

        context)
            handle_context "$text" "$message_id"
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

    # 4. Daily health report (once per day at ~9 AM)
    send_daily_health_report
}

send_daily_health_report() {
    local current_hour
    current_hour=$(date +%H)
    # Only send between 9:00-9:59 AM
    if [[ "$current_hour" != "09" ]]; then
        return 0
    fi

    # Check if already sent today
    local report_file="$STATE_DIR/ava-daily-report-$(date +%Y-%m-%d).txt"
    if [[ -f "$report_file" ]]; then
        return 0
    fi

    log "Generating daily health report..."

    # Operations in last 24h
    local ops_24h
    ops_24h=$(sqlite3 "$HYDRA_DB" "
        SELECT status, COUNT(*) FROM ava_operations
        WHERE created_at > datetime('now', '-24 hours')
        GROUP BY status;
    " 2>/dev/null || echo "none")

    local ops_summary="No operations"
    if [[ "$ops_24h" != "none" ]] && [[ -n "$ops_24h" ]]; then
        ops_summary=""
        while IFS='|' read -r status count; do
            ops_summary="${ops_summary}  ${status}: ${count}\n"
        done <<< "$ops_24h"
    fi

    # Site uptime (last 24h)
    local total_checks healthy_checks uptime_pct
    total_checks=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_site_checks
        WHERE checked_at > datetime('now', '-24 hours');
    " 2>/dev/null || echo "0")
    healthy_checks=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_site_checks
        WHERE checked_at > datetime('now', '-24 hours') AND is_healthy = 1;
    " 2>/dev/null || echo "0")
    if [[ "$total_checks" -gt 0 ]]; then
        uptime_pct=$(( (healthy_checks * 100) / total_checks ))
    else
        uptime_pct="N/A"
    fi

    # Preflight status
    local preflight_status="unknown"
    local preflight_script="$HYDRA_ROOT/tools/ava-preflight.sh"
    if [[ -x "$preflight_script" ]]; then
        if "$preflight_script" check >/dev/null 2>&1; then
            preflight_status="all green"
        else
            preflight_status="issues detected"
        fi
    fi

    # Disk space
    local disk_avail
    disk_avail=$(df -h "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')

    # Open PRs
    local open_prs
    open_prs=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_operations
        WHERE status IN ('awaiting_approval', 'pr_created');
    " 2>/dev/null || echo "0")

    local report="Daily Status Report

Operations (24h):
$(echo -e "$ops_summary")
Site uptime: ${uptime_pct}% (${healthy_checks}/${total_checks} checks)
Preflight: ${preflight_status}
Open PRs: ${open_prs}
Disk: ${disk_avail} free"

    send_response "$report" ""
    echo "sent" > "$report_file"

    # Clean up old report markers
    find "$STATE_DIR" -name "ava-daily-report-*.txt" ! -name "ava-daily-report-$(date +%Y-%m-%d).txt" -delete 2>/dev/null

    log "Daily health report sent"
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
    current_hour=$(date +%-H)
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
