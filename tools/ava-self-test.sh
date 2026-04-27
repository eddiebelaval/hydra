#!/bin/bash
# ava-self-test.sh — Validate Ava's full pipeline without making changes
#
# Runs a dry-run through every subsystem:
#   1. Preflight checks
#   2. Worktree access + branch creation/cleanup
#   3. Engine connectivity (Claude + Codex)
#   4. Push authentication (SSH + HTTPS)
#   5. Database read/write
#   6. Telegram send
#
# Usage: ava-self-test.sh [--quiet]
# Exit code: 0 = all pass, 1 = failures detected

set -uo pipefail

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
AVA_WORKTREE="$HOME/Development/.worktrees/parallax/ava-workspace"
AVA_BUILD_ENV="$HYDRA_ROOT/config/ava-build.env"
AVA_PREFLIGHT="$HYDRA_ROOT/tools/ava-preflight.sh"
SSH_KEY="$HOME/.ssh/id_ed25519"
CLAUDE_CLI="$HOME/.local/bin/claude"
CODEX_CLI="$HOME/.nvm/versions/node/v22.21.1/bin/codex"

# Load Telegram config
AVA_TELEGRAM_ENV="$HYDRA_ROOT/config/ava-telegram.env"
if [[ -f "$AVA_TELEGRAM_ENV" ]]; then
    source "$AVA_TELEGRAM_ENV"
fi

QUIET="${1:-}"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

print_result() {
    local label="$1"
    local status="$2"
    local detail="${3:-}"

    case "$status" in
        PASS)
            PASS_COUNT=$((PASS_COUNT + 1))
            [[ "$QUIET" != "--quiet" ]] && echo "  [PASS] $label${detail:+ — $detail}"
            ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "  [FAIL] $label${detail:+ — $detail}"
            ;;
        WARN)
            WARN_COUNT=$((WARN_COUNT + 1))
            [[ "$QUIET" != "--quiet" ]] && echo "  [WARN] $label${detail:+ — $detail}"
            ;;
    esac
}

echo "Ava Pipeline Self-Test"
echo "======================"
echo ""

# --- 1. Preflight ---
echo "1. Preflight"
if [[ -x "$AVA_PREFLIGHT" ]]; then
    if "$AVA_PREFLIGHT" check >/dev/null 2>&1; then
        print_result "Preflight check" "PASS"
    else
        print_result "Preflight check" "FAIL" "Run 'ava-preflight.sh check' for details"
    fi
else
    print_result "Preflight script" "FAIL" "Not found at $AVA_PREFLIGHT"
fi

