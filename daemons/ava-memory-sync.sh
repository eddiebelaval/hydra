#!/bin/zsh
# ava-memory-sync.sh — Cross-platform memory sync between Telegram and Parallax
#
# Syncs Ava's memories bidirectionally:
#   T->W: Telegram (hydra.db ava_memories) -> Parallax (Supabase solo_memory)
#   W->T: Parallax (Supabase solo_memory) -> Telegram (hydra.db ava_memories)
#
# Runs every 30 minutes via launchd. Coordinates with (but does not overlap)
# the ava-memory-compiler daemon that runs at 3 AM.
#
# Loop prevention: Web-originated memories get source_exchange='parallax-web-sync'
# and are excluded from T->W queries.
#
# Usage:
#   ava-memory-sync.sh             # Full sync (both directions)
#   ava-memory-sync.sh --dry-run   # Show what would sync without writing
#   ava-memory-sync.sh --tw-only   # Telegram -> Web only
#   ava-memory-sync.sh --wt-only   # Web -> Telegram only
#   ava-memory-sync.sh --backfill  # Backfill all 725 existing memories T->W

set -uo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
STATE_DIR="$HYDRA_ROOT/state"
CONFIG_FILE="$HYDRA_ROOT/config/ava-sync.env"
SNAPSHOT_FILE="$STATE_DIR/solo-memory-snapshot.json"
HAIKU_MODEL="claude-haiku-4-5-20251001"
API_URL="https://api.anthropic.com/v1/messages"
API_VERSION="2023-06-01"
API_TIMEOUT=30
TMPDIR="${TMPDIR:-/tmp}"

LOG_DIR="$HOME/Library/Logs/claude-automation/ava-memory-sync"
LOG_FILE="$LOG_DIR/sync-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR" "$STATE_DIR"

MODE="${1:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [memory-sync] $1" | tee -a "$LOG_FILE"
}

# Dependency checks
for cmd in sqlite3 python3; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR: $cmd not found. Exiting."
        exit 1
    fi
done

# Load sync config
if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: Config not found at $CONFIG_FILE. Exiting."
    exit 1
fi

SUPABASE_URL=""
SUPABASE_SERVICE_ROLE_KEY=""
EDDIE_USER_ID=""
SYNC_BATCH_SIZE=20

while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
        SUPABASE_URL) SUPABASE_URL="$value" ;;
        SUPABASE_SERVICE_ROLE_KEY) SUPABASE_SERVICE_ROLE_KEY="$value" ;;
        EDDIE_USER_ID) EDDIE_USER_ID="$value" ;;
        SYNC_BATCH_SIZE) SYNC_BATCH_SIZE="$value" ;;
        SYNC_LOG_RETENTION_DAYS) SYNC_LOG_RETENTION_DAYS="$value" ;;
    esac
done < "$CONFIG_FILE"

if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_SERVICE_ROLE_KEY" || -z "$EDDIE_USER_ID" ]]; then
    log "ERROR: Missing required config values (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EDDIE_USER_ID). Exiting."
    exit 1
fi

# Load Anthropic API key (same source as compiler)
ANTHROPIC_API_KEY=""
if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ROOT/config/telegram.env" | head -1 | cut -d'"' -f2)
fi

if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "ERROR: No Anthropic API key found. Exiting."
    exit 1
fi

export ANTHROPIC_API_KEY HAIKU_MODEL API_URL API_VERSION API_TIMEOUT

# Atomic write helper
atomic_write() {
    local target="$1"
    local content="$2"
    local tmpfile="$TMPDIR/ava-sync-$$.tmp"
    echo "$content" > "$tmpfile" && mv "$tmpfile" "$target"
}

# Clean up old logs
find "$LOG_DIR" -name "*.log" -mtime +${SYNC_LOG_RETENTION_DAYS:-30} -delete 2>/dev/null

# Log sync to SQLite (all params escaped to prevent injection)
log_sync() {
    local direction="${1//\'/\'\'}"
    local items="$2"
    local sync_status="${3//\'/\'\'}"
    local details="${4//\'/\'\'}"
    sqlite3 "$HYDRA_DB" "INSERT INTO ava_sync_log (direction, items_synced, status, details) VALUES ('$direction', $items, '$sync_status', '$details');" 2>/dev/null
}

