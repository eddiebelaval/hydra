#!/bin/bash
# ava-autonomy.sh - Ava's autonomous code modification handler (v2)
#
# Rewritten 2026-02-20 for "robot-ready" operation:
#   - Worktree isolation (never touches Eddie's working directory)
#   - Dedicated build environment (ava-build.env)
#   - Preflight checks before every operation
#   - Trap-based cleanup (clean state guaranteed on crash/kill)
#   - Concurrency lock (one operation at a time)
#   - Three-tier push cascade (SSH → HTTPS → .patch)
#   - Allowlist-only staging (no git add -A)
#
# Subcommands:
#   instruction <message> <message_id>  - Process Eddie's instruction
#   approval <reply> <thread_id>        - Handle approve/reject/revise
#   status                              - Show open Ava operations
#   dry-run <instruction>               - Test prompt building
#
# Engines:
#   claude (default) - Claude CLI (Opus) for primary work
#   codex            - Codex CLI (GPT) for bulk/boilerplate

set -uo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
HYDRA_ENV="$HYDRA_ROOT/config/telegram.env"
PARALLAX_DIR="$HOME/Development/id8/products/parallax"

# Worktree-based paths (Ava's isolated workspace)
AVA_WORKTREE="$HOME/Development/.worktrees/parallax/ava-workspace"
AVA_SOUL_DIR="$AVA_WORKTREE/src/ava"
AVA_BUILD_ENV="$HYDRA_ROOT/config/ava-build.env"
AVA_PREFLIGHT="$HYDRA_ROOT/tools/ava-preflight.sh"
AVA_LOCK_FILE="$HYDRA_ROOT/state/ava-autonomy.lock"
LOCKFILE_SHA_FILE="$HYDRA_ROOT/state/ava-lockfile-sha.txt"
SSH_KEY="$HOME/.ssh/id_ed25519"

# Engine configuration
AVA_ENGINE="${AVA_ENGINE:-claude}"
CLAUDE_CLI="$HOME/.local/bin/claude"
CODEX_CLI="$HOME/.nvm/versions/node/v22.21.1/bin/codex"

# Logging
LOG_DIR="$HOME/Library/Logs/claude-automation/ava-autonomy"
LOG_FILE="$LOG_DIR/ava-$(date +%Y-%m-%d).log"
LOG_JSON="$LOG_DIR/ava-$(date +%Y-%m-%d).jsonl"
AVA_LOG_FORMAT="${AVA_LOG_FORMAT:-text}"  # "text" (default) or "json"
mkdir -p "$LOG_DIR"

# Current operation tracking (for cleanup)
CURRENT_OP_ID=""
CURRENT_BRANCH=""
LOCK_ACQUIRED=false

# Engine cost tracking (set by run_claude/run_codex)
LAST_ENGINE_ELAPSED=0
LAST_ENGINE_MODEL=""

log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Always write human-readable text log
    echo "[$ts] [ava] $msg" >> "$LOG_FILE"

    # Additionally write structured JSON log
    if [[ "$AVA_LOG_FORMAT" == "json" ]] || [[ -f "$LOG_JSON" ]]; then
        printf '{"ts":"%s","level":"info","component":"ava","op":"%s","msg":"%s"}\n' \
            "$ts" "${CURRENT_OP_ID:-}" "$(echo "$msg" | sed 's/"/\\"/g' | head -c 500)" >> "$LOG_JSON"
    fi
}

log_error() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$ts] [ava] ERROR: $msg" >> "$LOG_FILE"

    # Always write errors to JSON (errors are high-value)
    printf '{"ts":"%s","level":"error","component":"ava","op":"%s","msg":"%s"}\n' \
        "$ts" "${CURRENT_OP_ID:-}" "$(echo "$msg" | sed 's/"/\\"/g' | head -c 500)" >> "$LOG_JSON"
}

# ============================================================================
# TRAP-BASED CLEANUP
# ============================================================================

cleanup() {
    local exit_code=$?
    log "Cleanup triggered (exit_code=$exit_code)"

    # Reset worktree to clean state
    if [[ -d "$AVA_WORKTREE" ]]; then
        (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git reset --hard origin/dev >/dev/null 2>&1 && git clean -fd >/dev/null 2>&1) || true
        log "Worktree reset to clean state"
    fi

    # Delete the feature branch locally if it was created but not pushed
    if [[ -n "$CURRENT_BRANCH" ]]; then
        (cd "$AVA_WORKTREE" && git branch -D "$CURRENT_BRANCH" >/dev/null 2>&1) || true
    fi

    # Release lock
    release_lock

    exit $exit_code
}

# Only set trap for instruction subcommand (not status/help/approval)
# Trap is set inside handle_instruction

# ============================================================================
# CONCURRENCY LOCK
# ============================================================================

acquire_lock() {
    local lock_stale_minutes=30

    if [[ -f "$AVA_LOCK_FILE" ]]; then
        local lock_age
        lock_age=$(( ($(date +%s) - $(stat -f %m "$AVA_LOCK_FILE" 2>/dev/null || echo "0")) / 60 ))

        if [[ $lock_age -gt $lock_stale_minutes ]]; then
            log "Stale lock detected (${lock_age}m old), breaking it"
            rm -f "$AVA_LOCK_FILE"
        else
            local lock_pid
            lock_pid=$(cat "$AVA_LOCK_FILE" 2>/dev/null || echo "unknown")
            log_error "Lock held by PID $lock_pid (${lock_age}m old)"
            return 1
        fi
    fi

    echo "$$" > "$AVA_LOCK_FILE"
    LOCK_ACQUIRED=true
    log "Lock acquired (PID $$)"
    return 0
}

release_lock() {
    if [[ "$LOCK_ACQUIRED" == "true" ]]; then
        rm -f "$AVA_LOCK_FILE"
        LOCK_ACQUIRED=false
        log "Lock released"
    fi
}

# ============================================================================
# LOAD CREDENTIALS
# ============================================================================

AVA_TELEGRAM_ENV="$HYDRA_ROOT/config/ava-telegram.env"

if [[ -n "${AVA_BOT_TOKEN:-}" ]]; then
    TELEGRAM_BOT_TOKEN="$AVA_BOT_TOKEN"
    TELEGRAM_CHAT_ID="${AVA_BOT_CHAT_ID:-}"
    log "Using Ava's own bot token"
