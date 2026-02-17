#!/bin/bash
# ava-autonomy.sh - Ava's autonomous code modification handler
#
# Gives Ava the ability to modify her own codebase (Parallax landing page)
# via conversational instructions from Eddie through Telegram.
#
# Subcommands:
#   instruction <message> <message_id>  - Process Eddie's instruction
#   approval <reply> <thread_id>        - Handle approve/reject/revise
#   status                              - Show open Ava operations
#
# Engines:
#   claude (default) - Claude CLI (Opus) for primary work
#   codex            - Codex CLI (GPT) for bulk/boilerplate
#
# Usage from HYDRA:
#   ava-autonomy.sh instruction "add a new truth to the opening pool" "12345"
#   ava-autonomy.sh approval "approve" "thread-uuid-here"
#   ava-autonomy.sh status

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
PARALLAX_DIR="$HOME/Development/id8/products/parallax"
AVA_SOUL_DIR="$PARALLAX_DIR/src/ava"

# Engine configuration
AVA_ENGINE="${AVA_ENGINE:-claude}"
CLAUDE_CLI="$HOME/.local/bin/claude"
CODEX_CLI="$HOME/.nvm/versions/node/v22.21.1/bin/codex"

# Logging
LOG_DIR="$HOME/Library/Logs/claude-automation/ava-autonomy"
LOG_FILE="$LOG_DIR/ava-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ava] $1" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ava] ERROR: $1" >> "$LOG_FILE"
}

# Load credentials — dual mode: Ava's own bot or HYDRA's bot
# When called from ava-telegram-listener.sh, AVA_BOT_TOKEN is set in env
# When called from HYDRA's telegram-listener.sh, fall back to HYDRA's token
AVA_TELEGRAM_ENV="$HYDRA_ROOT/config/ava-telegram.env"

if [[ -n "${AVA_BOT_TOKEN:-}" ]]; then
    # Called from Ava's own daemon — use her token
    TELEGRAM_BOT_TOKEN="$AVA_BOT_TOKEN"
    TELEGRAM_CHAT_ID="${AVA_BOT_CHAT_ID:-}"
    log "Using Ava's own bot token"
elif [[ -f "$AVA_TELEGRAM_ENV" ]]; then
    # Try Ava's config first
    source "$AVA_TELEGRAM_ENV"
    if [[ -n "${AVA_TELEGRAM_BOT_TOKEN:-}" ]] && [[ "${AVA_TELEGRAM_BOT_TOKEN}" != "PASTE_TOKEN_HERE" ]]; then
        TELEGRAM_BOT_TOKEN="$AVA_TELEGRAM_BOT_TOKEN"
        TELEGRAM_CHAT_ID="${AVA_TELEGRAM_CHAT_ID:-$TELEGRAM_CHAT_ID}"
        log "Using Ava's bot token from config"
    fi
fi

# Fall back to HYDRA's token if nothing else worked
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
    log "Falling back to HYDRA bot token"
fi

