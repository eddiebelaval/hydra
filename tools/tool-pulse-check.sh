#!/bin/bash
# tool-pulse-check.sh -- Weekly toolchain version pulse (report-only, no auto-upgrade)
# Schedule: Mondays 09:15 via com.hydra.tool-pulse launchd agent
# Output:   ~/Development/id8/.context/TOOL-PULSE.md (standing report, overwritten each run)
# Exit:     0 = GREEN (all current), 1 = YELLOW (stale, non-critical), 2 = RED (deploy-critical tool stale)
#
# Deploy-critical tools (RED if stale): supabase, vercel, gh.
# There are TWO npm global trees on this machine -- nvm node's and brew node's.
# Both are checked; whichever tree wins PATH resolution is what actually runs.

set -u
NVM_NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="${NVM_NODE_BIN:+$NVM_NODE_BIN:}/opt/homebrew/bin:/usr/local/bin:$PATH"

REPORT_DIR="$HOME/Development/id8/.context"
REPORT="$REPORT_DIR/TOOL-PULSE.md"
mkdir -p "$REPORT_DIR"

NOW="$(date '+%Y-%m-%d %H:%M %Z')"
STATUS="GREEN"
CRITICAL_STALE=()
declare -a BREW_LINES

# ---- Homebrew ----
brew update >/dev/null 2>&1
BREW_OUTDATED="$(brew outdated --verbose 2>/dev/null)"
if [ -n "$BREW_OUTDATED" ]; then
  STATUS="YELLOW"
  while IFS= read -r line; do BREW_LINES+=("$line"); done <<< "$BREW_OUTDATED"
fi
if echo "$BREW_OUTDATED" | grep -q '^gh '; then
  STATUS="RED"
  CRITICAL_STALE+=("gh: $(echo "$BREW_OUTDATED" | grep '^gh ' | head -1)")
fi

# ---- Tap formulae that plain `brew outdated` can miss (supabase/tap) ----
SUPA_INSTALLED="$(supabase --version 2>/dev/null | head -1)"
SUPA_LATEST="$(brew info supabase/tap/supabase 2>/dev/null | head -1 | sed -E 's/.*stable ([0-9.]+).*/\1/')"
if [ -n "$SUPA_INSTALLED" ] && [ -n "$SUPA_LATEST" ] && [ "$SUPA_INSTALLED" != "$SUPA_LATEST" ]; then
  STATUS="RED"
  CRITICAL_STALE+=("supabase CLI: $SUPA_INSTALLED -> $SUPA_LATEST")
fi

# ---- npm globals: check BOTH trees ----
# is_older a b -> true if version a < version b
is_older() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# check_npm_tree <npm-binary> -> sets NPM_TREE_LINES array + updates STATUS
check_npm_tree() {
  local npm_bin="$1"
  NPM_TREE_LINES=()
  [ -x "$npm_bin" ] || return 0
  local outdated
  outdated="$("$npm_bin" outdated -g 2>/dev/null | tail -n +2)"
  [ -z "$outdated" ] && return 0
  local line pkg cur latest
  while IFS= read -r line; do
    pkg="$(echo "$line" | awk '{print $1}')"
    cur="$(echo "$line" | awk '{print $2}' | sed 's/^v//')"
    latest="$(echo "$line" | awk '{print $4}' | sed 's/^v//')"
    # skip locally-linked dev packages
    [ "$pkg" = "cortex-protocol" ] && continue
    # npm outdated also flags installed AHEAD of latest dist-tag -- only report genuinely stale
    is_older "$cur" "$latest" || continue
    NPM_TREE_LINES+=("$line")
    [ "$STATUS" = "GREEN" ] && STATUS="YELLOW"
    case "$pkg" in
      vercel) STATUS="RED"; CRITICAL_STALE+=("vercel: $cur -> $latest") ;;
    esac
  done <<< "$outdated"
}

NVM_NPM="${NVM_NODE_BIN:+$NVM_NODE_BIN/npm}"
BREW_NPM="/opt/homebrew/bin/npm"
NVM_NODE_V="$([ -n "$NVM_NODE_BIN" ] && "$NVM_NODE_BIN/node" --version 2>/dev/null)"
BREW_NODE_V="$(/opt/homebrew/bin/node --version 2>/dev/null)"

