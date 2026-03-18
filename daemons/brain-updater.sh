#!/bin/bash
# brain-updater.sh - HYDRA Brain Auto-Updater
#
# Runs daily at 6:00 AM via launchd (before morning briefing).
# Scans git repos for recent activity, summarizes via Claude Haiku,
# and updates the bounded section in TECHNICAL_BRAIN.md.
#
# Only modifies content between <!-- BRAIN-UPDATER:START --> and
# <!-- BRAIN-UPDATER:END --> markers. Never touches manual content.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

BRAIN_FILE="$HOME/.hydra/TECHNICAL_BRAIN.md"
STATE_FILE="$HOME/.hydra/state/brain-updater-state.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-brain-updater"
LOG_FILE="$LOG_DIR/brain-updater.log"
HYDRA_ENV="$HOME/.hydra/config/telegram.env"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Shared repo config (single source of truth)
source "$HOME/.hydra/config/repos.sh"
REPO_LIST=("${HYDRA_REPOS[@]}")

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== Brain updater started ==="

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
    log "Created new state file"
fi

get_last_sha() {
    local repo_name="$1"
    python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    state = json.load(f)
print(state.get('$repo_name', {}).get('last_sha', ''))
" 2>/dev/null || echo ""
}

save_sha() {
    local repo_name="$1"
    local sha="$2"
    python3 -c "
import json
state_path = '$STATE_FILE'
with open(state_path) as f:
    state = json.load(f)
if '$repo_name' not in state:
    state['$repo_name'] = {}
state['$repo_name']['last_sha'] = '$sha'
state['$repo_name']['updated'] = '$TIMESTAMP'
with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
}

# ============================================================================
# SCAN REPOS FOR NEW COMMITS
# ============================================================================

CHANGES_FOUND=false
ALL_SUMMARIES=""

# Cache dir for commit data (reused by MC signal push, avoids double scan)
COMMIT_CACHE=$(mktemp -d)
trap 'rm -rf "$COMMIT_CACHE"' EXIT

for repo_entry in "${REPO_LIST[@]}"; do
    parse_repo "$repo_entry"

    # Skip repos that don't exist
    if [[ ! -d "$REPO_PATH/.git" ]]; then
        log "Skipping $REPO_NAME: not a git repo at $REPO_PATH"
        continue
    fi

    # Get current HEAD SHA
    current_sha=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -z "$current_sha" ]]; then
        log "Skipping $REPO_NAME: could not get HEAD SHA"
        continue
    fi

    # Compare with last-seen SHA
    last_sha=$(get_last_sha "$REPO_NAME")
    if [[ "$current_sha" == "$last_sha" ]]; then
        log "Skipping $REPO_NAME: no new commits (HEAD=$current_sha)"
        continue
    fi

    # Get recent commits (last 7 days)
    commits=$(git -C "$REPO_PATH" log --oneline --since="7 days ago" --max-count=20 2>/dev/null || echo "")
    if [[ -z "$commits" ]]; then
        log "Skipping $REPO_NAME: no commits in last 7 days"
        save_sha "$REPO_NAME" "$current_sha"
        continue
    fi

    commit_count=$(echo "$commits" | wc -l | tr -d ' ')
    log "Found $commit_count new commits in $REPO_NAME"
    CHANGES_FOUND=true

    # Cache commit data for MC signal push (avoids re-scanning)
    echo "$commit_count" > "$COMMIT_CACHE/$REPO_NAME.count"
    echo "$commits" | head -1 | cut -c9- > "$COMMIT_CACHE/$REPO_NAME.latest"

    # Collect raw commits for summarization
    ALL_SUMMARIES+="### $REPO_NAME ($commit_count commits)
$commits

"

    # Save new SHA
    save_sha "$REPO_NAME" "$current_sha"
done

# ============================================================================
# EXIT EARLY IF NO CHANGES
# ============================================================================

if [[ "$CHANGES_FOUND" == "false" ]]; then
    log "No new commits across any repos. Brain unchanged."
    echo "No new commits found. Brain not updated."
    exit 0
fi

log "Changes found, generating summary..."

# ============================================================================
# SUMMARIZE WITH HAIKU
# ============================================================================