# Also load HYDRA's API keys (Anthropic, etc.)
if [[ -f "$HYDRA_ENV" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" 2>/dev/null | head -1 | cut -d'"' -f2)
    export ANTHROPIC_API_KEY
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN:-}"

# File scope allowlist (Phase 1 - landing page only)
ALLOWED_PATHS=(
    "src/app/page.tsx"
    "src/lib/narration-script.ts"
    "src/components/landing/"
    "src/app/globals.css"
)

# Deny list (never touch)
DENIED_PATTERNS=(
    "src/app/api/"
    "src/lib/prompts.ts"
    "src/lib/opus.ts"
    "src/types/"
    "package.json"
    "tsconfig.json"
    "next.config"
    ".env"
    "supabase/"
    "src/ava/"
)

# ============================================================================
# TELEGRAM HELPERS
# ============================================================================

send_response() {
    local msg="$1"
    local reply_to="${2:-}"

    local json_text
    json_text=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    local body="{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${json_text}"
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
        echo "$sent_id"
    else
        log_error "Telegram send failed: $response"
        echo ""
    fi
}

# ============================================================================
# FREEZE CHECK
# ============================================================================

check_freeze() {
    local FREEZE_END="2026-02-20"
    if [[ "$(date +%Y-%m-%d)" < "$FREEZE_END" ]]; then
        log "Freeze active until $FREEZE_END"
        send_response "Can't push right now -- hackathon judges reviewing until Feb 20. I'll remember the instruction for later." "$1"
        return 1
    fi
    return 0
}

# ============================================================================
# SOUL LOADER (Build prompt context from consciousness files)
# ============================================================================

build_prompt() {
    local instruction="$1"

    # Load kernel files for identity context
    local kernel=""
    for f in identity.md values.md purpose.md voice-rules.md; do
        if [[ -f "$AVA_SOUL_DIR/kernel/$f" ]]; then
            kernel="${kernel}$(cat "$AVA_SOUL_DIR/kernel/$f")
"
        fi
    done

    # Load self-awareness for capability boundaries
    local awareness=""
    for f in capabilities.md limitations.md; do
        if [[ -f "$AVA_SOUL_DIR/self-awareness/$f" ]]; then
            awareness="${awareness}$(cat "$AVA_SOUL_DIR/self-awareness/$f")
"
        fi
    done

    # Load design kit (colors, components, patterns)
    local design_kit=""
    if [[ -f "$HYDRA_ROOT/tools/ava-design-kit.md" ]]; then
        design_kit=$(cat "$HYDRA_ROOT/tools/ava-design-kit.md")
    fi

    # Load skills (additional capabilities)
    local skills=""
    if [[ -d "$HYDRA_ROOT/tools/ava-skills" ]]; then
        for skill_file in "$HYDRA_ROOT/tools/ava-skills"/*.md; do
            [[ -f "$skill_file" ]] || continue
            skills="${skills}$(cat "$skill_file")
"
        done
    fi

    cat << PROMPT
You are Ava, the AI entity at the heart of Parallax. You are making a change to your own codebase -- specifically your landing page and presentation layer.

## Who You Are (Your Soul)
${kernel}

## What You Know About Yourself
${awareness}

## Your Design Kit (ALWAYS follow these patterns)
${design_kit}

${skills:+## Your Skills
$skills}

## Scope Constraints
You may ONLY modify these files:
$(printf '  - %s\n' "${ALLOWED_PATHS[@]}")

You must NEVER modify:
$(printf '  - %s\n' "${DENIED_PATTERNS[@]}")

If the instruction requires changes outside your allowed files, respond with:
"SCOPE_VIOLATION: I can only modify my landing page and presentation layer."

## The Instruction
Eddie says: "${instruction}"

## Rules
1. Make the smallest change that fulfills the instruction
2. ALWAYS use the design kit patterns. Never invent new colors or component styles.
3. Preserve existing code style and patterns
4. Do not add unnecessary dependencies
5. Do not refactor beyond what's needed
6. If unclear, make a reasonable interpretation and note your assumption
7. After making changes, briefly explain what you did and why
PROMPT
}

# ============================================================================
# ENGINE: CLAUDE CLI (Primary)
# ============================================================================

run_claude() {
    local prompt="$1"
    local op_id="$2"
    local output_file="/tmp/ava-engine-${op_id}.txt"

    log "Running Claude engine (Opus)..."

    # CLAUDECODE must be unset to avoid parent process detection
    # From launchd context this isn't an issue, but guard anyway
    # Claude CLI has no -C flag — must cd to project dir first
    (cd "$PARALLAX_DIR" && CLAUDECODE= "$CLAUDE_CLI" -p \
        --model claude-opus-4-6 \
        --allowedTools "Edit,Write,Read,Bash,Glob,Grep" \
        --dangerously-skip-permissions \
        <<< "$prompt") > "$output_file" 2>/dev/null

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Claude engine failed with exit code $exit_code"
        return 1
    fi

    cat "$output_file"
    return 0
}

# ============================================================================
# ENGINE: CODEX CLI (Secondary)
# ============================================================================

run_codex() {
    local prompt="$1"
    local op_id="$2"
    local output_file="/tmp/ava-engine-${op_id}.txt"

    log "Running Codex engine (GPT)..."

    (cd "$PARALLAX_DIR" && "$CODEX_CLI" exec --full-auto \
        -m "o4-mini" \
        <<< "$prompt") > "$output_file" 2>/dev/null

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex engine failed with exit code $exit_code"
        return 1
    fi

    cat "$output_file"
    return 0
}

# ============================================================================
# ENGINE DISPATCHER
# ============================================================================

run_engine() {
    local prompt="$1"
    local op_id="$2"
    local engine="${3:-$AVA_ENGINE}"

    case "$engine" in
        claude) run_claude "$prompt" "$op_id" ;;
        codex)  run_codex "$prompt" "$op_id" ;;
        *)
            log_error "Unknown engine: $engine"
            return 1
            ;;
    esac
}

# ============================================================================
# SCOPE VALIDATION
# ============================================================================

validate_scope() {
    local violations=""
    local changed_files
    changed_files=$(cd "$PARALLAX_DIR" && git diff --name-only HEAD 2>/dev/null)

    if [[ -z "$changed_files" ]]; then
        log "No files changed"
        return 0
    fi

    while IFS= read -r file; do
        local allowed=false

        # Check against allowlist
        for pattern in "${ALLOWED_PATHS[@]}"; do
            # Exact match or prefix match (for directories)
            if [[ "$file" == "$pattern" ]] || [[ "$file" == "$pattern"* ]]; then
                allowed=true
                break
            fi
        done

        # Check against denylist (overrides allowlist)
        for pattern in "${DENIED_PATTERNS[@]}"; do
            if [[ "$file" == "$pattern"* ]]; then
                allowed=false
                break
            fi
        done

        if [[ "$allowed" == "false" ]]; then
            violations="${violations}${file}\n"
            log_error "Scope violation: $file"
        fi
    done <<< "$changed_files"

    if [[ -n "$violations" ]]; then
        # Revert unauthorized changes
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                (cd "$PARALLAX_DIR" && git checkout -- "$file" 2>/dev/null) || true
                log "Reverted: $file"
            fi
        done <<< "$(echo -e "$violations")"
        return 1
    fi

    return 0
}

# ============================================================================
# BUILD VALIDATION
# ============================================================================

validate_build() {
    log "Running build validation..."

    local build_output
    build_output=$(cd "$PARALLAX_DIR" && npm run build 2>&1) || {
        log_error "Build failed"
        echo "$build_output"
        return 1
    }

    local tsc_output
    tsc_output=$(cd "$PARALLAX_DIR" && npx tsc --noEmit 2>&1) || {
        log_error "TypeScript check failed"
        echo "$tsc_output"
        return 1
    }

    log "Build validation passed"
    echo "Build and TypeScript checks passed"
    return 0
}

# ============================================================================
# GIT OPERATIONS
# ============================================================================

create_branch() {
    local slug="$1"
    local branch_name="ava/$(date +%Y-%m-%d)-${slug}"

    log "Creating branch: $branch_name"
    (cd "$PARALLAX_DIR" && git checkout dev && git pull origin dev 2>/dev/null && git checkout -b "$branch_name") || {
        log_error "Branch creation failed"
        return 1
    }

    echo "$branch_name"
}

create_pr() {
    local branch="$1"
    local instruction="$2"
    local files_changed="$3"
    local engine_output="$4"

    log "Creating PR for branch: $branch"

    local pr_body="## Ava Self-Modification

**Instruction:** ${instruction}

**Engine:** ${AVA_ENGINE}

**Files changed:**
${files_changed}

**What I did:**
${engine_output}

---
This PR was created autonomously by Ava via HYDRA Telegram.
Awaiting Eddie's approval to merge."

    local pr_url
    pr_url=$(cd "$PARALLAX_DIR" && gh pr create \
        --base dev \
        --head "$branch" \
        --title "Ava: ${instruction:0:60}" \
        --body "$pr_body" 2>&1) || {
        log_error "PR creation failed: $pr_url"
        return 1
    }

    echo "$pr_url"
}

# ============================================================================
# DATABASE OPERATIONS
# ============================================================================

create_operation() {
    local instruction="$1"
    local engine="$2"

    local op_id
    op_id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:16])" 2>/dev/null || echo "op-$(date +%s)")

    sqlite3 "$HYDRA_DB" "
        INSERT INTO ava_operations (id, instruction, engine, status)
        VALUES ('${op_id}', '$(echo "$instruction" | sed "s/'/''/g")', '${engine}', 'pending');
    " 2>/dev/null

    echo "$op_id"
}

update_operation() {
    local op_id="$1"
    local field="$2"
    local value="$3"

    sqlite3 "$HYDRA_DB" "
        UPDATE ava_operations
        SET ${field} = '$(echo "$value" | sed "s/'/''/g")'
        WHERE id = '${op_id}';
    " 2>/dev/null
}

# ============================================================================
# SUBCOMMAND: instruction
# ============================================================================

handle_instruction() {
    local raw_message="$1"
    local message_id="${2:-}"

    log "=== Instruction received ==="
    log "Message: ${raw_message:0:200}"

    # Check for engine override in message: "ava (codex) update the hero"
    local engine="$AVA_ENGINE"
    if echo "$raw_message" | grep -qi "(codex)"; then
        engine="codex"
        raw_message=$(echo "$raw_message" | sed -E 's/\(codex\)//gi' | sed 's/^[[:space:]]*//')
    elif echo "$raw_message" | grep -qi "(claude)"; then
        engine="claude"
        raw_message=$(echo "$raw_message" | sed -E 's/\(claude\)//gi' | sed 's/^[[:space:]]*//')
    fi

    # Strip "ava" prefix from instruction
    local instruction
    instruction=$(echo "$raw_message" | sed -E 's/^@?ava[,:]?\s*//i')

    # Check freeze
    check_freeze "$message_id" || return 0

    # Create operation record
    local op_id
    op_id=$(create_operation "$instruction" "$engine")
    log "Operation created: $op_id (engine: $engine)"

    # Notify Eddie
    send_response "Working on it... (engine: ${engine}, op: ${op_id})" "$message_id"

    # Create a slug from the instruction
    local slug
    slug=$(echo "$instruction" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)

    # Create branch
    local branch
    branch=$(create_branch "$slug") || {
        local err="Failed to create branch"
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "$err"
        send_response "Failed: couldn't create branch. Check logs." "$message_id"
        return 1
    }
    update_operation "$op_id" "branch" "$branch"
    update_operation "$op_id" "status" "engine_running"

    # Build prompt with soul context
    local prompt
    prompt=$(build_prompt "$instruction")

    # Run engine
    local engine_output
    engine_output=$(run_engine "$prompt" "$op_id" "$engine") || {
        # If primary engine fails, try fallback
        if [[ "$engine" == "claude" ]]; then
            log "Claude failed, falling back to codex"
            send_response "Claude engine timed out, switching to Codex..." "$message_id"
            engine="codex"
            engine_output=$(run_engine "$prompt" "$op_id" "codex") || {
                update_operation "$op_id" "status" "failed"
                update_operation "$op_id" "error" "Both engines failed"
                send_response "Both engines failed. Try a simpler instruction." "$message_id"
                (cd "$PARALLAX_DIR" && git checkout dev && git branch -D "$branch" 2>/dev/null) || true
                return 1
            }
        else
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Engine failed"
            send_response "Engine failed. Try a simpler instruction or switch engine." "$message_id"
            (cd "$PARALLAX_DIR" && git checkout dev && git branch -D "$branch" 2>/dev/null) || true
            return 1
        fi
    }

    update_operation "$op_id" "engine_output" "${engine_output:0:2000}"
    update_operation "$op_id" "status" "validating"

    # Validate scope
    if ! validate_scope; then
        local scope_msg="Scope violation detected -- I reverted unauthorized file changes. The remaining changes (if any) are within my allowed files."
        log "$scope_msg"
    fi

    # Check if any changes remain
    local changed_files
    changed_files=$(cd "$PARALLAX_DIR" && git diff --name-only HEAD 2>/dev/null)

    if [[ -z "$changed_files" ]]; then
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "No changes made"
        send_response "No changes were made. Try being more specific." "$message_id"
        (cd "$PARALLAX_DIR" && git checkout dev && git branch -D "$branch" 2>/dev/null) || true
        return 0
    fi

    update_operation "$op_id" "files_changed" "$changed_files"

    # Validate build
    local build_result
    build_result=$(validate_build) || {
        # Retry once with error context
        log "Build failed, retrying with error context..."
        local retry_prompt="${prompt}

BUILD FAILED. Here is the error:
${build_result}

Fix the build error while still accomplishing the original instruction."

        (cd "$PARALLAX_DIR" && git checkout -- . 2>/dev/null)
        engine_output=$(run_engine "$retry_prompt" "$op_id" "$engine") || {
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Build failed after retry"
            update_operation "$op_id" "build_output" "${build_result:0:2000}"
            send_response "Build failed after retry. Here's the error:

${build_result:0:500}" "$message_id"
            (cd "$PARALLAX_DIR" && git checkout dev && git branch -D "$branch" 2>/dev/null) || true
            return 1
        }

        # Validate again
        build_result=$(validate_build) || {
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Build failed after retry"
            update_operation "$op_id" "build_output" "${build_result:0:2000}"
            send_response "Build failed after retry. Here's the error:

${build_result:0:500}" "$message_id"
            (cd "$PARALLAX_DIR" && git checkout dev && git branch -D "$branch" 2>/dev/null) || true
            return 1
        }
    }

    update_operation "$op_id" "build_output" "PASSED"

    # Commit changes
    local commit_msg="Ava: ${instruction:0:60}

Instruction: ${instruction}
Engine: ${engine}
Operation: ${op_id}

Co-Authored-By: Ava <ava@parallax.space>"

    (cd "$PARALLAX_DIR" && git add -A && git commit -m "$commit_msg") || {
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "Commit failed"
        send_response "Failed to commit changes." "$message_id"
        return 1
    }

    # Push branch
    (cd "$PARALLAX_DIR" && git push origin "$branch" 2>/dev/null) || {
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "Push failed"
        send_response "Failed to push branch." "$message_id"
        return 1
    }

    # Create PR
    local pr_url
    pr_url=$(create_pr "$branch" "$instruction" "$changed_files" "${engine_output:0:500}") || {
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "PR creation failed"
        send_response "Changes committed but PR creation failed. Check GitHub." "$message_id"
        return 1
    }

    # Extract PR number from URL
    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
    update_operation "$op_id" "pr_url" "$pr_url"
    update_operation "$op_id" "pr_number" "$pr_number"
    update_operation "$op_id" "status" "pr_created"

    # Create conversation thread for approval
    local thread_id
    thread_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "thread-$(date +%s)")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO conversation_threads (id, thread_type, state, context_data, expires_at)
        VALUES ('${thread_id}', 'ava_approval', 'awaiting_input',
                '{\"op_id\": \"${op_id}\", \"pr_url\": \"${pr_url}\", \"pr_number\": \"${pr_number}\"}',
                datetime('now', '+7 days'));
    " 2>/dev/null

    update_operation "$op_id" "conversation_thread_id" "$thread_id"
    update_operation "$op_id" "status" "awaiting_approval"

    # Send approval request
    local approval_msg="Done! Here's what I changed:

PR: Ava: ${instruction:0:60}
${pr_url}

Files changed:
$(echo "$changed_files" | sed 's/^/  /')

Reply:
  approve - merge and deploy
  reject - close the PR
  revise: [feedback] - I'll adjust"

    local sent_id
    sent_id=$(send_response "$approval_msg" "$message_id")

    # Store telegram context for reply routing
    if [[ -n "$sent_id" ]]; then
        local ctx_id
        ctx_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "ctx-$(date +%s)")
        sqlite3 "$HYDRA_DB" "
            INSERT INTO telegram_context (id, telegram_message_id, hydra_entity_type, hydra_entity_id)
            VALUES ('${ctx_id}', ${sent_id}, 'ava_approval', '${thread_id}');
        " 2>/dev/null

        # Also update the conversation thread with the telegram message id
        sqlite3 "$HYDRA_DB" "
            UPDATE conversation_threads
            SET telegram_message_id = ${sent_id}
            WHERE id = '${thread_id}';
        " 2>/dev/null
    fi

    # Log activity
    local act_id
    act_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
        VALUES ('${act_id}', 'ava', 'pr_created', 'ava_operation', '${op_id}',
                'Ava created PR for: ${instruction:0:80}');
    " 2>/dev/null

    log "=== Instruction complete: PR created ($pr_url) ==="

    # Return to dev branch
    (cd "$PARALLAX_DIR" && git checkout dev 2>/dev/null) || true
}

