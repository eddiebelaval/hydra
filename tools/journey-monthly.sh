#!/bin/bash
# Monthly entry for the lab story (~/Development/id8/JOURNEY.md).
#
# THE PROBLEM THIS FIXES: JOURNEY.md calls itself "a living document, updated as
# the story continues." Nothing ever updated it. Last content date was 2026-03-05,
# five months stale, while "What's Next" still listed goals long since shipped or
# killed. A document that claims a cadence nobody runs is worse than one that
# admits it is a snapshot -- you trust it.
#
# WHAT IT DOES: assembles the month's real evidence (field notes, commits across
# the portfolio, memories filed), hands it to Claude headless with the story's own
# voice as reference, and writes a DRAFT. It does not touch JOURNEY.md.
#
# WHY A DRAFT AND NOT AN APPEND: the lab story is the company's autobiography in
# Eddie's voice. Identity and public positioning are his lane, not an automation's.
# The job does the assembly and the first pass; he lands it. Set JOURNEY_AUTOLAND=1
# to change that, deliberately.
#
# Origin: 2026-08-06.

set -uo pipefail

ID8="$HOME/Development/id8"
STORY="$ID8/JOURNEY.md"
FIELD="$ID8/FIELD_NOTES.md"
MEM="$HOME/.claude/projects/-Users-eddiebelaval-Development-id8/memory"
# Default to LAST month (this runs on the 1st, describing the month that just ended).
MONTH="${JOURNEY_MONTH:-$(date -v-1m '+%Y-%m')}"
LABEL="$(date -j -f '%Y-%m' "$MONTH" '+%B %Y' 2>/dev/null || echo "$MONTH")"
DRAFT="$ID8/JOURNEY-DRAFT-$MONTH.md"
EVID="$(mktemp)"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Lab story\" sound name \"Glass\"" 2>/dev/null || true
}

[ -f "$STORY" ] || { echo "no story at $STORY"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI not found"; exit 1; }

# ---- assemble the month's evidence -----------------------------------------
{
  echo "## Field notes filed in $MONTH"
  echo
  if [ -f "$FIELD" ]; then
    grep -E "^- $MONTH" "$FIELD" | cut -c1-600 || echo "(none)"
  fi
  echo
  echo "## Commits across the portfolio in $MONTH (subjects only)"
  echo
  for r in "$ID8" "$HOME/Development/id8-halos" "$HOME/.claude" "$HOME/.hydra" \
           "$HOME/Development/Homer" "$HOME/Development/fed" \
           "$HOME/Development/sands-of-the-restless" "$HOME/Development/3327"; do
    [ -d "$r/.git" ] || continue
    n=$(cd "$r" && git log --all --since="$MONTH-01" --until="$MONTH-31" \
          --no-merges --invert-grep --grep="chore(eod)" --oneline 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "0" ] && continue
    echo "### $(basename "$r") — $n commits"
    (cd "$r" && git log --all --since="$MONTH-01" --until="$MONTH-31" --no-merges \
       --invert-grep --grep="chore(eod)" --format="- %s" 2>/dev/null | sort -u | head -28)
    echo
  done
  echo "## Memories filed in $MONTH (what was learned)"
  echo
  find "$MEM" -maxdepth 1 -name "*.md" -newermt "$MONTH-01" ! -newermt "$MONTH-31" 2>/dev/null \
    | head -30 | while read -r f; do
        d=$(grep -m1 '^description:' "$f" 2>/dev/null | cut -c14-260)
        echo "- $(basename "$f" .md): $d"
      done
  echo
  echo "## The story's current 'What's Next' (now stale; replace it)"
  echo
  sed -n "/^## What's Next/,/^---/p" "$STORY" | head -20
} > "$EVID"

# ---- voice reference: the story's own most recent chapter --------------------
VOICE="$(sed -n '/^## Chapter 3/,/^## Chapter 5/p' "$STORY" | head -40)"

PROMPT="You are writing one monthly entry for the id8Labs lab story, the company's
autobiography. It lives at ~/Development/id8/JOURNEY.md and is written in Eddie
Belaval's voice.

VOICE REFERENCE (match this register exactly -- narrative, declarative, specific
numbers, short punchy sentences, names things, no hype, no em dashes, no emoji):
---
$VOICE
---

EVIDENCE FROM $LABEL (this is what actually happened; do not invent anything not
supported here):
---
$(cat "$EVID")
---

Write EXACTLY this, in markdown, and nothing else:

### $LABEL

Four short paragraphs, no headers inside, no bullet lists except where noted:

1. WHAT WE DID. The month's real work. Lead with the largest thing. Use specific
   numbers from the evidence. Name the projects.
2. HOW WE GREW. What the lab can do now that it could not on the 1st. Capability,
   not activity.
3. WHAT WE LEARNED. The lesson that cost the most to learn. Prefer a failure that
   became a rule over a success. Be concrete about what broke.
4. WHAT'S NEXT. Open with the exact line '**What's next:**' on its own line (bold
   text, NOT a markdown header -- the story already has a '## What's Next' section
   and a second H2 would collide). Then 4 to 6 bullets, forward-looking, drawn from
   what the evidence shows is in flight or blocked.

Rules: past tense for 1-3. No em dashes or en dashes, use commas or periods. No
emoji. Do not praise. If the evidence does not support a claim, leave it out. Aim
for 350 to 500 words total."

echo "$(date '+%Y-%m-%d %H:%M')  drafting $LABEL entry..."
if claude -p "$PROMPT" > "$DRAFT" 2>/dev/null && [ -s "$DRAFT" ]; then
  rm -f "$EVID"
  if [ "${JOURNEY_AUTOLAND:-0}" = "1" ]; then
    python3 - "$STORY" "$DRAFT" "$LABEL" << 'PY'
import io,sys,re
story,draft,label = sys.argv[1],sys.argv[2],sys.argv[3]
s=io.open(story,encoding='utf-8').read(); d=io.open(draft,encoding='utf-8').read().strip()
if "## The Monthly Record" not in s:
    s=s.replace("## Timeline", "## The Monthly Record\n\n_One entry a month. What we did, how we grew, what we learned, what is next._\n\n## Timeline",1)
s=s.replace("## Timeline", d+"\n\n## Timeline",1)
io.open(story,'w',encoding='utf-8').write(s)
print("  landed into the story")
PY
    notify "$LABEL entry landed in the lab story."
  else
    notify "$LABEL draft ready. Review, then land it."
    echo "  draft -> $DRAFT"
    echo "  review it, then append under '## The Monthly Record' in $STORY"
  fi
else
  rm -f "$EVID"
  notify "Lab story draft FAILED for $LABEL."
  echo "  FAILED: claude produced no output. Evidence assembly ran; retry by hand:"
  echo "  JOURNEY_MONTH=$MONTH ~/.hydra/tools/journey-monthly.sh"
  exit 2
fi
