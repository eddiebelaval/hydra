#!/bin/bash
# ava-preflight.sh — Ava's self-diagnostic and healing script
#
# Subcommands:
#   check                 — Run all checks, return pass/warn/fail per category
#   diagnose <category>   — Deep-dive one area
#   heal <category>       — Attempt auto-fix
#
# Categories: env, git, ssh, disk, tools, network, worktree
#
# Exit codes:
#   0 = all pass (or heal succeeded)
#   1 = at least one fail (or heal failed)
#   2 = usage error

set -uo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
AVA_BUILD_ENV="$HYDRA_ROOT/config/ava-build.env"
AVA_WORKTREE="$HOME/Development/.worktrees/parallax/ava-workspace"
PARALLAX_DIR="$HOME/Development/id8/products/parallax"
LOCKFILE_SHA_FILE="$HYDRA_ROOT/state/ava-lockfile-sha.txt"
SSH_KEY="$HOME/.ssh/id_ed25519"

LOG_DIR="$HOME/Library/Logs/claude-automation/ava-autonomy"
LOG_FILE="$LOG_DIR/preflight-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

# Required env var names (just the names — values come from ava-build.env)
REQUIRED_VARS=(
    NEXT_PUBLIC_SUPABASE_URL
    NEXT_PUBLIC_SUPABASE_ANON_KEY
    SUPABASE_SERVICE_ROLE_KEY
    ANTHROPIC_API_KEY
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    STRIPE_PRICE_PRO_MONTHLY
    STRIPE_PRICE_PREMIUM_MONTHLY
    ELEVENLABS_API_KEY
    ELEVENLABS_VOICE_ID
    UPSTASH_REDIS_REST_URL
    UPSTASH_REDIS_REST_TOKEN
    NEXT_PUBLIC_APP_URL
)

REQUIRED_TOOLS=(claude codex gh node npm git ssh python3)

# Result tracking
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [preflight] $1" >> "$LOG_FILE"
}

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

result_pass() {
    echo "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $1"
}

result_warn() {
    echo "  [WARN] $1"
    WARN_COUNT=$((WARN_COUNT + 1))
    log "WARN: $1"
}

result_fail() {
    echo "  [FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $1"
}

log_preflight_db() {
    local check_type="$1"
    local status="$2"
    local detail="${3:-}"
    local heal_attempted="${4:-0}"
    local heal_result="${5:-}"
    local operation_id="${6:-}"

    sqlite3 "$HYDRA_DB" "
        INSERT INTO ava_preflight_log (check_type, status, detail, heal_attempted, heal_result, operation_id)
        VALUES ('$(echo "$check_type" | sed "s/'/''/g")', '$status', '$(echo "$detail" | sed "s/'/''/g")', $heal_attempted, '$(echo "$heal_result" | sed "s/'/''/g")', '$(echo "$operation_id" | sed "s/'/''/g")');
    " 2>/dev/null
}

# ============================================================================
# CHECK: env
# ============================================================================

check_env() {
    echo "--- env ---"

    if [[ ! -f "$AVA_BUILD_ENV" ]]; then
        result_fail "ava-build.env not found at $AVA_BUILD_ENV"
        log_preflight_db "env" "fail" "ava-build.env missing"
        return 1
    fi

    result_pass "ava-build.env exists"

    local missing=""
    local found=0
    for var in "${REQUIRED_VARS[@]}"; do
        if grep -q "^${var}=" "$AVA_BUILD_ENV" 2>/dev/null; then
            found=$((found + 1))
        else
            missing="${missing} ${var}"
        fi
    done

    if [[ -n "$missing" ]]; then
        result_fail "Missing vars:${missing}"
        log_preflight_db "env" "fail" "Missing:${missing}"
        return 1
    fi

    result_pass "All ${found} required vars present"
    log_preflight_db "env" "pass" "${found} vars OK"
    return 0
}

diagnose_env() {
    echo "--- env (detailed) ---"
    echo "  Build env file: $AVA_BUILD_ENV"
    echo "  Fallback .env.local: $PARALLAX_DIR/.env.local"
    echo ""
    echo "  Variable status:"
    for var in "${REQUIRED_VARS[@]}"; do
        if grep -q "^${var}=" "$AVA_BUILD_ENV" 2>/dev/null; then
            local val
            val=$(grep "^${var}=" "$AVA_BUILD_ENV" | cut -d'=' -f2 | cut -c1-20)
            echo "    [OK] $var = ${val}..."
        else
            echo "    [MISSING] $var"
        fi
    done
}