elif [[ -f "$AVA_TELEGRAM_ENV" ]]; then
    source "$AVA_TELEGRAM_ENV"
    if [[ -n "${AVA_TELEGRAM_BOT_TOKEN:-}" ]] && [[ "${AVA_TELEGRAM_BOT_TOKEN}" != "PASTE_TOKEN_HERE" ]]; then
        TELEGRAM_BOT_TOKEN="$AVA_TELEGRAM_BOT_TOKEN"
        TELEGRAM_CHAT_ID="${AVA_TELEGRAM_CHAT_ID:-$TELEGRAM_CHAT_ID}"
        log "Using Ava's bot token from config"
    fi
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -f "$HYDRA_ENV" ]]; then
    source "$HYDRA_ENV"
    log "Falling back to HYDRA bot token"
fi

if [[ -f "$HYDRA_ENV" ]]; then
    ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ENV" 2>/dev/null | head -1 | cut -d'"' -f2)
    export ANTHROPIC_API_KEY
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN:-}"

# ============================================================================
# FILE SCOPE (unchanged from v1)
# ============================================================================

ALLOWED_PATHS=(
    "src/app/page.tsx"
    "src/lib/narration-script.ts"
    "src/components/landing/"
    "src/app/globals.css"
)

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
# ENVIRONMENT LOADING (Keychain → ava-build.env → .env.local fallback)
# ============================================================================

# Retrieve a secret from macOS Keychain
# Usage: get_secret "service-name" "account-name"
# To store: security add-generic-password -s "ava-parallax" -a "ANTHROPIC_API_KEY" -w "sk-ant-..."
get_secret() {
    local service="$1"
    local account="$2"
    security find-generic-password -s "$service" -a "$account" -w 2>/dev/null || echo ""
}

AVA_KEYCHAIN_SERVICE="ava-parallax"

load_build_env() {
    local loaded_from=""

    # Tier 1: macOS Keychain (most secure, optional)
    local keychain_key
    keychain_key=$(get_secret "$AVA_KEYCHAIN_SERVICE" "ANTHROPIC_API_KEY")
    if [[ -n "$keychain_key" ]]; then
        # Load all available secrets from Keychain
        local vars=(
            ANTHROPIC_API_KEY NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY
            SUPABASE_SERVICE_ROLE_KEY STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET
            STRIPE_PRICE_PRO_MONTHLY STRIPE_PRICE_PREMIUM_MONTHLY
            ELEVENLABS_API_KEY ELEVENLABS_VOICE_ID
            UPSTASH_REDIS_REST_URL UPSTASH_REDIS_REST_TOKEN NEXT_PUBLIC_APP_URL
        )
        local found=0
        for var in "${vars[@]}"; do
            local val
            val=$(get_secret "$AVA_KEYCHAIN_SERVICE" "$var")
            if [[ -n "$val" ]]; then
                export "$var=$val"
                found=$((found + 1))
            fi
        done

        if [[ $found -gt 5 ]]; then
            loaded_from="keychain ($found vars)"
            log "Loaded build env from macOS Keychain ($found secrets)"
        else
            log "Keychain has only $found vars — falling through to file-based env"
        fi
    fi

    # Tier 2: ava-build.env (dedicated file, always available)
    if [[ -z "$loaded_from" ]] && [[ -f "$AVA_BUILD_ENV" ]]; then
        set -a
        source "$AVA_BUILD_ENV" 2>/dev/null || true
        set +a
        loaded_from="ava-build.env"
        log "Loaded build env from ava-build.env"
    fi

    # Tier 3: .env.local fallbacks
    if [[ -z "$loaded_from" ]]; then
        if [[ -f "$AVA_WORKTREE/.env.local" ]]; then
            set -a
            source "$AVA_WORKTREE/.env.local" 2>/dev/null || true
            set +a
            loaded_from="worktree .env.local"
            log "Loaded build env from worktree .env.local"
        elif [[ -f "$PARALLAX_DIR/.env.local" ]]; then
            set -a
            source "$PARALLAX_DIR/.env.local" 2>/dev/null || true
            set +a
            loaded_from="main repo .env.local"
            log "Loaded build env from main repo .env.local (fallback)"
        fi
    fi

    if [[ -z "$loaded_from" ]]; then
        log_error "No build environment found"
        return 1
    fi

    return 0
}

# ============================================================================
# SOUL LOADER (Build prompt context from consciousness files)
# ============================================================================

