#!/bin/bash
# telegram-ingest-kb.sh - Knowledge Base Ingest Handler for HYDRA
#
# Receives a URL from Telegram, classifies it (article/repo/other),
# fetches content, contextualizes it for id8Labs, auto-routes to
# the best KB, and saves to raw/.
#
# Usage: telegram-ingest-kb.sh <url> <kb|auto> <reply_message_id>
#
# Runs in background from telegram-listener.sh dispatch.

set -euo pipefail

URL="${1:-}"
KB_OVERRIDE="${2:-auto}"
REPLY_MSG_ID="${3:-}"

# Load config
HYDRA_ROOT="$HOME/.hydra"
HYDRA_CONFIG="$HYDRA_ROOT/config/telegram.env"
source "$HYDRA_CONFIG" 2>/dev/null || true
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
export REPLY_MSG_ID

KB_ROOT="$HOME/Development/id8/knowledge"
MANIFEST="$KB_ROOT/manifest.json"
LOG_FILE="$HOME/Library/Logs/claude-automation/hydra-telegram/ingest-$(date +%Y-%m-%d).log"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Telegram helper (reuse from listener)
send_msg() {
    local text="$1"
    local parse_mode="${2:-}"
    local payload
    if [[ -n "$parse_mode" ]]; then
        payload=$(python3 -c "
import json
print(json.dumps({
    'chat_id': '$TELEGRAM_CHAT_ID',
    'text': '''$text''',
    'reply_to_message_id': $REPLY_MSG_ID,
    'parse_mode': '$parse_mode'
}))
" 2>/dev/null)
    else
        payload=$(python3 -c "
import json
print(json.dumps({
    'chat_id': '$TELEGRAM_CHAT_ID',
    'text': $(python3 -c "import json; print(json.dumps('''$text'''))"),
    'reply_to_message_id': $REPLY_MSG_ID
}))
" 2>/dev/null)
    fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# Better Telegram send that handles special characters
send_telegram() {
    local text="$1"
    # Write to temp file to avoid heredoc escaping issues
    local msg_file=$(mktemp)
    echo "$text" > "$msg_file"
    python3 -c "
import json, urllib.request, sys, os

with open('$msg_file', 'r') as f:
    text = f.read().strip()

data = json.dumps({
    'chat_id': os.environ.get('TELEGRAM_CHAT_ID', ''),
    'text': text,
    'reply_to_message_id': int(os.environ.get('REPLY_MSG_ID', '0') or '0')
}).encode()

req = urllib.request.Request(
    'https://api.telegram.org/bot' + os.environ.get('TELEGRAM_BOT_TOKEN', '') + '/sendMessage',
    data=data,
    headers={'Content-Type': 'application/json'}
)
try:
    urllib.request.urlopen(req, timeout=10)
except:
    pass
" 2>/dev/null
    rm -f "$msg_file"
}

# ============================================================================
# STEP 1: Validate URL
# ============================================================================

if [[ -z "$URL" ]]; then
    send_telegram "No URL provided. Send me a link to ingest."
    exit 1
fi

# Strip surrounding whitespace/quotes
URL=$(echo "$URL" | sed 's/^[[:space:]"'\'']*//;s/[[:space:]"'\'']*$//')

log "Ingest started: $URL (kb=$KB_OVERRIDE)"

# ============================================================================
# STEP 2: Classify source type
# ============================================================================

SOURCE_TYPE="article"
IS_REPO=false

if echo "$URL" | grep -qE 'github\.com/[^/]+/[^/]+'; then
    SOURCE_TYPE="repo"
    IS_REPO=true
elif echo "$URL" | grep -qE 'arxiv\.org'; then
    SOURCE_TYPE="paper"
elif echo "$URL" | grep -qE '\.(pdf)$'; then
    SOURCE_TYPE="paper"
fi

log "Source type: $SOURCE_TYPE"

# ============================================================================
# STEP 3: Fetch content
# ============================================================================

TEMP_DIR=$(mktemp -d)
export TEMP_DIR
CONTENT_FILE="$TEMP_DIR/content.md"
TITLE=""

if [[ "$IS_REPO" == true ]]; then
    # GitHub repo: fetch README via API
    REPO_PATH=$(echo "$URL" | sed -E 's|https?://github\.com/||' | sed 's|/$||' | cut -d'/' -f1-2)
    log "Fetching repo: $REPO_PATH"

    # Get repo info
    REPO_INFO=$(curl -s "https://api.github.com/repos/$REPO_PATH" 2>/dev/null || echo '{}')
    TITLE=$(echo "$REPO_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('full_name','unknown'))" 2>/dev/null || echo "$REPO_PATH")
    DESCRIPTION=$(echo "$REPO_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description','') or '')" 2>/dev/null || echo "")
    STARS=$(echo "$REPO_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stargazers_count',0))" 2>/dev/null || echo "0")
    LANGUAGE=$(echo "$REPO_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('language','') or 'unknown')" 2>/dev/null || echo "unknown")
    TOPICS=$(echo "$REPO_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d.get('topics',[])))" 2>/dev/null || echo "")

    # Get README
    README_CONTENT=$(curl -s "https://raw.githubusercontent.com/$REPO_PATH/main/README.md" 2>/dev/null || \
                     curl -s "https://raw.githubusercontent.com/$REPO_PATH/master/README.md" 2>/dev/null || \
                     echo "No README found.")

    # Truncate README to first 3000 chars for context
    README_TRUNCATED=$(echo "$README_CONTENT" | head -c 3000)

    cat > "$CONTENT_FILE" << REPOEOF
# $TITLE

**URL:** $URL
**Description:** $DESCRIPTION
**Language:** $LANGUAGE | **Stars:** $STARS
**Topics:** $TOPICS

## README (truncated)

$README_TRUNCATED
REPOEOF

else
    # Article/paper: use defuddle via npx or curl fallback
    log "Fetching article: $URL"

    # Try defuddle first (best quality), fall back to curl
    if command -v npx &>/dev/null; then
        FETCHED=$(npx -y @anthropic-ai/defuddle "$URL" 2>/dev/null || echo "")
    fi

    if [[ -z "${FETCHED:-}" ]]; then
        # Fallback: raw curl + basic cleanup
        FETCHED=$(curl -sL -A "Mozilla/5.0" "$URL" 2>/dev/null | \
                  python3 -c "
import sys, re, html
raw = sys.stdin.read()
# Strip HTML tags (rough)
text = re.sub(r'<script[^>]*>.*?</script>', '', raw, flags=re.DOTALL)
text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
text = re.sub(r'<[^>]+>', ' ', text)
text = html.unescape(text)
# Collapse whitespace
text = re.sub(r'\s+', ' ', text).strip()
print(text[:8000])
" 2>/dev/null || echo "Failed to fetch content from $URL")
    fi

    # Extract title from content
    TITLE=$(echo "$FETCHED" | head -5 | grep -oP '(?<=^# ).*' | head -1 || echo "")
    if [[ -z "$TITLE" ]]; then
        TITLE=$(echo "$URL" | sed -E 's|https?://||;s|/+$||;s|[/?#].*||')
    fi

    echo "$FETCHED" > "$CONTENT_FILE"
fi

CONTENT_LENGTH=$(wc -c < "$CONTENT_FILE" | tr -d ' ')
log "Fetched $CONTENT_LENGTH bytes, title: $TITLE"

if [[ "$CONTENT_LENGTH" -lt 100 ]]; then
    send_telegram "Could not fetch meaningful content from $URL. The page might require authentication or be behind a paywall."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# ============================================================================
# STEP 4: Contextualize + Auto-route KB
# ============================================================================

# Read manifest for KB tags
KB_TAGS=$(python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
for kb in m['kbs']:
    if kb.get('type') != 'mirror':
        print(f\"{kb['name']}: {', '.join(kb.get('tags', []))} - {kb.get('description', '')}\")
" 2>/dev/null || echo "research: consciousness, caf, philosophy
design: design, ui, ux, design-systems")

# Use Claude Haiku to contextualize and route
# Write content preview to temp file (avoids shell escaping issues in heredoc)
head -c 2000 "$CONTENT_FILE" > "$TEMP_DIR/preview.txt"

# Write metadata to temp JSON for safe passing
python3 -c "
import json
meta = {
    'source_type': '''$SOURCE_TYPE''',
    'url': '''$URL''',
    'title': '''$TITLE''',
    'kb_tags': '''$KB_TAGS''',
    'kb_override': '''$KB_OVERRIDE'''
}
with open('$TEMP_DIR/meta.json', 'w') as f:
    json.dump(meta, f)
" 2>/dev/null

CONTEXT_RESPONSE=$(python3 << 'CTXEOF'
import json, urllib.request, os, re

temp_dir = os.environ.get("TEMP_DIR", "/tmp")

# Read content from file (safe from shell escaping)
with open(os.path.join(temp_dir, "preview.txt"), "r") as f:
    content = f.read()

with open(os.path.join(temp_dir, "meta.json"), "r") as f:
    meta = json.load(f)

source_type = meta["source_type"]
url = meta["url"]
title = meta["title"]
kb_tags = meta["kb_tags"]
kb_override = meta["kb_override"]

system_prompt = (
    "You are a knowledge base router for id8Labs. Given a source (article, paper, or GitHub repo), you must:\n\n"
    "1. Write a 2-sentence summary of what this source is about\n"
    "2. Explain in 1 sentence why it matters for id8Labs (products: Homer real estate, Parallax AI chat, consciousness research CaF, design systems, trading)\n"
    "3. List 2-3 existing concepts it might relate to\n"
    "4. Route it to the best knowledge base\n\n"
    "Available KBs:\n" + kb_tags + "\n\n"
    "If the user specified a KB override (not 'auto'), use that. Otherwise pick the best match.\n\n"
    "Respond with ONLY valid JSON:\n"
    '{"summary": "...", "relevance": "...", "concepts": ["concept1", "concept2"], "kb": "research|design", "title_slug": "kebab-case-slug-max-40-chars"}'
)

user_msg = f"Source type: {source_type}\nURL: {url}\nTitle: {title}\nKB override: {kb_override}\n\nContent preview:\n{content[:1500]}"

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 300,
    "system": system_prompt,
    "messages": [{"role": "user", "content": user_msg}]
}).encode()

fallback = json.dumps({"summary": "Analysis failed", "relevance": "Unknown", "concepts": [], "kb": "research", "title_slug": "unknown-source"})

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
if not api_key:
    print(fallback)
    exit(0)

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
    resp = urllib.request.urlopen(req, timeout=30)
    result = json.loads(resp.read().decode())
    text = result["content"][0]["text"]
    json_match = re.search(r'\{[^{}]*\}', text, re.DOTALL)
    if json_match:
        print(json_match.group())
    else:
        print(fallback)
except Exception as e:
    print(fallback)
CTXEOF
)

log "Context response: $CONTEXT_RESPONSE"

# Parse the context
TARGET_KB=$(echo "$CONTEXT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kb','research'))" 2>/dev/null || echo "research")
SUMMARY=$(echo "$CONTEXT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('summary','No summary'))" 2>/dev/null || echo "No summary")
RELEVANCE=$(echo "$CONTEXT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('relevance','Unknown'))" 2>/dev/null || echo "Unknown")
CONCEPTS=$(echo "$CONTEXT_RESPONSE" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('concepts',[])))" 2>/dev/null || echo "")
SLUG=$(echo "$CONTEXT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title_slug','unknown'))" 2>/dev/null || echo "unknown")

# Override KB if user specified
if [[ "$KB_OVERRIDE" != "auto" ]]; then
    TARGET_KB="$KB_OVERRIDE"
fi

log "Routed to KB: $TARGET_KB, slug: $SLUG"

# ============================================================================
# STEP 5: Save to raw/
# ============================================================================

RAW_DIR="$KB_ROOT/$TARGET_KB/raw"
mkdir -p "$RAW_DIR"

OUTPUT_FILE="$RAW_DIR/$SLUG.md"

# Don't overwrite existing files
if [[ -f "$OUTPUT_FILE" ]]; then
    SLUG="${SLUG}-$(date +%s)"
    OUTPUT_FILE="$RAW_DIR/$SLUG.md"
fi

# Write with frontmatter
cat > "$OUTPUT_FILE" << RAWEOF
---
source_url: "$URL"
source_type: $SOURCE_TYPE
ingested: $(date +%Y-%m-%d)
processed: false
summary: "$SUMMARY"
relevance: "$RELEVANCE"
concepts: [$CONCEPTS]
kb_routed: $TARGET_KB
---

$(cat "$CONTENT_FILE")
RAWEOF

log "Saved to $OUTPUT_FILE"

# ============================================================================
# STEP 6: Log to HYDRA database
# ============================================================================

sqlite3 "$HYDRA_ROOT/hydra.db" "
INSERT OR IGNORE INTO observations (id, entity_type, entity_id, observation, source, created_at)
VALUES (
    'obs-kb-$(date +%s)',
    'kb_ingest',
    '$SLUG',
    'Ingested $SOURCE_TYPE from $URL into $TARGET_KB KB. $SUMMARY',
    'telegram',
    datetime('now')
);
" 2>/dev/null || true

# ============================================================================
# STEP 7: Send response
# ============================================================================

RESPONSE="Ingested into $TARGET_KB KB

$TITLE
$SUMMARY

Why it matters: $RELEVANCE

Relates to: $CONCEPTS

Run /kb-compile $TARGET_KB to process into wiki articles."

send_telegram "$RESPONSE"

# Log to event buffer
EVENT_BUFFER="$HYDRA_ROOT/state/event-buffer.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] KB_INGEST: $URL -> $TARGET_KB/$SLUG ($SOURCE_TYPE)" >> "$EVENT_BUFFER" 2>/dev/null || true

# Cleanup
rm -rf "$TEMP_DIR"

log "Ingest complete: $URL -> $TARGET_KB/$SLUG"