heal_env() {
    echo "--- env (heal) ---"
    # Cannot auto-generate secrets — report what's missing
    if [[ ! -f "$AVA_BUILD_ENV" ]]; then
        echo "  Cannot heal: ava-build.env does not exist."
        echo "  Create it manually: cp $PARALLAX_DIR/.env.local $AVA_BUILD_ENV"
        return 1
    fi

    local healed=0
    for var in "${REQUIRED_VARS[@]}"; do
        if ! grep -q "^${var}=" "$AVA_BUILD_ENV" 2>/dev/null; then
            # Try to copy from .env.local
            if [[ -f "$PARALLAX_DIR/.env.local" ]]; then
                local val
                val=$(grep "^${var}=" "$PARALLAX_DIR/.env.local" 2>/dev/null)
                if [[ -n "$val" ]]; then
                    echo "$val" >> "$AVA_BUILD_ENV"
                    echo "  Copied $var from .env.local"
                    healed=$((healed + 1))
                else
                    echo "  Cannot find $var in .env.local either"
                fi
            fi
        fi
    done

    if [[ $healed -gt 0 ]]; then
        echo "  Healed $healed vars"
        log_preflight_db "env" "healed" "$healed vars copied" 1 "success"
        return 0
    fi
    return 1
}

# ============================================================================
# CHECK: git
# ============================================================================

check_git() {
    echo "--- git ---"

    # Check main repo exists
    if [[ ! -d "$PARALLAX_DIR/.git" ]]; then
        result_fail "Parallax repo not found at $PARALLAX_DIR"
        return 1
    fi
    result_pass "Parallax repo exists"

    # Check remote is reachable (quick)
    if (cd "$PARALLAX_DIR" && git ls-remote --exit-code origin HEAD &>/dev/null); then
        result_pass "Remote origin reachable"
    else
        result_warn "Remote origin unreachable (may be offline)"
    fi

    log_preflight_db "git" "pass" "repo OK"
    return 0
}

heal_git() {
    echo "--- git (heal) ---"
    echo "  Git repo issues require manual intervention."
    echo "  Repo path: $PARALLAX_DIR"
    return 1
}

# ============================================================================
# CHECK: ssh
# ============================================================================