# Clean old sync logs (keep last 30 days)
sqlite3 "$HYDRA_DB" "DELETE FROM ava_sync_log WHERE created_at < datetime('now', '-${SYNC_LOG_RETENTION_DAYS:-30} days');" 2>/dev/null

log "=== Ava Memory Sync starting (mode: ${MODE:-full}) ==="

# ============================================================================
# TELEGRAM -> WEB (T->W)
# ============================================================================

sync_telegram_to_web() {
    log "--- T->W: Telegram -> Parallax Web ---"

    # 1. Get last synced ID
    local last_id
    last_id=$(sqlite3 "$HYDRA_DB" "SELECT value FROM ava_sync_state WHERE key = 'last_tw_sync_id';" 2>/dev/null || echo "0")
    log "  Last synced ID: $last_id"

    # 2. Get unsynced memories (excluding web-originated ones to prevent loops)
    local batch
    batch=$(sqlite3 -separator '|||' "$HYDRA_DB" "
        SELECT id, content, category, importance, created_at
        FROM ava_memories
        WHERE id > $last_id
        AND (source_exchange IS NULL OR source_exchange != 'parallax-web-sync')
        ORDER BY id ASC
        LIMIT $SYNC_BATCH_SIZE;
    " 2>/dev/null || echo "")

    if [[ -z "$batch" ]]; then
        log "  No new memories to sync T->W"
        log_sync "telegram_to_web" 0 "skipped" "No new memories since ID $last_id"
        return 0
    fi

    # Count rows
    local row_count
    row_count=$(echo "$batch" | wc -l | tr -d ' ')
    log "  Found $row_count new memories to translate"

    # Get max ID in this batch
    local max_id
    max_id=$(echo "$batch" | tail -1 | cut -d'|' -f1)

    # 3. Fetch existing solo_memory to merge arrays properly
    local existing_memory
    existing_memory=$(SYNC_SB_URL="$SUPABASE_URL" \
        SYNC_SB_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
        SYNC_USER_ID="$EDDIE_USER_ID" \
        python3 << 'PYEOF'
import urllib.request, json, os, sys

url = os.environ["SYNC_SB_URL"]
key = os.environ["SYNC_SB_KEY"]
uid = os.environ["SYNC_USER_ID"]

endpoint = f"{url}/rest/v1/user_profiles?select=solo_memory&user_id=eq.{uid}"
req = urllib.request.Request(endpoint, headers={
    "apikey": key,
    "Authorization": f"Bearer {key}",
    "Content-Type": "application/json"
})

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
        if data and data[0].get("solo_memory"):
            print(json.dumps(data[0]["solo_memory"]))
        else:
            print("{}")
except Exception as e:
    print("{}", file=sys.stdout)
    print(f"Warning: Could not fetch existing solo_memory: {e}", file=sys.stderr)
PYEOF
) || existing_memory="{}"

    # 4. Feed batch + existing memory to Haiku for translation
    local patch
    patch=$(SYNC_BATCH="$batch" \
        SYNC_EXISTING="$existing_memory" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
batch_raw = os.environ.get("SYNC_BATCH", "")
existing_raw = os.environ.get("SYNC_EXISTING", "{}")

# Parse batch into structured data
memories = []
for line in batch_raw.strip().split("\n"):
    if not line:
        continue
    parts = line.split("|||")
    if len(parts) >= 5:
        memories.append({
            "id": parts[0],
            "content": parts[1],
            "category": parts[2],
            "importance": parts[3],
            "created_at": parts[4]
        })

if not memories:
    print("{}")
    sys.exit(0)

# Parse existing memory
try:
    existing = json.loads(existing_raw)
except (json.JSONDecodeError, ValueError, TypeError):
    existing = {}

# Build the memory list for the prompt
memory_text = "\n".join([
    f"- [{m['category']}] (importance: {m['importance']}) {m['content']}"
    for m in memories
])

# Show existing arrays so Haiku can merge (cap lengths to control prompt size)
existing_themes = existing.get("themes", [])[:8]
existing_patterns = existing.get("patterns", [])[:6]
existing_values = existing.get("values", [])[:10]
existing_people = existing.get("identity", {}).get("importantPeople", [])[:15]

prompt = f"""You are translating Ava's Telegram memories into the Parallax web memory format.
The output will be merged into an existing memory store using a JSONB merge function.

IMPORTANT: For array fields (themes, patterns, values, importantPeople), you must include
ALL existing values plus any new ones from the memories. The merge function REPLACES arrays,
so omitting existing values would delete them.

Existing data to preserve:
- themes: {json.dumps(existing_themes)}
- patterns: {json.dumps(existing_patterns)}
- values: {json.dumps(existing_values)}
- importantPeople: {json.dumps(existing_people)}

New Telegram memories to integrate:
{memory_text}

Output a JSON object matching this schema (include only fields with actual data):
{{
  "identity": {{ "name": "string or null", "bio": "string or null", "importantPeople": [{{"name": "str", "relationship": "str"}}] }},
  "themes": ["string array — recurring life themes, max 8"],
  "patterns": ["string array — behavioral patterns, max 6"],
  "values": ["string array — core values"],
  "currentSituation": "string or null — what's happening right now",
  "emotionalState": "string or null — current emotional state",
  "lifeSections": {{
    "work": {{ "role": "str or null", "projects": ["str"], "challenges": ["str"] }},
    "life": {{ "livingContext": "str or null", "relationships": ["str"], "interests": ["str"] }}
  }}
}}

Category mapping:
- "relationship" -> identity.importantPeople (extract name + relationship type)
- "preference" -> values array
- "emotion" -> emotionalState (use most recent) and themes
- "context" -> currentSituation and/or lifeSections
- "fact" -> lifeSections (work or life depending on content)
- "milestone" -> themes
- "insight" -> patterns
- "general" -> distribute to best-fit field

Rules:
- INCLUDE all existing array values plus new ones (deduplicated)
- Cap themes at 8, patterns at 6, values at 10, importantPeople at 15
- Keep importantPeople relationship strings SHORT (under 30 chars, e.g. "loved one", "AI companion")
- Return ONLY valid JSON, no markdown fences, no explanation
- If a memory doesn't clearly map to any field, skip it
- Prefer specificity over vagueness
- Keep the total response compact — summarize, don't accumulate verbatim"""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 4000,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

max_retries = 2
for attempt in range(max_retries + 1):
    try:
        req = urllib.request.Request(
            os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
            data=data,
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
            }
        )
        timeout = int(os.environ.get("API_TIMEOUT", "45"))
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            result = json.loads(resp.read().decode())
            if "error" in result:
                print(f"API error: {result['error']}", file=sys.stderr)
                sys.exit(1)
            text = result.get("content", [{}])[0].get("text", "")
            text = text.strip()
            if text.startswith("```"):
                text = "\n".join(text.split("\n")[1:])
            if text.endswith("```"):
                text = "\n".join(text.split("\n")[:-1])
            parsed = json.loads(text.strip())
            print(json.dumps(parsed))
            sys.exit(0)
    except json.JSONDecodeError as e:
        if attempt < max_retries:
            import time
            print(f"JSON parse error (attempt {attempt+1}), retrying...", file=sys.stderr)
            time.sleep(2)
            continue
        print(f"JSON parse error after {max_retries+1} attempts: {e}", file=sys.stderr)
        print(f"Raw text: {text[:500]}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
PYEOF
) || { log "  ERROR: T->W translation failed"; log_sync "telegram_to_web" 0 "error" "Haiku translation failed"; return 1; }

    if [[ -z "$patch" || "$patch" == "{}" ]]; then
        log "  T->W: Empty patch from translation, skipping"
        log_sync "telegram_to_web" 0 "skipped" "Empty translation result"
        return 0
    fi

    if [[ "$MODE" == "--dry-run" ]]; then
        log "  [DRY RUN] Would push patch to Supabase (${#patch} chars):"
        echo "$patch" | python3 -m json.tool 2>/dev/null || echo "$patch"
        log "  [DRY RUN] Would update last_tw_sync_id to $max_id"
        return 0
    fi

    # 5. Push patch to Supabase via merge_solo_memory RPC
    local rpc_result
    rpc_result=$(SYNC_SB_URL="$SUPABASE_URL" \
        SYNC_SB_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
        SYNC_USER_ID="$EDDIE_USER_ID" \
        SYNC_PATCH="$patch" \
        python3 << 'PYEOF'
import urllib.request, json, os, sys

url = os.environ["SYNC_SB_URL"]
key = os.environ["SYNC_SB_KEY"]
uid = os.environ["SYNC_USER_ID"]
patch = os.environ["SYNC_PATCH"]

endpoint = f"{url}/rest/v1/rpc/merge_solo_memory"
body = json.dumps({
    "p_user_id": uid,
    "p_patch": json.loads(patch)
}).encode()

req = urllib.request.Request(endpoint, data=body, headers={
    "apikey": key,
    "Authorization": f"Bearer {key}",
    "Content-Type": "application/json",
    "Prefer": "return=representation"
})

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = resp.read().decode()
        print("ok")
except urllib.error.HTTPError as e:
    err_body = e.read().decode() if e.fp else "no body"
    print(f"RPC error {e.code}: {err_body}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || { log "  ERROR: T->W RPC call failed"; log_sync "telegram_to_web" 0 "error" "merge_solo_memory RPC failed"; return 1; }

    # 6. Update sync state
    sqlite3 "$HYDRA_DB" "
        UPDATE ava_sync_state SET value = '$max_id', updated_at = datetime('now') WHERE key = 'last_tw_sync_id';
        UPDATE ava_sync_state SET value = datetime('now'), updated_at = datetime('now') WHERE key = 'last_sync_at';
    " 2>/dev/null

    log "  T->W: Synced $row_count memories (IDs $((last_id + 1))-$max_id)"
    log_sync "telegram_to_web" "$row_count" "success" "Synced IDs $((last_id + 1))-$max_id"
}

# ============================================================================
# WEB -> TELEGRAM (W->T)
# ============================================================================

sync_web_to_telegram() {
    log "--- W->T: Parallax Web -> Telegram ---"

    # 1. Fetch current solo_memory from Supabase
    local current_memory
    current_memory=$(SYNC_SB_URL="$SUPABASE_URL" \
        SYNC_SB_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
        SYNC_USER_ID="$EDDIE_USER_ID" \
        python3 << 'PYEOF'
import urllib.request, json, os, sys

url = os.environ["SYNC_SB_URL"]
key = os.environ["SYNC_SB_KEY"]
uid = os.environ["SYNC_USER_ID"]

endpoint = f"{url}/rest/v1/user_profiles?select=solo_memory&user_id=eq.{uid}"
req = urllib.request.Request(endpoint, headers={
    "apikey": key,
    "Authorization": f"Bearer {key}",
    "Content-Type": "application/json"
})

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
        if data and data[0].get("solo_memory"):
            print(json.dumps(data[0]["solo_memory"]))
        else:
            print("{}")
except Exception as e:
    print("{}", file=sys.stdout)
    print(f"Error fetching solo_memory: {e}", file=sys.stderr)
PYEOF
) || current_memory="{}"

    if [[ "$current_memory" == "{}" || -z "$current_memory" ]]; then
        log "  W->T: No solo_memory data on web, skipping"
        log_sync "web_to_telegram" 0 "skipped" "No solo_memory on web"
        return 0
    fi

    # 2. Compute hash and compare to last known
    local current_hash
    current_hash=$(echo -n "$current_memory" | md5 -q 2>/dev/null || echo -n "$current_memory" | md5sum 2>/dev/null | cut -d' ' -f1)

    local last_hash
    last_hash=$(sqlite3 "$HYDRA_DB" "SELECT value FROM ava_sync_state WHERE key = 'last_wt_hash';" 2>/dev/null || echo "")

    if [[ "$current_hash" == "$last_hash" && -n "$last_hash" ]]; then
        log "  W->T: solo_memory unchanged (hash: ${current_hash:0:8}...)"
        log_sync "web_to_telegram" 0 "skipped" "Hash unchanged: ${current_hash:0:8}"
        return 0
    fi

    log "  W->T: solo_memory changed (old: ${last_hash:0:8}..., new: ${current_hash:0:8}...)"

    # 3. Load cached snapshot for diff
    local snapshot="{}"
    if [[ -f "$SNAPSHOT_FILE" ]]; then
        snapshot=$(cat "$SNAPSHOT_FILE" 2>/dev/null || echo "{}")
    fi

    # 4. Feed diff to Haiku to generate new ava_memories rows
    local new_rows
    new_rows=$(SYNC_CURRENT="$current_memory" \
        SYNC_SNAPSHOT="$snapshot" \
        python3 << 'PYEOF'
import json, urllib.request, os, sys

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
current_raw = os.environ.get("SYNC_CURRENT", "{}")
snapshot_raw = os.environ.get("SYNC_SNAPSHOT", "{}")

try:
    current = json.loads(current_raw)
    snapshot = json.loads(snapshot_raw)
except (json.JSONDecodeError, ValueError, TypeError):
    current = {}
    snapshot = {}

# If snapshot is empty, this is the first W->T sync — generate from full memory
if not snapshot:
    diff_desc = f"Full solo_memory (first sync):\n{json.dumps(current, indent=2)[:3000]}"
else:
    # Compute meaningful diff
    changes = []
    for key in set(list(current.keys()) + list(snapshot.keys())):
        cv = current.get(key)
        sv = snapshot.get(key)
        if cv != sv:
            changes.append(f"  {key}: {json.dumps(sv)[:200]} -> {json.dumps(cv)[:200]}")

    if not changes:
        print("[]")
        sys.exit(0)

    diff_desc = "Changed fields:\n" + "\n".join(changes)

prompt = f"""You are translating changes in Ava's Parallax web memory into flat memory rows for Telegram.

The web memory changed. Generate new memory rows that Ava on Telegram should know about.

{diff_desc}

Output a JSON array of objects, each with:
- "content": string (the memory text, written naturally as something Ava observed)
- "category": one of "relationship", "preference", "emotion", "context", "fact", "milestone", "insight", "general"
- "importance": integer 1-10

Rules:
- Only generate rows for genuinely NEW information (not things Telegram already knows)
- Write content as Ava would note it: "Eddie mentioned..." or "Eddie values..."
- Keep each content under 200 characters
- Generate 0-10 rows (empty array [] if nothing new)
- Return ONLY valid JSON array, no markdown fences"""

data = json.dumps({
    "model": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5-20251001"),
    "max_tokens": 1500,
    "messages": [{"role": "user", "content": prompt}]
}).encode()

try:
    req = urllib.request.Request(
        os.environ.get("API_URL", "https://api.anthropic.com/v1/messages"),
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": os.environ.get("API_VERSION", "2023-06-01")
        }
    )
    timeout = int(os.environ.get("API_TIMEOUT", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read().decode())
        if "error" in result:
            print(f"API error: {result['error']}", file=sys.stderr)
            sys.exit(1)
        text = result.get("content", [{}])[0].get("text", "")
        text = text.strip()
        if text.startswith("```"):
            text = "\n".join(text.split("\n")[1:])
        if text.endswith("```"):
            text = "\n".join(text.split("\n")[:-1])
        parsed = json.loads(text.strip())
        if not isinstance(parsed, list):
            parsed = []
        print(json.dumps(parsed))
except json.JSONDecodeError as e:
    print(f"JSON parse error: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || { log "  ERROR: W->T translation failed"; log_sync "web_to_telegram" 0 "error" "Haiku translation failed"; return 1; }

    if [[ "$new_rows" == "[]" || -z "$new_rows" ]]; then
        log "  W->T: No new memories to create"
        # Still update hash and snapshot since we detected the change
        atomic_write "$SNAPSHOT_FILE" "$current_memory"
        sqlite3 "$HYDRA_DB" "UPDATE ava_sync_state SET value = '$current_hash', updated_at = datetime('now') WHERE key = 'last_wt_hash';" 2>/dev/null
        log_sync "web_to_telegram" 0 "skipped" "Hash changed but no actionable diff"
        return 0
    fi

    # Count new rows
    local insert_count
    insert_count=$(echo "$new_rows" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$MODE" == "--dry-run" ]]; then
        log "  [DRY RUN] Would insert $insert_count memories into ava_memories:"
        echo "$new_rows" | python3 -m json.tool 2>/dev/null || echo "$new_rows"
        return 0
    fi

    # 5. Insert new rows into ava_memories with loop-prevention marker
    local actual_inserted
    actual_inserted=$(SYNC_ROWS="$new_rows" SYNC_DB="$HYDRA_DB" python3 << 'PYEOF'
import json, sqlite3, os, sys

rows = json.loads(os.environ.get("SYNC_ROWS", "[]"))
db_path = os.environ.get("SYNC_DB", "")

if not rows or not db_path:
    sys.exit(1)

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    inserted = 0
    for row in rows:
        content = row.get("content", "")
        category = row.get("category", "general")
        importance = row.get("importance", 5)

        if not content:
            continue

        cursor.execute("""
            INSERT INTO ava_memories (content, category, importance, source_exchange)
            VALUES (?, ?, ?, 'parallax-web-sync')
        """, (content, category, importance))
        inserted += 1

    conn.commit()
    conn.close()
    print(f"{inserted}")
except Exception as e:
    print(f"Insert error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
) || { log "  ERROR: W->T insert into ava_memories failed"; log_sync "web_to_telegram" 0 "error" "Insert failed"; return 1; }

    # 6. Update snapshot and hash (only reached if insert succeeded)
    atomic_write "$SNAPSHOT_FILE" "$current_memory"
    local safe_hash="${current_hash//\'/\'\'}"
    sqlite3 "$HYDRA_DB" "
        UPDATE ava_sync_state SET value = '$safe_hash', updated_at = datetime('now') WHERE key = 'last_wt_hash';
        UPDATE ava_sync_state SET value = datetime('now'), updated_at = datetime('now') WHERE key = 'last_sync_at';
    " 2>/dev/null

    log "  W->T: Inserted $actual_inserted memories from web changes"
    log_sync "web_to_telegram" "$actual_inserted" "success" "Inserted $actual_inserted rows from web diff"
}

# ============================================================================
# BACKFILL MODE — Process all existing memories in batches
# ============================================================================

run_backfill() {
    log "=== BACKFILL MODE: Syncing all existing memories T->W ==="

    # Reset sync pointer to 0
    sqlite3 "$HYDRA_DB" "UPDATE ava_sync_state SET value = '0', updated_at = datetime('now') WHERE key = 'last_tw_sync_id';" 2>/dev/null

    local total_count
    total_count=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM ava_memories WHERE source_exchange IS NULL OR source_exchange != 'parallax-web-sync';" 2>/dev/null || echo "0")

    log "  Total memories to backfill: $total_count"
    log "  Batch size: $SYNC_BATCH_SIZE"
    log "  Estimated batches: $(( (total_count + SYNC_BATCH_SIZE - 1) / SYNC_BATCH_SIZE ))"

    local batch_num=0
    while true; do
        batch_num=$((batch_num + 1))
        log "  --- Backfill batch $batch_num ---"

        sync_telegram_to_web || {
            log "  Backfill batch $batch_num failed, stopping"
            break
        }

        # Check if there are more
        local last_id
        last_id=$(sqlite3 "$HYDRA_DB" "SELECT value FROM ava_sync_state WHERE key = 'last_tw_sync_id';" 2>/dev/null || echo "0")
        local remaining
        remaining=$(sqlite3 "$HYDRA_DB" "
            SELECT COUNT(*) FROM ava_memories
            WHERE id > $last_id
            AND (source_exchange IS NULL OR source_exchange != 'parallax-web-sync');
        " 2>/dev/null || echo "0")

        if [[ "$remaining" -eq 0 ]]; then
            log "  Backfill complete! All memories synced."
            break
        fi

        log "  $remaining memories remaining, pausing 2s..."
        sleep 2
    done

    log "=== Backfill finished ==="
}

# ============================================================================
# RUN
# ============================================================================

case "$MODE" in
    --dry-run)
        sync_telegram_to_web
        sync_web_to_telegram
        ;;
    --tw-only)
        sync_telegram_to_web
        ;;
    --wt-only)
        sync_web_to_telegram
        ;;
    --backfill)
        run_backfill
        ;;
    *)
        sync_telegram_to_web || log "  WARN: T->W sync failed"
        sync_web_to_telegram || log "  WARN: W->T sync failed"
        ;;
esac

log "=== Memory sync complete ==="
