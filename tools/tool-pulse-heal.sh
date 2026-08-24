#!/usr/bin/env bash
# tool-pulse-heal.sh -- the AUTO-heal actor for the tool-pulse RED.
#
# The tender's boundary (gardener.py): AUTO = internal + reversible + no external
# effect. Upgrading a deploy CLI to its own latest is exactly that -- deterministic,
# reversible (a version can be pinned back), touches nothing outside this machine.
# So this is the one red on the board that heals itself. Everything with an external
# effect (auth, money, outbound, a deploy) is NOT ours -- it escalates, never here.
#
# HARD RULE: never run a bare `brew upgrade` (that upgrades the whole system). Only
# the SPECIFIC deploy-critical tools tool-pulse flags: supabase (brew tap), vercel
# (npm -g, in both node trees). Idempotent: safe to re-run; a no-op when current.
#
# Wired as the heal step after tool-pulse-check. On success it credits selfHealed[]
# in the tend report (the Gardener reads it as HEALED, the Sweep Clock flips it
# green with "healed"). If the upgrade runs but the red persists, it ESCALATES.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
export HOME="${HOME:-/Users/eddiebelaval}"
TOOLS="$HOME/.hydra/tools"
PRE_LOG="$(mktemp -t tool-pulse-pre)"; POST_LOG="$(mktemp -t tool-pulse-post)"
trap 'rm -f "$PRE_LOG" "$POST_LOG"' EXIT

# 1. Only act on a real RED. exit 2 = RED (deploy-critical stale); 0/1 are not ours.
"$TOOLS/tool-pulse-check.sh" >"$PRE_LOG" 2>&1; PRE=$?
if [ "$PRE" -ne 2 ]; then
  echo "tool-pulse is not RED (check exit $PRE) -- nothing to auto-heal."
  exit 0
fi

HEALED=()

# 2a. supabase CLI -- Homebrew tap. Targeted formula upgrade only.
if grep -qi "supabase CLI:" "$PRE_LOG"; then
  before="$(supabase --version 2>/dev/null | head -1)"
  echo "auto-heal: brew upgrade supabase/tap/supabase ..."
  brew upgrade supabase/tap/supabase >/dev/null 2>&1 || true
  after="$(supabase --version 2>/dev/null | head -1)"
  [ -n "$after" ] && [ "$before" != "$after" ] && HEALED+=("supabase ${before:-?} -> $after")
fi

# 2b. vercel -- npm global, lives in BOTH the nvm tree and the /usr/local (brew-node)
# tree; upgrade in each so both binaries advance (matches what tool-pulse checks).
# Call each npm binary by full path -- sourcing nvm.sh under `set -u` trips on its
# own unset vars and silently kills the upgrade (the bug that first shipped here).
if grep -qi "vercel:" "$PRE_LOG"; then
  before="$(vercel --version 2>/dev/null | head -1)"
  echo "auto-heal: npm install -g vercel@latest (every node tree) ..."
  for NPM in "$HOME"/.nvm/versions/node/*/bin/npm /usr/local/bin/npm /opt/homebrew/bin/npm; do
    [ -x "$NPM" ] && "$NPM" install -g vercel@latest >/dev/null 2>&1 || true
  done
  after="$(vercel --version 2>/dev/null | head -1)"
  [ -n "$after" ] && [ "$before" != "$after" ] && HEALED+=("vercel ${before:-?} -> $after")
fi

# 3. Re-verify from ground truth. Re-running the check rewrites tool-pulse.json to
# the true post-upgrade state.
"$TOOLS/tool-pulse-check.sh" >"$POST_LOG" 2>&1; POST=$?

# 4. Credit the heal, or escalate if it didn't clear.
if [ "$POST" -eq 0 ] && [ ${#HEALED[@]} -gt 0 ]; then
  "$TOOLS/tend-report" tool-pulse GREEN "toolchain current (auto-healed)" 168 "" "" "$(printf '%s; ' "${HEALED[@]}")"
  echo "HEALED: ${HEALED[*]}"
  exit 0
elif [ "$POST" -eq 0 ]; then
  echo "tool-pulse already current -- no upgrade was needed."
  exit 0
else
  # Upgrade ran but the red persists (e.g. a non-brew gh, or a pinned version).
  # That is no longer a clean AUTO -- hand it to Eddie.
  "$TOOLS/tend-report" tool-pulse RED "auto-heal ran; still stale -- needs a look" 168 \
    "tool-pulse still RED after an auto-upgrade attempt" "eddie"
  echo "STILL RED after auto-heal -- escalated to Eddie."
  exit 2
fi
