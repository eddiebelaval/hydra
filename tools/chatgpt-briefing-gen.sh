#!/bin/bash
# Regenerate the ChatGPT briefing from the live brain.
#
# WHY THIS IS CURATED AND NOT A BRAIN DUMP: per project_chatgpt_split, ChatGPT is
# deliberately the OTHER lane -- existential / 2 a.m. / founder-as-instrument. The
# documented failure was ChatGPT collapsing existential questions into ops and
# strategy because it lacked stage context. Feeding it the full ops brain would make
# that worse, not better: more ops material to collapse into. So this assembles
# portfolio SHAPE and stage, not the ops brain.
#
# WHAT GETS SCRUBBED: this file is pasted into an external service. Anything sent
# there is published. Contact details, credential-shaped strings, and financial
# specifics are stripped before write, and the result is checked before it lands.
#
# Output: ~/.claude/CHATGPT-BRIEFING.md  (paste into a fresh ChatGPT session)
# Origin: 2026-08-06.

set -euo pipefail

MEM="$HOME/.claude/projects/-Users-eddiebelaval-Development-id8/memory"
FIELD="$HOME/Development/id8/FIELD_NOTES.md"
OUT="$HOME/.claude/CHATGPT-BRIEFING.md"
TMP="$(mktemp)"
TODAY="$(date '+%Y-%m-%d')"

[ -d "$MEM" ] || { echo "no memory dir at $MEM"; exit 1; }

{
  echo "# Briefing for ChatGPT"
  echo
  echo "_Regenerated $TODAY from the live brain. Paste into a fresh ChatGPT session._"
  echo
  echo "## Read this first"
  echo
  echo "I am not a pre-PMF first-time founder. This is my fourth startup, I am"
  echo "mid-execution, and I have paying clients. Do not hand me the Mom Test, Lean"
  echo "Startup, a reading list, or \"go find one customer.\" That is the wrong layer"
  echo "and the wrong moment, and it is the specific failure that made me write this."
  echo
  echo "**Your lane:** the existential register. The 2 a.m. founder-as-instrument"
  echo "layer. Durability, meaning, whether I can metabolize pain into clarity, the"
  echo "question behind the question. Claude holds ops, portfolio coherence,"
  echo "shipping, code, and infrastructure. I am not asking you to be Claude."
  echo
  echo "If I bring you an ops question, it is fine to say it belongs in the other"
  echo "lane. Do not collapse an existential question into a strategy answer."
  echo
  echo "## Where I actually am (as of $TODAY)"
  echo

  # SECTION-AWARE. Only North Stars / Portfolio / Project (what he is building and
  # where it stands). Feedback, Orchestration, and References are Claude's operating
  # rules -- they are ops, they are not stage context, and they are exactly what
  # makes ChatGPT collapse into strategy. Excluded on purpose.
  if [ -f "$MEM/MEMORY.md" ]; then
    awk '
      /^## /   { keep = ($0 ~ /North Stars|Portfolio|^## Project/) ? 1 : 0; next }
      keep && /^- \*\*/ { print }
    ' "$MEM/MEMORY.md" \
      | sed -E 's/\(dispatcher for:[^)]*\)//; s/\(sub-index:[^)]*\)//' \
      | sed -E 's/`[^`]*`//g' \
      | sed -E 's/\*\*//g; s/  +/ /g' \
      | grep -viE 'phone|contact|email|credit|FICO|rate sheet|invoic|supabase|worktree|disk hog' \
      | grep -viE 'skill|gate|verification|cockpit|host|commons|consolidation|deploy target|lexicon standard|periodic table' \
      | grep -viE 'banking|autopay|checking|brokerage|capital one|fidelity|infra \+ auto-pipes' \
      | sed -E 's/ +([;.,])/\1/g; s/—[ ;.]*=/—/; s/ +—/ —/; s/—[ ]*$//' \
      | grep -vE '—[ ]*[;.,]?[ ]*$' \
      | sed -E 's/[ ]*;[ ]*$//; s/;[ ]*\.[ ]*$/./' \
      | sed -E 's/[,;]? (at|on|via|in|to|from|ref|under)[ ]*[);.,]*$/./' \
      | sed -E 's/ \)/)/g; s/\([ ]*\)//g; s/[ ]+([.;])/\1/g' \
      | head -22
  fi

  echo
  echo "## What has actually been happening"
  echo
  if [ -f "$FIELD" ]; then
    # Hard-truncated on purpose. Full entries are bug archaeology and PR counts --
    # ops detail is exactly what makes ChatGPT collapse into strategy. Headlines only.
    tail -14 "$FIELD" | grep -E '^- 20' | tail -8 \
      | sed -E 's/^- ([0-9-]+)[^A-Za-z0-9]*/- \1: /' \
      | cut -c1-165 | sed -E 's/[ ,;.]*$/.../' \
      | sed -E 's/^- ([0-9-]+): ([a-z]+)\): /- \1 (\2): /'
  else
    echo "_(field notes unavailable)_"
  fi

  echo
  echo "## How to talk to me"
  echo
  echo "- Peer register. You are not my assistant and not my teacher."
  echo "- Bring a pick, not a menu. Call / why / one alternative. I will note if I disagree."
  echo "- Analogies land: nature and mycology, TV production, music, real estate."
  echo "- No em dashes. No emoji. No founder kindergarten. No reading lists as deflection."
  echo "- Do not hedge to be safe. If you think I am wrong, say so plainly and once."
  echo
  echo "## Depletion tells"
  echo
  echo "When my typing degrades -- typos, all lower-case, \"i can't tell anymore\" --"
  echo "that is not a prompt to optimize. Slow down and ask about the person, not the"
  echo "portfolio. Do not respond with a plan."
  echo
  echo "## Standing risks to watch me for"
  echo
  echo "Sprawl. Depletion. Cathedral-reading (admiring the system instead of shipping"
  echo "it). The iterative cliff (polishing past the point of return). Naming these"
  echo "when you see them is more useful than another strategy."
  echo
  echo "---"
  echo "_Generated by chatgpt-briefing-gen.sh. Curated to the existential lane on"
  echo "purpose; ops context lives with Claude._"
} > "$TMP"

# Scrub anything that should never reach an external service.
/usr/bin/sed -i '' -E \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[email redacted]/g' \
  -e 's/[0-9]{3}[.-][0-9]{3}[.-][0-9]{4}/[phone redacted]/g' \
  -e 's/(sbp_|sk-|ghp_|eyJ)[A-Za-z0-9_.-]{8,}/[credential redacted]/g' \
  -e 's/\$[0-9][0-9,]*(\.[0-9]+)?[KkMm]?/[amount redacted]/g' \
  "$TMP"

# Verify the scrub actually worked before publishing (do not trust sed silently).
LEAKS=$(grep -icE '@[a-z0-9.-]+\.(com|tech|org|net)|sbp_|sk-|ghp_|eyJ[A-Za-z0-9]' "$TMP" || true)
if [ "${LEAKS:-0}" -gt 0 ]; then
  echo "REFUSING TO WRITE: $LEAKS possible leak(s) survived the scrub."
  echo "Inspect: $TMP"
  exit 2
fi

mv "$TMP" "$OUT"
echo "$(date '+%Y-%m-%d %H:%M')  wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