summarize_with_haiku() {
    local raw_commits="$1"

    # Load API key
    local api_key=""
    if [[ -f "$HYDRA_ENV" ]]; then
        api_key=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" | head -1 | cut -d'"' -f2)
    fi

    if [[ -z "$api_key" ]]; then
        log "No API key, using raw commits as summary"
        echo "$raw_commits"
        return
    fi

    export HAIKU_COMMITS="$raw_commits"
    export ANTHROPIC_API_KEY="$api_key"

    local summary=$(python3 << 'PYEOF'
import json, urllib.request, sys, os

commits = os.environ.get("HAIKU_COMMITS", "")
api_key = os.environ.get("ANTHROPIC_API_KEY", "")

system_prompt = """You summarize git commit activity for a developer's knowledge base.

Given git log output grouped by repository, produce a concise summary:
- 3-5 bullet points per active repo
- Focus on features shipped, bugs fixed, and architectural changes
- Use present tense ("Added", "Fixed", "Refactored")
- Skip merge commits and trivial changes
- Use **bold** for key terms
- Keep total output under 1500 characters

Format:
**RepoName**
- Bullet point 1
- Bullet point 2

Return ONLY the formatted summary, no explanation."""

data = json.dumps({
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 500,
    "system": system_prompt,
    "messages": [{"role": "user", "content": commits}]
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
        text = result.get("content", [{}])[0].get("text", "").strip()
        if text:
            print(text)
        else:
            print(commits)
except Exception as e:
    print(commits, file=sys.stdout)
    print(f"Haiku error: {e}", file=sys.stderr)
PYEOF
)

    if [[ -n "$summary" ]]; then
        echo "$summary"
    else
        log "Haiku returned empty, using raw commits"
        echo "$raw_commits"
    fi
}

SUMMARY=$(summarize_with_haiku "$ALL_SUMMARIES")
log "Summary generated (${#SUMMARY} chars)"

# ============================================================================
# UPDATE BOUNDED SECTION IN TECHNICAL_BRAIN.MD
# ============================================================================

export BRAIN_FILE
export SUMMARY
export DATE

python3 << 'PYEOF'
import os, sys, hashlib

brain_path = os.environ["BRAIN_FILE"]
summary = os.environ["SUMMARY"]
date = os.environ["DATE"]

with open(brain_path, "r") as f:
    content = f.read()

start_marker = "<!-- BRAIN-UPDATER:START -->"
end_marker = "<!-- BRAIN-UPDATER:END -->"

if start_marker not in content or end_marker not in content:
    print("ERROR: Brain updater markers not found in TECHNICAL_BRAIN.md", file=sys.stderr)
    sys.exit(1)

start_idx = content.index(start_marker)
end_idx = content.index(end_marker) + len(end_marker)

# Checksum content after end marker (safety check)
after_content = content[end_idx:]
checksum_before = hashlib.md5(after_content.encode()).hexdigest()

# Build new bounded section
new_section = f"""{start_marker}
## Recent Git Activity
*Auto-updated: {date}*

{summary}
{end_marker}"""

# Replace bounded section
updated = content[:start_idx] + new_section + content[end_idx:]

# Verify content after markers is unchanged
after_updated = updated[updated.index(end_marker) + len(end_marker):]
checksum_after = hashlib.md5(after_updated.encode()).hexdigest()

if checksum_before != checksum_after:
    print("ERROR: Content after end marker changed! Aborting.", file=sys.stderr)
    sys.exit(1)

with open(brain_path, "w") as f:
    f.write(updated)

print(f"Brain updated: {len(summary)} chars between markers")
PYEOF

log "TECHNICAL_BRAIN.md updated successfully"

# ============================================================================
# PUSH SIGNALS TO MISSION CONTROL (uses cached commit data from scan above)
# ============================================================================

log "Pushing activity signals to Mission Control..."
push_mc_signals heartbeat 24 "" "24 hours ago" "$COMMIT_CACHE"
log "Mission Control signals complete"

# Purge expired signals (daily housekeeping)
if [[ -x "$MC_CLI" ]]; then
    "$MC_CLI" purge 2>/dev/null || true
fi

echo "Brain updated with recent git activity for $DATE"