# --- 2. Worktree ---
echo ""
echo "2. Worktree"
if [[ -d "$AVA_WORKTREE/.git" ]] || [[ -f "$AVA_WORKTREE/.git" ]]; then
    print_result "Worktree exists" "PASS" "$AVA_WORKTREE"

    # Check if worktree is clean
    local_changes=$(cd "$AVA_WORKTREE" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$local_changes" == "0" ]]; then
        print_result "Worktree clean" "PASS"
    else
        print_result "Worktree clean" "WARN" "$local_changes uncommitted changes"
    fi

    # Test branch creation and cleanup
    test_branch="ava/self-test-$(date +%s)"
    if (cd "$AVA_WORKTREE" && git checkout -b "$test_branch" >/dev/null 2>&1); then
        (cd "$AVA_WORKTREE" && git checkout dev >/dev/null 2>&1 && git branch -D "$test_branch" >/dev/null 2>&1)
        print_result "Branch create/delete" "PASS"
    else
        print_result "Branch create/delete" "FAIL"
    fi
else
    print_result "Worktree exists" "FAIL" "Missing at $AVA_WORKTREE"
fi

# --- 3. Engine Connectivity ---
echo ""
echo "3. Engines"
if [[ -f "$CLAUDE_CLI" ]] && [[ -x "$CLAUDE_CLI" ]]; then
    print_result "Claude CLI" "PASS" "$CLAUDE_CLI"
else
    print_result "Claude CLI" "FAIL" "Not found or not executable"
fi

if [[ -f "$CODEX_CLI" ]] && [[ -x "$CODEX_CLI" ]]; then
    print_result "Codex CLI" "PASS" "$CODEX_CLI"
else
    print_result "Codex CLI" "WARN" "Not found (optional fallback)"
fi

# Check Anthropic API key
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    print_result "Anthropic API key" "PASS" "set (${#ANTHROPIC_API_KEY} chars)"
else
    # Try loading from config
    if [[ -f "$HYDRA_ROOT/config/telegram.env" ]]; then
        test_key=$(grep '^ANTHROPIC_API_KEY=' "$HYDRA_ROOT/config/telegram.env" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [[ -n "$test_key" ]]; then
            print_result "Anthropic API key" "PASS" "found in telegram.env"
        else
            print_result "Anthropic API key" "FAIL" "not found"
        fi
    else
        print_result "Anthropic API key" "FAIL" "not found"
    fi
fi

# --- 4. Push Authentication ---
echo ""
echo "4. Push Auth"

# SSH
if [[ -f "$SSH_KEY" ]]; then
    ssh_test=$(ssh -T -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no git@github.com 2>&1 || true)
    if echo "$ssh_test" | grep -qi "successfully authenticated"; then
        ssh_user=$(echo "$ssh_test" | sed -n 's/.*Hi \([^ !]*\).*/\1/p')
        print_result "SSH push" "PASS" "authenticated as $ssh_user"
    else
        print_result "SSH push" "WARN" "key exists but auth test inconclusive"
    fi
else
    print_result "SSH push" "FAIL" "No key at $SSH_KEY"
fi

# HTTPS (gh)
if command -v gh >/dev/null 2>&1; then
    gh_user=$(gh auth status 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)
    if [[ -n "$gh_user" ]]; then
        print_result "HTTPS push (gh)" "PASS" "logged in as $gh_user"
    else
        gh_status=$(gh auth status 2>&1 | head -1 || echo "unknown")
        print_result "HTTPS push (gh)" "WARN" "$gh_status"
    fi
else
    print_result "HTTPS push (gh)" "FAIL" "gh CLI not found"
fi

# --- 5. Database ---
echo ""
echo "5. Database"
if [[ -f "$HYDRA_DB" ]]; then
    # Test read
    op_count=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM ava_operations;" 2>/dev/null || echo "ERR")
    if [[ "$op_count" != "ERR" ]]; then
        print_result "DB read" "PASS" "$op_count operations"
    else
        print_result "DB read" "FAIL" "query error"
    fi

    # Test write (insert + delete)
    test_id="self-test-$(date +%s)"
    sqlite3 "$HYDRA_DB" "INSERT INTO ava_operations (id, instruction, engine, status) VALUES ('$test_id', 'self-test', 'test', 'test');" 2>/dev/null
    verify=$(sqlite3 "$HYDRA_DB" "SELECT COUNT(*) FROM ava_operations WHERE id = '$test_id';" 2>/dev/null || echo "0")
    sqlite3 "$HYDRA_DB" "DELETE FROM ava_operations WHERE id = '$test_id';" 2>/dev/null
    if [[ "$verify" == "1" ]]; then
        print_result "DB write" "PASS" "insert/delete cycle"
    else
        print_result "DB write" "FAIL" "could not write"
    fi

    # Check new columns exist
    has_elapsed=$(sqlite3 "$HYDRA_DB" "SELECT sql FROM sqlite_master WHERE name='ava_operations';" 2>/dev/null | grep -c "engine_elapsed_secs" || echo "0")
    if [[ "$has_elapsed" -gt 0 ]]; then
        print_result "Cost tracking columns" "PASS"
    else
        print_result "Cost tracking columns" "WARN" "migration not applied"
    fi
else
    print_result "Database" "FAIL" "Not found at $HYDRA_DB"
fi

# --- 6. Telegram ---
echo ""
echo "6. Telegram"
if [[ -n "${AVA_TELEGRAM_BOT_TOKEN:-}" ]] && [[ "${AVA_TELEGRAM_BOT_TOKEN}" != "PASTE_TOKEN_HERE" ]]; then
    # Test getMe (doesn't send a message)
    bot_name=$(curl -s "https://api.telegram.org/bot${AVA_TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('username',''))" 2>/dev/null || echo "")
    if [[ -n "$bot_name" ]]; then
        print_result "Telegram bot" "PASS" "@$bot_name"
    else
        print_result "Telegram bot" "FAIL" "getMe failed"
    fi
else
    print_result "Telegram bot" "FAIL" "token not configured"
fi

if [[ -n "${AVA_TELEGRAM_CHAT_ID:-}" ]] && [[ "${AVA_TELEGRAM_CHAT_ID}" != "PASTE_CHAT_ID_HERE" ]]; then
    print_result "Telegram chat ID" "PASS" "$AVA_TELEGRAM_CHAT_ID"
else
    print_result "Telegram chat ID" "FAIL" "not configured"
fi

# --- 7. Build Environment ---
echo ""
echo "7. Build Env"
if [[ -f "$AVA_BUILD_ENV" ]]; then
    var_count=$(grep -c '=' "$AVA_BUILD_ENV" 2>/dev/null || echo "0")
    print_result "ava-build.env" "PASS" "$var_count variables"
else
    print_result "ava-build.env" "WARN" "not found (will use .env.local fallback)"
fi

# Keychain check (optional)
kc_test=$(security find-generic-password -s "ava-parallax" -a "ANTHROPIC_API_KEY" -w 2>/dev/null || echo "")
if [[ -n "$kc_test" ]]; then
    print_result "Keychain secrets" "PASS" "ava-parallax service found"
else
    print_result "Keychain secrets" "WARN" "not configured (optional)"
fi

# --- Summary ---
echo ""
echo "======================"
total=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "Results: $PASS_COUNT pass, $FAIL_COUNT fail, $WARN_COUNT warn (${total} total)"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "STATUS: FAILURES DETECTED"
    exit 1
else
    echo "STATUS: ALL CLEAR"
    exit 0
fi