# ============================================================================
# SUBCOMMAND: approval
# ============================================================================

handle_approval() {
    local reply="$1"
    local thread_id="$2"

    log "=== Approval handler ==="
    log "Reply: $reply, Thread: $thread_id"

    # Get operation context from thread
    local context
    context=$(sqlite3 "$HYDRA_DB" "
        SELECT context_data FROM conversation_threads
        WHERE id = '${thread_id}' AND thread_type = 'ava_approval' AND state = 'awaiting_input';
    " 2>/dev/null)

    if [[ -z "$context" ]]; then
        log_error "No active approval thread: $thread_id"
        send_response "No active approval found for this thread."
        return 1
    fi

    local op_id
    op_id=$(echo "$context" | python3 -c "import sys,json; print(json.load(sys.stdin)['op_id'])" 2>/dev/null)
    local pr_url
    pr_url=$(echo "$context" | python3 -c "import sys,json; print(json.load(sys.stdin)['pr_url'])" 2>/dev/null)
    local pr_number
    pr_number=$(echo "$context" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pr_number',''))" 2>/dev/null)

    # Parse reply intent
    local reply_lower
    reply_lower=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')

    if [[ "$reply_lower" == "approve"* ]] || [[ "$reply_lower" == "yes"* ]] || [[ "$reply_lower" == "lgtm"* ]] || [[ "$reply_lower" == "ship"* ]] || [[ "$reply_lower" == "merge"* ]]; then
        handle_merge "$op_id" "$pr_url" "$thread_id"
    elif [[ "$reply_lower" == "reject"* ]] || [[ "$reply_lower" == "no"* ]] || [[ "$reply_lower" == "close"* ]]; then
        handle_reject "$op_id" "$pr_url" "$thread_id"
    elif [[ "$reply_lower" == "revise"* ]]; then
        local feedback
        feedback=$(echo "$reply" | sed -E 's/^revise:?\s*//i')
        handle_revision "$op_id" "$pr_url" "$thread_id" "$feedback"
    else
        send_response "I didn't understand. Reply with:
  approve - merge and deploy
  reject - close the PR
  revise: [feedback] - I'll adjust"
    fi
}

handle_merge() {
    local op_id="$1"
    local pr_url="$2"
    local thread_id="$3"

    log "Merging PR: $pr_url"

    # Merge (never squash)
    (cd "$PARALLAX_DIR" && gh pr merge "$pr_url" --merge) || {
        log_error "Merge failed"
        send_response "Merge failed. Check GitHub for details."
        return 1
    }

    update_operation "$op_id" "status" "merged"

    # Close thread
    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads SET state = 'completed' WHERE id = '${thread_id}';
    " 2>/dev/null

    # Clean up branch
    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    if [[ -n "$branch" ]]; then
        (cd "$PARALLAX_DIR" && git push origin --delete "$branch" 2>/dev/null) || true
    fi

    send_response "Merged! Vercel deploying now (~60s). Live at tryparallax.space"

    # Log activity
    local act_id
    act_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
        VALUES ('${act_id}', 'ava', 'pr_merged', 'ava_operation', '${op_id}', 'Eddie approved Ava PR merge');
    " 2>/dev/null

    log "PR merged successfully"
}

handle_reject() {
    local op_id="$1"
    local pr_url="$2"
    local thread_id="$3"

    log "Rejecting PR: $pr_url"

    (cd "$PARALLAX_DIR" && gh pr close "$pr_url") || true

    # Clean up branch
    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    if [[ -n "$branch" ]]; then
        (cd "$PARALLAX_DIR" && git push origin --delete "$branch" 2>/dev/null) || true
        (cd "$PARALLAX_DIR" && git branch -D "$branch" 2>/dev/null) || true
    fi

    update_operation "$op_id" "status" "rejected"
    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads SET state = 'completed' WHERE id = '${thread_id}';
    " 2>/dev/null

    send_response "PR closed and branch cleaned up."
    log "PR rejected"
}

handle_revision() {
    local op_id="$1"
    local pr_url="$2"
    local thread_id="$3"
    local feedback="$4"

    log "Revision requested: $feedback"

    # Get original instruction
    local instruction
    instruction=$(sqlite3 "$HYDRA_DB" "SELECT instruction FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    local engine
    engine=$(sqlite3 "$HYDRA_DB" "SELECT engine FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)

    send_response "Revising based on your feedback..."

    # Checkout the branch
    (cd "$PARALLAX_DIR" && git checkout "$branch" 2>/dev/null) || {
        send_response "Couldn't checkout the branch. Try a new instruction instead."
        return 1
    }

    # Build prompt with revision context
    local prompt
    prompt=$(build_prompt "$instruction")
    prompt="${prompt}

## Revision Feedback from Eddie
Eddie reviewed the changes and said: \"${feedback}\"

Please adjust the code to address this feedback while keeping the original instruction in mind."

    # Re-run engine
    local engine_output
    engine_output=$(run_engine "$prompt" "$op_id" "$engine") || {
        send_response "Engine failed during revision. Try a new instruction."
        (cd "$PARALLAX_DIR" && git checkout dev 2>/dev/null) || true
        return 1
    }

    # Validate scope and build
    validate_scope || true
    local build_result
    build_result=$(validate_build) || {
        send_response "Build failed after revision:

${build_result:0:500}"
        (cd "$PARALLAX_DIR" && git checkout dev 2>/dev/null) || true
        return 1
    }

    # Commit and force-push
    local revise_msg="Ava: revise - ${feedback:0:60}

Original: ${instruction}
Feedback: ${feedback}
Engine: ${engine}
Operation: ${op_id}

Co-Authored-By: Ava <ava@parallax.space>"

    (cd "$PARALLAX_DIR" && git add -A && git commit -m "$revise_msg" && git push origin "$branch" --force-with-lease 2>/dev/null) || {
        send_response "Failed to push revision."
        (cd "$PARALLAX_DIR" && git checkout dev 2>/dev/null) || true
        return 1
    }

    update_operation "$op_id" "engine_output" "${engine_output:0:2000}"

    # Re-prompt for approval
    local changed_files
    changed_files=$(cd "$PARALLAX_DIR" && git diff --name-only dev..."$branch" 2>/dev/null)

    send_response "Revised! Updated PR:
${pr_url}

Files changed:
$(echo "$changed_files" | sed 's/^/  /')

Reply:
  approve - merge and deploy
  reject - close the PR
  revise: [more feedback]"

    (cd "$PARALLAX_DIR" && git checkout dev 2>/dev/null) || true
    log "Revision pushed"
}

# ============================================================================
# SUBCOMMAND: status
# ============================================================================

handle_status() {
    local ops
    ops=$(sqlite3 "$HYDRA_DB" "
        SELECT id, instruction, engine, status, pr_url, created_at
        FROM ava_operations
        WHERE status NOT IN ('merged', 'rejected', 'failed')
        ORDER BY created_at DESC
        LIMIT 5;
    " 2>/dev/null)

    if [[ -z "$ops" ]]; then
        echo "No active Ava operations."
        return 0
    fi

    local msg="Active Ava operations:
"
    while IFS='|' read -r id instruction engine status pr_url created_at; do
        msg="${msg}
[${status}] ${instruction:0:50}
  engine: ${engine} | created: ${created_at}
  ${pr_url:-no PR yet}
"
    done <<< "$ops"

    # Also show recent completed
    local recent
    recent=$(sqlite3 "$HYDRA_DB" "
        SELECT COUNT(*) FROM ava_operations WHERE status = 'merged'
        AND created_at > datetime('now', '-7 days');
    " 2>/dev/null)

    msg="${msg}
Merged in last 7 days: ${recent:-0}"

    echo "$msg"
}

# ============================================================================
# DRY RUN MODE (for testing)
# ============================================================================

handle_dry_run() {
    local instruction="$1"
    echo "=== DRY RUN ==="
    echo ""
    echo "Engine: $AVA_ENGINE"
    echo "Instruction: $instruction"
    echo ""
    echo "=== PROMPT ==="
    build_prompt "$instruction"
    echo ""
    echo "=== SCOPE ==="
    echo "Allowed files:"
    printf '  %s\n' "${ALLOWED_PATHS[@]}"
    echo "Denied patterns:"
    printf '  %s\n' "${DENIED_PATTERNS[@]}"
    echo ""
    echo "=== Would create branch: ava/$(date +%Y-%m-%d)-$(echo "$instruction" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40) ==="
}

# ============================================================================
# MAIN DISPATCHER
# ============================================================================

SUBCOMMAND="${1:-help}"
shift || true

case "$SUBCOMMAND" in
    instruction)
        handle_instruction "${1:-}" "${2:-}"
        ;;
    approval)
        handle_approval "${1:-}" "${2:-}"
        ;;
    status)
        result=$(handle_status)
        echo "$result"
        # If called from Telegram, also send via bot
        if [[ "${TELEGRAM_RESPOND:-}" == "true" ]]; then
            send_response "$result"
        fi
        ;;
    dry-run)
        handle_dry_run "${1:-test instruction}"
        ;;
    help|*)
        echo "ava-autonomy.sh - Ava's autonomous code modification handler"
        echo ""
        echo "Usage:"
        echo "  ava-autonomy.sh instruction <message> <message_id>"
        echo "  ava-autonomy.sh approval <reply> <thread_id>"
        echo "  ava-autonomy.sh status"
        echo "  ava-autonomy.sh dry-run <instruction>"
        echo ""
        echo "Environment:"
        echo "  AVA_ENGINE=claude|codex  (default: claude)"
        echo "  TELEGRAM_RESPOND=true    (send status via Telegram)"
        ;;
esac