build_prompt() {
    local instruction="$1"

    local kernel=""
    for f in identity.md values.md purpose.md voice-rules.md; do
        if [[ -f "$AVA_SOUL_DIR/kernel/$f" ]]; then
            kernel="${kernel}$(cat "$AVA_SOUL_DIR/kernel/$f")
"
        fi
    done

    local awareness=""
    for f in capabilities.md limitations.md; do
        if [[ -f "$AVA_SOUL_DIR/self-awareness/$f" ]]; then
            awareness="${awareness}$(cat "$AVA_SOUL_DIR/self-awareness/$f")
"
        fi
    done

    local design_kit=""
    if [[ -f "$HYDRA_ROOT/tools/ava-design-kit.md" ]]; then
        design_kit=$(cat "$HYDRA_ROOT/tools/ava-design-kit.md")
    fi

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
# ENGINE TIMEOUT (macOS has no `timeout` command — use watchdog pattern)
# ============================================================================

ENGINE_TIMEOUT="${ENGINE_TIMEOUT:-300}"  # 5 minutes default

run_with_timeout() {
    local timeout_secs="$1"
    shift
    local output_file="$1"
    shift

    # Run command in background, capturing output
    "$@" > "$output_file" 2>/dev/null &
    local cmd_pid=$!

    # Watchdog: kill engine if it exceeds timeout
    (sleep "$timeout_secs" && kill -TERM "$cmd_pid" 2>/dev/null && kill -TERM 0 2>/dev/null) &
    local watchdog_pid=$!

    # Wait for engine to finish
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?

    # Kill watchdog (engine finished before timeout)
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    # SIGTERM exit code = 143
    if [[ $exit_code -eq 143 ]]; then
        log_error "Engine timed out after ${timeout_secs}s"
        return 124  # Match GNU timeout exit code
    fi

    return $exit_code
}

# ============================================================================
# ENGINE: CLAUDE CLI (Primary)
# ============================================================================

run_claude() {
    local prompt="$1"
    local op_id="$2"
    local output_file="/tmp/ava-engine-${op_id}.txt"
    local start_time
    start_time=$(date +%s)

    log "Running Claude engine (Opus) in worktree... (timeout: ${ENGINE_TIMEOUT}s)"

    # Write prompt to temp file (stdin piping doesn't work with background processes)
    local prompt_file="/tmp/ava-prompt-${op_id}.txt"
    echo "$prompt" > "$prompt_file"

    run_with_timeout "$ENGINE_TIMEOUT" "$output_file" \
        bash -c "cd \"$AVA_WORKTREE\" && CLAUDECODE= \"$CLAUDE_CLI\" -p \
            --model claude-opus-4-6 \
            --allowedTools 'Edit,Write,Read,Bash,Glob,Grep' \
            --dangerously-skip-permissions \
            < \"$prompt_file\""

    local exit_code=$?
    rm -f "$prompt_file"

    LAST_ENGINE_ELAPSED=$(( $(date +%s) - start_time ))
    LAST_ENGINE_MODEL="claude-opus-4-6"
    log "Claude engine finished in ${LAST_ENGINE_ELAPSED}s (exit: $exit_code)"

    if [[ $exit_code -eq 124 ]]; then
        log_error "Claude engine TIMED OUT after ${ENGINE_TIMEOUT}s"
        return 1
    fi

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
    local start_time
    start_time=$(date +%s)

    log "Running Codex engine (GPT) in worktree... (timeout: ${ENGINE_TIMEOUT}s)"

    local prompt_file="/tmp/ava-prompt-${op_id}.txt"
    echo "$prompt" > "$prompt_file"

    run_with_timeout "$ENGINE_TIMEOUT" "$output_file" \
        bash -c "cd \"$AVA_WORKTREE\" && \"$CODEX_CLI\" exec --full-auto \
            -m 'o4-mini' \
            < \"$prompt_file\""

    local exit_code=$?
    rm -f "$prompt_file"

    LAST_ENGINE_ELAPSED=$(( $(date +%s) - start_time ))
    LAST_ENGINE_MODEL="o4-mini"
    log "Codex engine finished in ${LAST_ENGINE_ELAPSED}s (exit: $exit_code)"

    if [[ $exit_code -eq 124 ]]; then
        log_error "Codex engine TIMED OUT after ${ENGINE_TIMEOUT}s"
        return 1
    fi

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
# SCOPE VALIDATION (worktree-based)
# ============================================================================

validate_scope() {
    local violations=""

    # Get BOTH modified tracked files AND new untracked files
    local modified_files untracked_files changed_files
    modified_files=$(cd "$AVA_WORKTREE" && git diff --name-only dev 2>/dev/null)
    untracked_files=$(cd "$AVA_WORKTREE" && git ls-files --others --exclude-standard 2>/dev/null)
    changed_files=$(printf '%s\n%s' "$modified_files" "$untracked_files" | sort -u | sed '/^$/d')

    if [[ -z "$changed_files" ]]; then
        log "No files changed"
        return 0
    fi

    while IFS= read -r file; do
        local allowed=false

        for pattern in "${ALLOWED_PATHS[@]}"; do
            if [[ "$file" == "$pattern" ]] || [[ "$file" == "$pattern"* ]]; then
                allowed=true
                break
            fi
        done

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
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                # For tracked files, revert; for untracked (new) files, delete
                if (cd "$AVA_WORKTREE" && git ls-files --error-unmatch "$file" >/dev/null 2>&1); then
                    (cd "$AVA_WORKTREE" && git checkout -- "$file" 2>/dev/null) || true
                else
                    rm -f "$AVA_WORKTREE/$file" 2>/dev/null || true
                fi
                log "Reverted: $file"
            fi
        done <<< "$(echo -e "$violations")"
        return 1
    fi

    return 0
}

# ============================================================================
# BUILD VALIDATION (graceful degradation)
# ============================================================================

validate_build() {
    log "Running build validation in worktree..."

    # Load env vars for build
    load_build_env

    local build_mode="full"

    # Try full build first
    local build_output
    build_output=$(cd "$AVA_WORKTREE" && npm run build 2>&1) || {
        # If full build fails because of missing env vars, try tsc-only
        if echo "$build_output" | grep -qi "env\|environment\|NEXT_PUBLIC\|undefined"; then
            log "Full build failed (likely env issue), falling back to tsc-only"
            build_mode="tsc-only"
        else
            log_error "Build failed"
            echo "$build_output"
            return 1
        fi
    }

    # Run TypeScript check (strict — no error filtering)
    local tsc_output tsc_exit
    tsc_output=$(cd "$AVA_WORKTREE" && npx tsc --noEmit 2>&1) || tsc_exit=$?

    if [[ "${tsc_exit:-0}" -ne 0 ]]; then
        log_error "TypeScript check failed"
        echo "$tsc_output" | grep "error TS" | head -20
        return 1
    fi

    if [[ "$build_mode" == "full" ]]; then
        log "Build validation passed (full build + tsc)"
        echo "Build and TypeScript checks passed (full)"
    else
        log "Build validation passed (tsc-only, env vars unavailable for full build)"
        echo "TypeScript check passed (tsc-only mode — env vars unavailable for full build)"
    fi
    return 0
}

# ============================================================================
# STAGE ALLOWED FILES (replaces git add -A)
# ============================================================================

stage_allowed_files() {
    local staged_count=0
    local skipped=""
    local changed_files

    # Get BOTH modified tracked files AND new untracked files
    # git diff catches modifications; git ls-files catches new files
    local modified_files untracked_files
    modified_files=$(cd "$AVA_WORKTREE" && git diff --name-only dev 2>/dev/null)
    untracked_files=$(cd "$AVA_WORKTREE" && git ls-files --others --exclude-standard 2>/dev/null)

    # Combine and deduplicate
    changed_files=$(printf '%s\n%s' "$modified_files" "$untracked_files" | sort -u | sed '/^$/d')

    if [[ -z "$changed_files" ]]; then
        log "No files to stage"
        return 0
    fi

    while IFS= read -r file; do
        local allowed=false

        for pattern in "${ALLOWED_PATHS[@]}"; do
            if [[ "$file" == "$pattern" ]] || [[ "$file" == "$pattern"* ]]; then
                allowed=true
                break
            fi
        done

        for pattern in "${DENIED_PATTERNS[@]}"; do
            if [[ "$file" == "$pattern"* ]]; then
                allowed=false
                break
            fi
        done

        if [[ "$allowed" == "true" ]]; then
            (cd "$AVA_WORKTREE" && git add "$file" 2>/dev/null)
            staged_count=$((staged_count + 1))
            log "Staged: $file"
        else
            skipped="${skipped}  ${file}\n"
            log "Skipped (not in allowlist): $file"
        fi
    done <<< "$changed_files"

    if [[ -n "$skipped" ]]; then
        log "Skipped files:\n$(echo -e "$skipped")"
    fi

    log "Staged $staged_count files"
    return 0
}

# ============================================================================
# GIT OPERATIONS (worktree-based)
# ============================================================================

create_branch() {
    local slug="$1"
    local branch_name="ava/$(date +%Y-%m-%d)-${slug}"

    log "Creating branch in worktree: $branch_name"

    # Fetch latest dev (redirect ALL output — stdout captured by caller)
    (cd "$AVA_WORKTREE" && git fetch origin dev >/dev/null 2>&1) || {
        log_error "git fetch failed"
        return 1
    }

    # Reset to origin/dev
    (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git reset --hard origin/dev >/dev/null 2>&1) || {
        log_error "Reset to origin/dev failed"
        return 1
    }

    # Check if npm ci needed (package-lock.json SHA changed?)
    local current_sha=""
    local cached_sha=""
    if [[ -f "$AVA_WORKTREE/package-lock.json" ]]; then
        current_sha=$(shasum -a 256 "$AVA_WORKTREE/package-lock.json" 2>/dev/null | cut -d' ' -f1)
    fi
    if [[ -f "$LOCKFILE_SHA_FILE" ]]; then
        cached_sha=$(cat "$LOCKFILE_SHA_FILE" 2>/dev/null)
    fi

    if [[ "$current_sha" != "$cached_sha" ]] || [[ ! -d "$AVA_WORKTREE/node_modules" ]]; then
        log "package-lock.json changed or node_modules missing, running npm ci..."
        (cd "$AVA_WORKTREE" && npm ci >/dev/null 2>&1) || {
            log_error "npm ci failed"
            return 1
        }
        echo "$current_sha" > "$LOCKFILE_SHA_FILE"
        log "npm ci complete, SHA cached"
    else
        log "package-lock.json unchanged, skipping npm ci"
    fi

    # Sync soul files (gitignored IP content — lives on disk, not in git)
    # Copy from main repo if they exist there
    local soul_source="$PARALLAX_DIR/src/ava"
    if [[ -d "$soul_source/kernel" ]]; then
        mkdir -p "$AVA_WORKTREE/src/ava/kernel" "$AVA_WORKTREE/src/ava/self-awareness"
        cp "$soul_source/kernel/"*.md "$AVA_WORKTREE/src/ava/kernel/" 2>/dev/null || true
        cp "$soul_source/self-awareness/"*.md "$AVA_WORKTREE/src/ava/self-awareness/" 2>/dev/null || true
        log "Soul files synced from main repo"
    else
        log "Soul files not found in main repo — prompt will use design kit only"
    fi

    # Create feature branch
    (cd "$AVA_WORKTREE" && git checkout -b "$branch_name" >/dev/null 2>&1) || {
        log_error "Branch creation failed: $branch_name"
        return 1
    }

    CURRENT_BRANCH="$branch_name"
    echo "$branch_name"
}

# ============================================================================
# PUSH WITH CASCADE (SSH → HTTPS → .patch)
# ============================================================================

push_branch() {
    local branch="$1"
    local op_id="$2"

    # Tier 1: SSH push with explicit key
    log "Push attempt: SSH with explicit key"
    local ssh_cmd="ssh -i $SSH_KEY -o IdentitiesOnly=yes"
    if (cd "$AVA_WORKTREE" && GIT_SSH_COMMAND="$ssh_cmd" git push origin "$branch" 2>&1); then
        update_operation "$op_id" "push_method" "ssh"
        log "Push succeeded via SSH"
        return 0
    fi
    log "SSH push failed, trying HTTPS..."

    # Tier 2: HTTPS push using gh auth token
    local gh_token
    gh_token=$(gh auth token 2>/dev/null || echo "")
    if [[ -n "$gh_token" ]]; then
        log "Push attempt: HTTPS with gh token"
        local repo_url
        repo_url=$(cd "$AVA_WORKTREE" && git remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||').git
        if (cd "$AVA_WORKTREE" && git push "https://x-access-token:${gh_token}@${repo_url#https://}" "$branch" 2>&1); then
            update_operation "$op_id" "push_method" "https"
            log "Push succeeded via HTTPS"
            return 0
        fi
    fi
    log "HTTPS push failed, saving .patch..."

    # Tier 3: Save as .patch file
    local patch_dir="$HYDRA_ROOT/state/patches"
    mkdir -p "$patch_dir"
    local patch_file="$patch_dir/${op_id}.patch"
    (cd "$AVA_WORKTREE" && git format-patch dev --stdout > "$patch_file" 2>/dev/null)

    if [[ -s "$patch_file" ]]; then
        update_operation "$op_id" "push_method" "patch"
        update_operation "$op_id" "diagnostic_data" "Patch saved: $patch_file"
        log "Push failed, patch saved: $patch_file"
        return 1
    fi

    log_error "All push methods failed"
    return 1
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
    pr_url=$(cd "$AVA_WORKTREE" && gh pr create \
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

    CURRENT_OP_ID="$op_id"
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

    # Set trap for cleanup on this operation
    trap cleanup EXIT INT TERM

    local op_start_time
    op_start_time=$(date +%s)

    log "=== Instruction received ==="
    log "Message: ${raw_message:0:200}"

    # Acquire concurrency lock
    if ! acquire_lock; then
        send_response "I'm already working on something. Try again in a few minutes." "$message_id"
        trap - EXIT INT TERM
        return 0
    fi

    # Run preflight check
    local preflight_result=""
    if [[ -x "$AVA_PREFLIGHT" ]]; then
        log "Running preflight check..."
        preflight_result=$("$AVA_PREFLIGHT" check 2>&1) || {
            log "Preflight failed, attempting heal..."
            "$AVA_PREFLIGHT" heal 2>&1 || true

            # Re-check after heal
            preflight_result=$("$AVA_PREFLIGHT" check 2>&1) || {
                log_error "Preflight still failing after heal"
                send_response "Pre-flight check failed. Diagnostic:

${preflight_result:0:400}

Run 'ava diagnose' for details." "$message_id"
                trap - EXIT INT TERM
                release_lock
                return 1
            }
        }
        log "Preflight passed"
    fi

    # Check for engine override in message
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

    # Create operation record
    local op_id
    op_id=$(create_operation "$instruction" "$engine")
    update_operation "$op_id" "preflight_result" "${preflight_result:0:500}"
    log "Operation created: $op_id (engine: $engine)"

    # Notify Eddie
    send_response "Working on it... (engine: ${engine}, op: ${op_id})" "$message_id"

    # Create a slug from the instruction (flatten to single line, take first 40 chars, trim hyphens)
    local slug
    slug=$(echo "$instruction" | tr '\n' ' ' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40 | sed 's/-$//')

    # Load build environment
    load_build_env || true

    # Create branch in worktree
    local branch
    branch=$(create_branch "$slug") || {
        local err="Failed to create branch in worktree"
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
        if [[ "$engine" == "claude" ]]; then
            log "Claude failed, falling back to codex"
            send_response "Claude engine timed out, switching to Codex..." "$message_id"
            engine="codex"
            update_operation "$op_id" "retry_count" "1"
            engine_output=$(run_engine "$prompt" "$op_id" "codex") || {
                update_operation "$op_id" "status" "failed"
                update_operation "$op_id" "error" "Both engines failed"
                send_response "Both engines failed. Try a simpler instruction." "$message_id"
                return 1
            }
        else
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Engine failed"
            send_response "Engine failed. Try a simpler instruction or switch engine." "$message_id"
            return 1
        fi
    }

    update_operation "$op_id" "engine_output" "${engine_output:0:2000}"
    update_operation "$op_id" "engine_elapsed_secs" "$LAST_ENGINE_ELAPSED"
    update_operation "$op_id" "engine_model" "$LAST_ENGINE_MODEL"
    update_operation "$op_id" "status" "validating"

    # Validate scope
    if ! validate_scope; then
        log "Scope violation detected -- reverted unauthorized changes"
    fi

    # Check if any changes remain (tracked modifications + new untracked files)
    local changed_files
    local _mod _untracked
    _mod=$(cd "$AVA_WORKTREE" && git diff --name-only dev 2>/dev/null)
    _untracked=$(cd "$AVA_WORKTREE" && git ls-files --others --exclude-standard 2>/dev/null)
    changed_files=$(printf '%s\n%s' "$_mod" "$_untracked" | sort -u | sed '/^$/d')

    if [[ -z "$changed_files" ]]; then
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "No changes made"
        send_response "No changes were made. Try being more specific." "$message_id"
        return 0
    fi

    update_operation "$op_id" "files_changed" "$changed_files"

    # Validate build
    local build_result
    build_result=$(validate_build) || {
        log "Build failed, retrying with error context..."
        update_operation "$op_id" "retry_count" "1"
        update_operation "$op_id" "heal_attempted" "1"

        local retry_prompt="${prompt}

BUILD FAILED. Here is the error:
${build_result}

Fix the build error while still accomplishing the original instruction."

        (cd "$AVA_WORKTREE" && git checkout -- . 2>/dev/null)
        engine_output=$(run_engine "$retry_prompt" "$op_id" "$engine") || {
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Build failed after retry"
            update_operation "$op_id" "build_output" "${build_result:0:2000}"
            send_response "Build failed after retry. Here's the error:

${build_result:0:500}" "$message_id"
            return 1
        }

        build_result=$(validate_build) || {
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Build failed after retry"
            update_operation "$op_id" "build_output" "${build_result:0:2000}"
            send_response "Build failed after retry. Here's the error:

${build_result:0:500}" "$message_id"
            return 1
        }
    }

    update_operation "$op_id" "build_output" "PASSED"

    # Stage only allowed files (NOT git add -A)
    stage_allowed_files

    # Commit changes
    local commit_msg="Ava: ${instruction:0:60}

Instruction: ${instruction}
Engine: ${engine}
Operation: ${op_id}

Co-Authored-By: Ava <ava@parallax.space>"

    (cd "$AVA_WORKTREE" && git commit -m "$commit_msg") || {
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "Commit failed"
        send_response "Failed to commit changes." "$message_id"
        return 1
    }

    # Push branch (three-tier cascade)
    if ! push_branch "$branch" "$op_id"; then
        local push_method
        push_method=$(sqlite3 "$HYDRA_DB" "SELECT push_method FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
        if [[ "$push_method" == "patch" ]]; then
            send_response "Push failed (SSH + HTTPS). Saved as .patch file. Eddie needs to push manually." "$message_id"
            update_operation "$op_id" "status" "failed"
            update_operation "$op_id" "error" "Push failed, patch saved"
            return 1
        fi
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "Push failed"
        send_response "Failed to push branch." "$message_id"
        return 1
    fi

    # Create PR
    local pr_url
    pr_url=$(create_pr "$branch" "$instruction" "$changed_files" "${engine_output:0:500}") || {
        update_operation "$op_id" "status" "failed"
        update_operation "$op_id" "error" "PR creation failed"
        send_response "Changes committed and pushed but PR creation failed. Check GitHub." "$message_id"
        return 1
    }

    # Extract PR number
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

    # Compute diff stats for approval message
    local diff_stat lines_added lines_removed diff_total diff_warning=""
    diff_stat=$(cd "$AVA_WORKTREE" && git diff --stat dev 2>/dev/null | tail -1)
    lines_added=$(cd "$AVA_WORKTREE" && git diff --numstat dev 2>/dev/null | awk '{s+=$1} END {print s+0}')
    lines_removed=$(cd "$AVA_WORKTREE" && git diff --numstat dev 2>/dev/null | awk '{s+=$1} END {print s+0}')
    # Recalculate: numstat col 1 = added, col 2 = removed
    lines_added=$(cd "$AVA_WORKTREE" && git diff --numstat dev 2>/dev/null | awk '{s+=$1} END {print s+0}')
    lines_removed=$(cd "$AVA_WORKTREE" && git diff --numstat dev 2>/dev/null | awk '{s+=$2} END {print s+0}')
    diff_total=$((lines_added + lines_removed))

    if [[ $diff_total -gt 200 ]]; then
        diff_warning="
WARNING: Large diff (${diff_total} lines). Review carefully."
    fi

    update_operation "$op_id" "diagnostic_data" "diff: +${lines_added}/-${lines_removed} (${diff_total} total)"

    # Send approval request
    local push_method_display
    push_method_display=$(sqlite3 "$HYDRA_DB" "SELECT push_method FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    local approval_msg="Done! Here's what I changed:

PR: Ava: ${instruction:0:60}
${pr_url}

Files changed:
$(echo "$changed_files" | sed 's/^/  /')

Diff: +${lines_added} / -${lines_removed} (${diff_total} lines)
Push: ${push_method_display:-unknown}${diff_warning}

Reply:
  approve - merge to dev
  approve and deploy - merge to dev + ship to production
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

    # Store total elapsed time
    local total_elapsed=$(( $(date +%s) - op_start_time ))
    update_operation "$op_id" "total_elapsed_secs" "$total_elapsed"
    log "Total operation time: ${total_elapsed}s (engine: ${LAST_ENGINE_ELAPSED}s)"

    log "=== Instruction complete: PR created ($pr_url) ==="

    # Cleanup is handled by trap — worktree returns to clean dev state
}

# ============================================================================
# SUBCOMMAND: approval
# ============================================================================

handle_approval() {
    local reply="$1"
    local thread_id="$2"

    log "=== Approval handler ==="
    log "Reply: $reply, Thread: $thread_id"

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

    local reply_lower
    reply_lower=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')

    # Detect "approve and deploy" — merge to dev then auto-promote to main
    local auto_deploy=false
    if [[ "$reply_lower" =~ approve.*deploy ]] || [[ "$reply_lower" =~ approve.*prod ]] || \
       [[ "$reply_lower" =~ approve.*ship ]] || [[ "$reply_lower" =~ approve.*release ]] || \
       [[ "$reply_lower" =~ approve.*main ]] || [[ "$reply_lower" =~ approve.*live ]]; then
        auto_deploy=true
    fi

    if [[ "$reply_lower" == "approve"* ]] || [[ "$reply_lower" == "yes"* ]] || [[ "$reply_lower" == "lgtm"* ]] || [[ "$reply_lower" == "ship"* ]] || [[ "$reply_lower" == "merge"* ]]; then
        handle_merge "$op_id" "$pr_url" "$thread_id"
        if [[ "$auto_deploy" == "true" ]]; then
            log "Auto-deploy triggered by 'approve and deploy'"
            promote_to_main "auto" "$op_id"
        fi
    elif [[ "$reply_lower" == "reject"* ]] || [[ "$reply_lower" == "no"* ]] || [[ "$reply_lower" == "close"* ]]; then
        handle_reject "$op_id" "$pr_url" "$thread_id"
    elif [[ "$reply_lower" == "revise"* ]]; then
        local feedback
        feedback=$(echo "$reply" | sed -E 's/^revise:?\s*//i')
        handle_revision "$op_id" "$pr_url" "$thread_id" "$feedback"
    else
        send_response "I didn't understand. Reply with:
  approve - merge to dev
  approve and deploy - merge to dev + ship to production
  reject - close the PR
  revise: [feedback] - I'll adjust"
    fi
}

handle_merge() {
    local op_id="$1"
    local pr_url="$2"
    local thread_id="$3"

    log "Merging PR: $pr_url"

    # gh pr merge works from any directory — just needs the URL
    gh pr merge "$pr_url" --merge || {
        log_error "Merge failed"
        send_response "Merge failed. Check GitHub for details."
        return 1
    }

    update_operation "$op_id" "status" "merged"

    sqlite3 "$HYDRA_DB" "
        UPDATE conversation_threads SET state = 'completed' WHERE id = '${thread_id}';
    " 2>/dev/null

    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    if [[ -n "$branch" ]]; then
        (cd "$PARALLAX_DIR" && git push origin --delete "$branch" 2>/dev/null) || true
    fi

    send_response "Merged to dev! Say 'deploy' to push to production, or I'll keep stacking changes."

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

    gh pr close "$pr_url" || true

    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    if [[ -n "$branch" ]]; then
        (cd "$PARALLAX_DIR" && git push origin --delete "$branch" 2>/dev/null) || true
        (cd "$AVA_WORKTREE" && git branch -D "$branch" 2>/dev/null) || true
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

    local instruction
    instruction=$(sqlite3 "$HYDRA_DB" "SELECT instruction FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    local branch
    branch=$(sqlite3 "$HYDRA_DB" "SELECT branch FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)
    local engine
    engine=$(sqlite3 "$HYDRA_DB" "SELECT engine FROM ava_operations WHERE id = '${op_id}';" 2>/dev/null)

    send_response "Revising based on your feedback..."

    # Checkout the branch in worktree
    (cd "$AVA_WORKTREE" && git fetch origin "$branch" 2>/dev/null && git checkout "$branch" 2>/dev/null) || {
        send_response "Couldn't checkout the branch. Try a new instruction instead."
        return 1
    }

    local prompt
    prompt=$(build_prompt "$instruction")
    prompt="${prompt}

## Revision Feedback from Eddie
Eddie reviewed the changes and said: \"${feedback}\"

Please adjust the code to address this feedback while keeping the original instruction in mind."

    local engine_output
    engine_output=$(run_engine "$prompt" "$op_id" "$engine") || {
        send_response "Engine failed during revision. Try a new instruction."
        (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null) || true
        return 1
    }

    validate_scope || true
    load_build_env || true
    local build_result
    build_result=$(validate_build) || {
        send_response "Build failed after revision:

${build_result:0:500}"
        (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null && git reset --hard origin/dev 2>/dev/null) || true
        return 1
    }

    local revise_msg="Ava: revise - ${feedback:0:60}

Original: ${instruction}
Feedback: ${feedback}
Engine: ${engine}
Operation: ${op_id}

Co-Authored-By: Ava <ava@parallax.space>"

    # Stage allowed files only, then commit and push
    stage_allowed_files
    (cd "$AVA_WORKTREE" && git commit -m "$revise_msg") || {
        send_response "Failed to commit revision."
        (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null) || true
        return 1
    }

    if ! push_branch "$branch" "$op_id"; then
        send_response "Failed to push revision."
        (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null) || true
        return 1
    fi

    update_operation "$op_id" "engine_output" "${engine_output:0:2000}"

    local changed_files
    changed_files=$(cd "$AVA_WORKTREE" && git diff --name-only dev..."$branch" 2>/dev/null)

    send_response "Revised! Updated PR:
${pr_url}

Files changed:
$(echo "$changed_files" | sed 's/^/  /')

Reply:
  approve - merge to dev
  approve and deploy - merge to dev + ship to production
  reject - close the PR
  revise: [more feedback]"

    (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null && git reset --hard origin/dev 2>/dev/null) || true
    log "Revision pushed"
}

# ============================================================================
# PROMOTE TO MAIN (dev → main release pipeline)
# ============================================================================

promote_to_main() {
    local trigger="${1:-manual}"  # "auto" from approve-and-deploy, "manual" from deploy command
    local op_id="${2:-}"          # optional: link to the operation that triggered this

    log "=== Promote to main (trigger: $trigger) ==="

    # Preflight on dev before touching main
    log "Running preflight before promotion..."
    if [[ -x "$AVA_PREFLIGHT" ]]; then
        local preflight_out
        preflight_out=$("$AVA_PREFLIGHT" check 2>&1) || {
            log_error "Preflight failed before promotion"
            send_response "Promotion to main blocked — preflight failed:

${preflight_out}"
            return 1
        }
    fi

    # Check if dev is ahead of main
    local ahead_count
    ahead_count=$(gh api repos/eddiebelaval/parallax/compare/main...dev --jq '.ahead_by' 2>/dev/null || echo "0")

    if [[ "$ahead_count" == "0" ]]; then
        log "dev is not ahead of main — nothing to promote"
        send_response "Nothing to deploy — dev and main are in sync."
        return 0
    fi

    log "dev is $ahead_count commits ahead of main"

    # Build verification in worktree (already on dev)
    log "Running build verification..."
    load_build_env || true
    local build_ok=true

    # Full build
    (cd "$AVA_WORKTREE" && set -a && source "$AVA_BUILD_ENV" 2>/dev/null && set +a && npm run build >/dev/null 2>&1) || {
        log_error "Build failed in worktree"
        build_ok=false
    }

    # TypeScript check (strict — no error filtering, all tests now pass)
    if [[ "$build_ok" == "true" ]]; then
        local tsc_output tsc_exit
        tsc_output=$(cd "$AVA_WORKTREE" && npx tsc --noEmit 2>&1) || tsc_exit=$?
        if [[ "${tsc_exit:-0}" -ne 0 ]]; then
            log_error "TypeScript errors — blocking promotion"
            send_response "Promotion blocked — TypeScript errors:

$(echo "$tsc_output" | grep "error TS" | head -20)"
            return 1
        fi
    fi

    if [[ "$build_ok" != "true" ]]; then
        send_response "Promotion blocked — build failed on dev. Fix before deploying."
        return 1
    fi

    log "Build verification passed"

    # Create the release PR
    local pr_title="Release: dev → main"
    local commit_log
    commit_log=$(gh api repos/eddiebelaval/parallax/compare/main...dev --jq '.commits[] | "- " + (.commit.message | split("\n")[0])' 2>/dev/null | head -20)

    local pr_body="## Release to Production

**Trigger:** ${trigger}
**Commits:** ${ahead_count}

### Changes
${commit_log}

---
Promoted by Ava's deployment pipeline."

    local pr_url
    pr_url=$(gh pr create --repo eddiebelaval/parallax --base main --head dev \
        --title "$pr_title" --body "$pr_body" 2>&1) || {
        # If PR already exists, find it
        pr_url=$(gh pr list --repo eddiebelaval/parallax --base main --head dev --json url --jq '.[0].url' 2>/dev/null)
        if [[ -z "$pr_url" ]]; then
            log_error "Failed to create release PR"
            send_response "Failed to create release PR. Check GitHub."
            return 1
        fi
        log "Using existing release PR: $pr_url"
    }

    log "Release PR: $pr_url"

    # Wait for CI checks before merging (poll every 15s, timeout 5min)
    local check_timeout=300
    local check_interval=15
    local check_elapsed=0

    log "Waiting for CI checks on release PR..."
    while [[ $check_elapsed -lt $check_timeout ]]; do
        local checks_status
        checks_status=$(gh pr checks "$pr_url" 2>&1) || true

        # No checks configured = proceed immediately
        if echo "$checks_status" | grep -qi "no checks"; then
            log "No CI checks configured — proceeding"
            break
        fi

        # All passed
        if ! echo "$checks_status" | grep -qiE "pending|queued|in_progress"; then
            if echo "$checks_status" | grep -qi "fail"; then
                log_error "CI checks failed on release PR"
                send_response "Release PR created but CI checks failed:
$pr_url

Fix the failing checks, then run 'deploy' again."
                return 1
            fi
            log "All CI checks passed"
            break
        fi

        sleep "$check_interval"
        check_elapsed=$((check_elapsed + check_interval))
    done

    if [[ $check_elapsed -ge $check_timeout ]]; then
        log "CI check timeout — proceeding with merge (checks may still be running)"
        send_response "CI checks still running after ${check_timeout}s — merging anyway. Monitor at:
$pr_url"
    fi

    # Merge the release PR
    gh pr merge "$pr_url" --merge || {
        log_error "Release merge failed"
        send_response "Release PR created but merge failed:
$pr_url

Merge manually on GitHub."
        return 1
    }

    log "Release merged to main — deploying to production"

    # Log activity
    local act_id
    act_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
        VALUES ('${act_id}', 'ava', 'release', 'deployment', '${op_id:-manual}', 'Ava promoted dev to main (trigger: ${trigger}, commits: ${ahead_count})');
    " 2>/dev/null

    send_response "Deployed to production! ${ahead_count} commits released.
Vercel deploying now (~60s). Live at tryparallax.space

Changes:
${commit_log:0:500}"

    log "=== Promotion complete ==="
    return 0
}

# ============================================================================
# SUBCOMMAND: rollback (revert last deploy on main)
# ============================================================================

rollback_main() {
    log "=== Rollback: reverting last merge on main ==="

    # Find the last merge commit on main
    local last_merge
    last_merge=$(gh api repos/eddiebelaval/parallax/commits?sha=main\&per_page=10 \
        --jq '[.[] | select(.parents | length > 1)][0].sha' 2>/dev/null)

    if [[ -z "$last_merge" ]]; then
        log_error "No merge commit found on main to revert"
        send_response "Rollback failed — no merge commit found on main."
        return 1
    fi

    local merge_msg
    merge_msg=$(gh api "repos/eddiebelaval/parallax/commits/${last_merge}" \
        --jq '.commit.message | split("\n")[0]' 2>/dev/null)
    log "Last merge on main: ${last_merge:0:8} — $merge_msg"

    # Confirm with Eddie (unless triggered with --force)
    if [[ "${1:-}" != "--force" ]]; then
        send_response "Rolling back last deploy on main:

Reverting: ${last_merge:0:8}
Commit: ${merge_msg}

This will create a revert commit on main and Vercel will auto-deploy the reverted state. Reply 'confirm rollback' to proceed."
        # Store rollback intent for approval handler
        sqlite3 "$HYDRA_DB" "
            INSERT OR REPLACE INTO ava_operations (id, instruction, engine, status, created_at)
            VALUES ('rollback-${last_merge:0:8}', 'Rollback: revert ${last_merge:0:8}', 'git', 'pending_rollback', datetime('now'));
        " 2>/dev/null
        return 0
    fi

    # Execute rollback in worktree
    log "Executing rollback in worktree..."

    # Ensure worktree is on main
    (cd "$AVA_WORKTREE" && git fetch origin main >/dev/null 2>&1 && \
        git checkout main >/dev/null 2>&1 && \
        git reset --hard origin/main >/dev/null 2>&1) || {
        log_error "Failed to prepare worktree for rollback"
        send_response "Rollback failed — could not prepare worktree."
        return 1
    }

    # Revert the merge commit (parent 1 = mainline)
    (cd "$AVA_WORKTREE" && git revert -m 1 --no-edit "$last_merge") || {
        log_error "git revert failed"
        (cd "$AVA_WORKTREE" && git revert --abort 2>/dev/null) || true
        send_response "Rollback failed — git revert failed. May need manual intervention."
        # Return worktree to dev
        (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git reset --hard origin/dev >/dev/null 2>&1) || true
        return 1
    }

    # Push the revert
    (cd "$AVA_WORKTREE" && GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes" \
        git push origin main 2>/dev/null) || {
        log_error "Failed to push revert to main"
        send_response "Rollback revert created but push failed. Push manually."
        # Return worktree to dev
        (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git reset --hard origin/dev >/dev/null 2>&1) || true
        return 1
    }

    # Return worktree to dev
    (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git reset --hard origin/dev >/dev/null 2>&1) || true

    # Log activity
    local act_id
    act_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "act-$(date +%s)")
    sqlite3 "$HYDRA_DB" "
        INSERT INTO activities (id, agent_id, activity_type, entity_type, entity_id, description)
        VALUES ('${act_id}', 'ava', 'rollback', 'deployment', '${last_merge:0:8}', 'Ava rolled back main: reverted ${last_merge:0:8} — ${merge_msg}');
    " 2>/dev/null

    # Update rollback operation status
    sqlite3 "$HYDRA_DB" "
        UPDATE ava_operations SET status = 'completed'
        WHERE id = 'rollback-${last_merge:0:8}';
    " 2>/dev/null

    send_response "Rolled back production!

Reverted: ${last_merge:0:8} — ${merge_msg}

Vercel will auto-deploy the reverted state (~60s)."

    log "=== Rollback complete ==="
    return 0
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
    echo "Worktree: $AVA_WORKTREE"
    echo "Build Env: $AVA_BUILD_ENV"
    echo "Preflight: $AVA_PREFLIGHT"
    echo ""

    # Check worktree soul files
    echo "=== SOUL FILES ==="
    if [[ -d "$AVA_SOUL_DIR/kernel" ]]; then
        echo "  Soul dir: $AVA_SOUL_DIR (exists)"
        ls "$AVA_SOUL_DIR/kernel/" 2>/dev/null | sed 's/^/    /'
    else
        echo "  Soul dir: $AVA_SOUL_DIR (MISSING)"
    fi
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
        if [[ "${TELEGRAM_RESPOND:-}" == "true" ]]; then
            send_response "$result"
        fi
        ;;
    deploy|release)
        promote_to_main "manual"
        ;;
    rollback)
        rollback_main "${1:-}"
        ;;
    dry-run)
        handle_dry_run "${1:-test instruction}"
        ;;
    help|*)
        echo "ava-autonomy.sh - Ava's autonomous code modification handler (v2)"
        echo ""
        echo "Usage:"
        echo "  ava-autonomy.sh instruction <message> <message_id>"
        echo "  ava-autonomy.sh approval <reply> <thread_id>"
        echo "  ava-autonomy.sh deploy          (promote dev -> main)"
        echo "  ava-autonomy.sh rollback         (revert last deploy)"
        echo "  ava-autonomy.sh rollback --force (execute without confirm)"
        echo "  ava-autonomy.sh status"
        echo "  ava-autonomy.sh dry-run <instruction>"
        echo ""
        echo "Approval commands (via Telegram):"
        echo "  approve              Merge PR to dev only"
        echo "  approve and deploy   Merge to dev + auto-promote to main"
        echo "  deploy / release     Ship everything on dev to main"
        echo "  rollback             Revert last deploy (two-phase confirm)"
        echo ""
        echo "Environment:"
        echo "  AVA_ENGINE=claude|codex  (default: claude)"
        echo "  TELEGRAM_RESPOND=true    (send status via Telegram)"
        echo ""
        echo "v2 features: worktree isolation, preflight checks, push cascade,"
        echo "  concurrency lock, allowlist staging, trap-based cleanup,"
        echo "  three-mode deployment (approve / approve+deploy / release)"
        ;;
esac