check_ssh() {
    echo "--- ssh ---"

    if [[ ! -f "$SSH_KEY" ]]; then
        result_fail "SSH key not found: $SSH_KEY"
        log_preflight_db "ssh" "fail" "key missing"
        return 1
    fi
    result_pass "SSH key exists"

    # Test GitHub SSH with explicit key
    local ssh_result
    ssh_result=$(GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes" ssh -T git@github.com 2>&1 || true)

    if echo "$ssh_result" | grep -qi "successfully authenticated"; then
        result_pass "GitHub SSH auth works"
        log_preflight_db "ssh" "pass" "authenticated"
        return 0
    else
        result_fail "SSH auth failed: ${ssh_result:0:100}"
        log_preflight_db "ssh" "fail" "${ssh_result:0:200}"
        return 1
    fi
}

heal_ssh() {
    echo "--- ssh (heal) ---"
    echo "  Trying GIT_SSH_COMMAND with explicit key path..."
    local result
    result=$(GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" ssh -T git@github.com 2>&1 || true)

    if echo "$result" | grep -qi "successfully authenticated"; then
        echo "  SSH works with explicit key. GIT_SSH_COMMAND is set in launchd plist."
        log_preflight_db "ssh" "healed" "explicit key works" 1 "success"
        return 0
    else
        echo "  SSH still failing: ${result:0:100}"
        echo "  Check: ssh-keygen -l -f $SSH_KEY"
        log_preflight_db "ssh" "fail" "heal failed" 1 "failed"
        return 1
    fi
}

# ============================================================================
# CHECK: disk
# ============================================================================

check_disk() {
    echo "--- disk ---"

    local avail_kb
    avail_kb=$(df -k "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
    local avail_mb=$((avail_kb / 1024))
    local avail_gb=$((avail_mb / 1024))

    if [[ $avail_mb -gt 1024 ]]; then
        result_pass "Disk space: ${avail_gb}GB free"
        log_preflight_db "disk" "pass" "${avail_gb}GB free"
        return 0
    elif [[ $avail_mb -gt 512 ]]; then
        result_warn "Disk space low: ${avail_mb}MB free"
        log_preflight_db "disk" "warn" "${avail_mb}MB free"
        return 0
    else
        result_fail "Disk space critical: ${avail_mb}MB free"
        log_preflight_db "disk" "fail" "${avail_mb}MB free"
        return 1
    fi
}

heal_disk() {
    echo "--- disk (heal) ---"

    # Clean up known large temp dirs
    local cleaned=0

    # Claude debug logs
    if [[ -d "$HOME/.claude/debug" ]]; then
        local debug_size
        debug_size=$(du -sm "$HOME/.claude/debug" 2>/dev/null | cut -f1)
        if [[ "$debug_size" -gt 100 ]]; then
            find "$HOME/.claude/debug" -mtime +1 -delete 2>/dev/null
            echo "  Cleaned claude debug logs (was ${debug_size}MB)"
            cleaned=1
        fi
    fi

    # Old Ava engine output files
    find /tmp -name "ava-engine-*" -mtime +1 -delete 2>/dev/null
    find /tmp -name "ava-voice-*" -mtime +1 -delete 2>/dev/null

    if [[ $cleaned -gt 0 ]]; then
        log_preflight_db "disk" "healed" "cleaned temp files" 1 "success"
    fi
    echo "  Temp cleanup done."
    return 0
}

# ============================================================================
# CHECK: tools
# ============================================================================

check_tools() {
    echo "--- tools ---"

    local missing=""
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if command -v "$tool" &>/dev/null; then
            : # present
        elif [[ -f "$HOME/.local/bin/$tool" ]]; then
            : # in local bin
        elif [[ -f "$HOME/.nvm/versions/node/v22.21.1/bin/$tool" ]]; then
            : # in nvm
        else
            missing="${missing} ${tool}"
        fi
    done

    if [[ -n "$missing" ]]; then
        result_fail "Missing tools:${missing}"
        log_preflight_db "tools" "fail" "Missing:${missing}"
        return 1
    fi

    result_pass "All required tools present"
    log_preflight_db "tools" "pass" "all tools found"
    return 0
}

heal_tools() {
    echo "--- tools (heal) ---"
    echo "  Cannot auto-install tools. Missing tools must be installed manually."
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null && \
           [[ ! -f "$HOME/.local/bin/$tool" ]] && \
           [[ ! -f "$HOME/.nvm/versions/node/v22.21.1/bin/$tool" ]]; then
            echo "    MISSING: $tool"
        fi
    done
    return 1
}

# ============================================================================
# CHECK: network
# ============================================================================

check_network() {
    echo "--- network ---"

    # GitHub
    if curl -s --max-time 5 -o /dev/null -w "%{http_code}" "https://github.com" 2>/dev/null | grep -q "200\|301\|302"; then
        result_pass "github.com reachable"
    else
        result_fail "github.com unreachable"
        log_preflight_db "network" "fail" "github.com unreachable"
        return 1
    fi

    # Supabase (just check DNS resolution)
    if curl -s --max-time 5 -o /dev/null "https://kzozdtgunuigcdmqqojw.supabase.co" 2>/dev/null; then
        result_pass "Supabase reachable"
    else
        result_warn "Supabase unreachable (non-critical for code changes)"
    fi

    log_preflight_db "network" "pass" "connectivity OK"
    return 0
}

# ============================================================================
# CHECK: worktree
# ============================================================================

check_worktree() {
    echo "--- worktree ---"

    if [[ ! -d "$AVA_WORKTREE" ]]; then
        result_fail "Worktree missing: $AVA_WORKTREE"
        log_preflight_db "worktree" "fail" "missing"
        return 1
    fi
    result_pass "Worktree exists"

    if [[ ! -d "$AVA_WORKTREE/.git" ]] && [[ ! -f "$AVA_WORKTREE/.git" ]]; then
        result_fail "Worktree not a git checkout"
        log_preflight_db "worktree" "fail" "not git"
        return 1
    fi

    # Check if clean
    local dirty
    dirty=$(cd "$AVA_WORKTREE" && git status --porcelain 2>/dev/null)
    if [[ -n "$dirty" ]]; then
        result_warn "Worktree has uncommitted changes"
        log_preflight_db "worktree" "warn" "dirty"
    else
        result_pass "Worktree is clean"
    fi

    # Check node_modules exist
    if [[ -d "$AVA_WORKTREE/node_modules" ]]; then
        result_pass "node_modules present"
    else
        result_warn "node_modules missing (npm ci needed)"
    fi

    log_preflight_db "worktree" "pass" "exists and checked"
    return 0
}

heal_worktree() {
    echo "--- worktree (heal) ---"

    if [[ ! -d "$AVA_WORKTREE" ]]; then
        echo "  Recreating worktree..."
        (cd "$PARALLAX_DIR" && git worktree add "$AVA_WORKTREE" dev 2>&1) || {
            echo "  Failed to create worktree"
            log_preflight_db "worktree" "fail" "create failed" 1 "failed"
            return 1
        }
        echo "  Worktree created. Running npm ci..."
        (cd "$AVA_WORKTREE" && npm ci 2>&1 | tail -3) || {
            echo "  npm ci failed"
            return 1
        }
        log_preflight_db "worktree" "healed" "recreated" 1 "success"
        return 0
    fi

    # Reset if dirty
    local dirty
    dirty=$(cd "$AVA_WORKTREE" && git status --porcelain 2>/dev/null)
    if [[ -n "$dirty" ]]; then
        echo "  Resetting dirty worktree..."
        (cd "$AVA_WORKTREE" && git checkout dev 2>/dev/null && git reset --hard origin/dev 2>/dev/null && git clean -fd 2>/dev/null)
        echo "  Worktree reset to origin/dev"
        log_preflight_db "worktree" "healed" "reset to clean" 1 "success"
    fi

    # Ensure node_modules
    if [[ ! -d "$AVA_WORKTREE/node_modules" ]]; then
        echo "  Installing dependencies..."
        (cd "$AVA_WORKTREE" && npm ci 2>&1 | tail -3)
    fi

    return 0
}

# ============================================================================
# MAIN DISPATCHER
# ============================================================================

run_all_checks() {
    echo "=== Ava Preflight Check ==="
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    check_env || true
    check_git || true
    check_ssh || true
    check_disk || true
    check_tools || true
    check_network || true
    check_worktree || true

    echo ""
    echo "=== Summary ==="
    echo "  Pass: $PASS_COUNT | Warn: $WARN_COUNT | Fail: $FAIL_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "  Status: FAIL"
        return 1
    elif [[ $WARN_COUNT -gt 0 ]]; then
        echo "  Status: WARN"
        return 0
    else
        echo "  Status: ALL PASS"
        return 0
    fi
}

SUBCOMMAND="${1:-check}"
CATEGORY="${2:-}"

case "$SUBCOMMAND" in
    check)
        run_all_checks
        ;;
    diagnose)
        if [[ -z "$CATEGORY" ]]; then
            echo "Usage: ava-preflight.sh diagnose <category>"
            echo "Categories: env, git, ssh, disk, tools, network, worktree"
            exit 2
        fi
        case "$CATEGORY" in
            env) diagnose_env ;;
            *) echo "Diagnose not implemented for: $CATEGORY (use 'check' for overview)" ;;
        esac
        ;;
    heal)
        if [[ -z "$CATEGORY" ]]; then
            echo "Healing all categories..."
            heal_env || true
            heal_git || true
            heal_ssh || true
            heal_disk || true
            heal_tools || true
            heal_worktree || true
        else
            case "$CATEGORY" in
                env) heal_env ;;
                git) heal_git ;;
                ssh) heal_ssh ;;
                disk) heal_disk ;;
                tools) heal_tools ;;
                worktree) heal_worktree ;;
                *) echo "Unknown category: $CATEGORY"; exit 2 ;;
            esac
        fi
        ;;
    *)
        echo "ava-preflight.sh — Ava's self-diagnostic tool"
        echo ""
        echo "Usage:"
        echo "  ava-preflight.sh check              — Run all checks"
        echo "  ava-preflight.sh diagnose <category> — Deep-dive one area"
        echo "  ava-preflight.sh heal [category]     — Attempt auto-fix (all or one)"
        echo ""
        echo "Categories: env, git, ssh, disk, tools, network, worktree"
        exit 2
        ;;
esac