check_npm_tree "$NVM_NPM";  NVM_LINES=("${NPM_TREE_LINES[@]+"${NPM_TREE_LINES[@]}"}")
check_npm_tree "$BREW_NPM"; BREWNPM_LINES=("${NPM_TREE_LINES[@]+"${NPM_TREE_LINES[@]}"}")

GH_INSTALLED="$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
CLAUDE_VERSION="$(claude --version 2>/dev/null | head -1)"

# ---- Write report ----
{
  echo "# Tool Pulse -- $NOW"
  echo
  echo "**Verdict: $STATUS**"
  echo
  if [ ${#CRITICAL_STALE[@]} -gt 0 ]; then
    echo "## RED -- deploy-critical tools stale"
    echo
    for c in "${CRITICAL_STALE[@]}"; do echo "- $c"; done
    echo
  fi
  echo "## Snapshot"
  echo
  echo '| Tool | Version |'
  echo '|------|---------|'
  echo "| supabase CLI | ${SUPA_INSTALLED:-not found} (latest ${SUPA_LATEST:-?}) |"
  echo "| gh | ${GH_INSTALLED:-not found} |"
  echo "| claude | ${CLAUDE_VERSION:-not found} |"
  echo "| node (nvm) | ${NVM_NODE_V:-not found} |"
  echo "| node (brew) | ${BREW_NODE_V:-not found} |"
  echo "| python3 (brew) | $(python3 --version 2>/dev/null | awk '{print $2}') |"
  echo
  echo "## Homebrew outdated (${#BREW_LINES[@]})"
  echo
  if [ ${#BREW_LINES[@]} -eq 0 ]; then
    echo "All current."
  else
    echo '```'
    printf '%s\n' "${BREW_LINES[@]}"
    echo '```'
  fi
  echo
  echo "## npm globals outdated -- nvm tree ${NVM_NODE_V:-?} (${#NVM_LINES[@]})"
  echo
  if [ ${#NVM_LINES[@]} -eq 0 ]; then
    echo "All current."
  else
    echo '```'
    printf '%s\n' "${NVM_LINES[@]}"
    echo '```'
  fi
  echo
  echo "## npm globals outdated -- brew-node tree ${BREW_NODE_V:-?} (${#BREWNPM_LINES[@]})"
  echo
  if [ ${#BREWNPM_LINES[@]} -eq 0 ]; then
    echo "All current."
  else
    echo '```'
    printf '%s\n' "${BREWNPM_LINES[@]}"
    echo '```'
  fi
  echo
  echo "## Remediation (copy-paste)"
  echo
  echo '```bash'
  echo 'brew upgrade && brew upgrade supabase/tap/supabase'
  echo "# nvm tree:"
  echo "$NVM_NPM outdated -g | tail -n +2 | awk '\$1 != \"cortex-protocol\" {print \$1\"@latest\"}' | xargs $NVM_NPM install -g"
  echo "# brew-node tree:"
  echo "$BREW_NPM outdated -g | tail -n +2 | awk '{print \$1\"@latest\"}' | xargs $BREW_NPM install -g"
  echo '```'
  echo
  echo "_Report-only. cortex-protocol is excluded (local symlink to ~/Development/cortex)._"
} > "$REPORT"

# Tend contract (TEND-CONTRACT.md): self-report tool-pulse's own verdict so the
# Gardener reads it by its word, not by a launchd exit code. Weekly cadence.
source "$HOME/.hydra/tools/tend-lib.sh" 2>/dev/null || true
TP_DETAIL="tool pulse: $STATUS"
if [ ${#CRITICAL_STALE[@]} -gt 0 ]; then
  TP_DETAIL="deploy-critical stale: $(printf '%s; ' "${CRITICAL_STALE[@]}")"
fi
tend_report tool-pulse "$STATUS" "$TP_DETAIL" 168

case "$STATUS" in
  GREEN)  exit 0 ;;
  YELLOW) exit 1 ;;
  RED)    exit 2 ;;
esac
