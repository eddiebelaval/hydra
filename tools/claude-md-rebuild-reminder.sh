#!/bin/bash
# Semi-annual CLAUDE.md rebuild prompt (Feb 15 / Aug 15).
#
# Deliberately does NOT swap anything. CLAUDE.md is guarded config that governs
# every session across 4-10 parallel sessions; per feedback_config_self_mod_edits
# a config change is presented as a diff for approval, never auto-applied on a
# timer. This job stages the decision and gets out of the way.
#
# Origin: 2026-08-03. The practice (periodically invalidate your CLAUDE.md rather
# than let it accrete) plus the audit at ~/.claude/CLAUDE-MD-AUDIT-2026-08-03.md.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
LIVE="$CLAUDE_DIR/CLAUDE.md"
DRAFT="$CLAUDE_DIR/CLAUDE.md.rebuild-2026-08-15"
STAMP="$(date +%Y-%m-%d)"
OUT="$CLAUDE_DIR/CLAUDE-MD-REBUILD-DUE-$STAMP.md"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"CLAUDE.md rebuild due\" sound name \"Submarine\"" 2>/dev/null || true
}

[ -f "$LIVE" ] || { notify "CLAUDE.md not found at $LIVE"; exit 1; }

{
  echo "# CLAUDE.md rebuild due - $STAMP"
  echo
  echo "Semi-annual prompt. Nothing has been changed. This is a decision, not a task."
  echo
  echo "## Current state"
  echo
  echo "- Live file: \`$LIVE\` ($(wc -l < "$LIVE" | tr -d ' ') lines, last modified $(date -r "$LIVE" '+%Y-%m-%d'))"
  if [ -f "$DRAFT" ]; then
    echo "- Staged draft: \`$DRAFT\` ($(wc -l < "$DRAFT" | tr -d ' ') lines)"
  else
    echo "- Staged draft: NONE. Start from blank, which is the stronger version of this exercise."
  fi
  echo
  echo "## The exercise"
  echo
  echo "Do NOT edit the live file into shape. Park it and rebuild:"
  echo
  echo '```bash'
  echo "cp \"$LIVE\" \"$CLAUDE_DIR/CLAUDE.md.archive-$STAMP\""
  if [ -f "$DRAFT" ]; then
    echo "cp \"$DRAFT\" \"$LIVE\"      # start from the staged draft"
  fi
  echo ": > \"$LIVE\"                  # or start genuinely blank"
  echo '```'
  echo
  echo "Then work for two weeks and add back ONLY what you actually miss, at the"
  echo "moment you miss it. The map tells you what is redundant; only absence tells"
  echo "you what is load-bearing. Those are different questions."
  echo
  echo "## Why this is safe"
  echo
  echo "- \`~/.claude\` is a git repo. Every version of this file is recoverable."
  echo "- Every substantive section already exists as a \`feedback_*\` / \`project_*\`"
  echo "  memory, most of them longer. Removing it changes WHEN a rule loads, not"
  echo "  whether the knowledge exists."
  echo "- Your feedback memories carry \`signatures\` and the outer loop detects"
  echo "  recurrence. Drop a load-bearing rule and the failure returns AND is caught."
  echo
  echo "## Protected"
  echo
  echo "Showrunner Mode and branch hygiene stay, in always-on form. Ratified"
  echo "2026-04-23 and reconfirmed 2026-08-03."
  echo
  if [ -f "$DRAFT" ]; then
    echo "## Diff: live vs staged draft"
    echo
    echo '```diff'
    diff -u "$LIVE" "$DRAFT" 2>/dev/null | head -200 || echo "(identical, or diff unavailable)"
    echo '```'
    echo
  fi
  echo "## Reference"
  echo
  echo "- Audit: \`$CLAUDE_DIR/CLAUDE-MD-AUDIT-2026-08-03.md\` (paired \`.html\`)"
  echo "- Do not run this during a live client window. Check what is in flight first."
} > "$OUT"

notify "Briefing written. Nothing changed. See CLAUDE-MD-REBUILD-DUE-$STAMP.md"
echo "wrote $OUT"
