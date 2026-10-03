#!/bin/bash
# ejb.ventures monthly Log drafter. Runs the 1st of each month, 9:30am.
#
# Gathers the month that just ended (FIELD_NOTES, commits across the public
# repos, new essays, which public pages are live), asks Claude (`claude -p`,
# no tools) to write that month's Log entry in Eddie's voice under the rules
# in ~/.claude/ejb-log/instructions.md, validates it, builds the site, and
# commits it on branch log/YYYY-MM in its own worktree. NEVER pushes: Eddie
# reads the review page, and "ship the log" in a session publishes it.
#
#   MONTH=2026-09 DRY=1 ejb-log-monthly.sh   # draft to stdout only, no branch

set -uo pipefail

source "$HOME/.hydra/tools/tend-lib.sh" 2>/dev/null || true
trap 'rc=$?; if [ "$rc" -eq 0 ]; then tend_report "${SITE:-ejb}-log-monthly" GREEN "log draft ready" 744; else tend_report "${SITE:-ejb}-log-monthly" RED "exited $rc" 744 "${SITE:-ejb} monthly log draft failed (exit $rc)" "read ~/Library/Logs/ejb-log"; fi' EXIT
source "$HOME/.claude/id8labs-sub.env"

# SITE=ejb (default) drafts the ejb.ventures Log; SITE=hamato drafts a
# Hamato Field Notes dispatch (its own voice rules in instructions-hamato.md).
SITE="${SITE:-ejb}"
DEV="$HOME/Development"
STATE="$HOME/.claude/ejb-log"
if [ "$SITE" = "hamato" ]; then
  REPO="$DEV/hamato-site"; LOGDIR="content/field-notes"; INSTR="$STATE/instructions-hamato.md"; TAG="hamato-notes"; NAME="Hamato Field Notes"
else
  REPO="$DEV/ejb.ventures"; LOGDIR="content/log"; INSTR="$STATE/instructions.md"; TAG="log"; NAME="ejb.ventures Log"
fi
LOG_DIR="$HOME/Library/Logs/ejb-log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%F).log"
log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }

MONTH="${MONTH:-$(date -v-1d +%Y-%m)}"   # on the 1st: the month that just ended
SINCE="$MONTH-01"
UNTIL="$(date -j -v+1m -f %Y-%m-%d "$SINCE" +%Y-%m-%d)"
DRY="${DRY:-0}"
log "=== $SITE $MONTH (since $SINCE until $UNTIL) dry=$DRY ==="

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
[ -z "$CLAUDE_BIN" ] && { log "ERROR: claude CLI missing"; exit 1; }

# --- gather the month's facts (deterministic) --------------------------------
FACTS="$(mktemp)"
{
  echo "# Facts for $MONTH"
  echo
  echo "## FIELD_NOTES entries"
  grep -E "^- $MONTH" "$DEV/id8/FIELD_NOTES.md" 2>/dev/null | grep -viE "canary|health|throttled|reaper|unpushed-sweep|nightly" | cut -c1-600
  echo
  echo "## Commits in public-facing repos"
  for r in ejb.ventures id8labs-site id8-workshops hamato-site parallax; do
    [ -d "$DEV/$r/.git" ] || continue
    c="$(git -C "$DEV/$r" log --since="$SINCE" --until="$UNTIL" --no-merges --format='- %s' 2>/dev/null | grep -viE '^- (wip|chore|eod|snapshot|merge)' | head -25)"
    [ -n "$c" ] && { echo "### $r"; echo "$c"; }
  done
  echo
  echo "## Essays published this month"
  for f in "$DEV"/id8labs-site/content/essays/*.md*; do
    d="$(grep -m1 -E '^date:' "$f" | tr -d "\"' " | cut -d: -f2)"
    [[ "$d" == $MONTH* ]] || continue
    t="$(grep -m1 -E '^title:' "$f" | cut -d: -f2- | sed 's/^ *//; s/^"//; s/"$//')"
    echo "- $t (https://id8labs.app/writing/$(basename "${f%.*}"))"
  done
  echo
  echo "## Public pages (only link ones marked LIVE)"
  grep -v '^#' "$STATE/urls.txt" | while read -r u; do
    [ -z "$u" ] && continue
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u")"
    [ "$code" = "200" ] && echo "- LIVE $u" || echo "- DOWN($code) $u"
  done
} > "$FACTS"
log "facts: $(wc -l < "$FACTS") lines"

# --- worktree on its own branch (never touches the main checkout) ------------
BR="$TAG/$MONTH"
WT="$DEV/.worktrees/$(basename "$REPO")/$TAG-$MONTH"
if [ "$DRY" != "1" ]; then
  git -C "$REPO" fetch -q origin
  if [ ! -d "$WT" ]; then
    git -C "$REPO" worktree add -q -B "$BR" "$WT" origin/main || { log "ERROR: worktree"; exit 1; }
  fi
  SRC="$WT"
else
  SRC="$REPO"
fi
ENTRY="$LOGDIR/$MONTH.md"
CURRENT="$SRC/$ENTRY"

# --- ask Claude for the entry --------------------------------------------------
PROMPT="$(mktemp)"
{
  cat "$INSTR"
  echo
  echo "# The month: $MONTH"
  echo
  if [ -f "$CURRENT" ]; then echo "# Current entry (approved: keep it, only add)"; cat "$CURRENT"; echo; fi
  cat "$FACTS"
} > "$PROMPT"
DRAFT="$(mktemp)"
"$CLAUDE_BIN" -p --model claude-opus-5-5 --output-format text < "$PROMPT" > "$DRAFT" 2>>"$LOG_FILE"
# keep only the frontmatter block, in case anything leaked around it
python3 - "$DRAFT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"^---\n.*?\n---\s*$", s, re.S | re.M)
open(p, "w").write((m.group(0).strip() + "\n") if m else "")
PY

# --- validate ------------------------------------------------------------------
[ -s "$DRAFT" ] || { log "ERROR: no entry in Claude's output"; exit 1; }
# Eddie's rule: no em or en dashes (bash 3.2 can't spell them; perl can)
perl -CSD -0pi -e 's/ \x{2014} /, /g; s/\x{2014}/, /g; s/\x{2013}/-/g' "$DRAFT"
# a link only if there is one
perl -ni -e 'print unless /^\s*url:\s*("")?\s*$/' "$DRAFT"
node -e '
const matter = require(process.env.HOME + "/Development/ejb.ventures/node_modules/gray-matter");
const d = matter(require("fs").readFileSync(process.argv[1], "utf8")).data;
const ok = /^\d{4}-(0[1-9]|1[0-2])$/.test(String(d.month)) && String(d.month) === process.argv[3]
  && typeof d.headline === "string" && d.headline.trim() && Array.isArray(d.items) && d.items.length > 0
  && d.items.every((i) => i && typeof i.text === "string" && (!i.url || /^https:\/\//.test(i.url)));
if (!ok) { console.error("invalid entry", JSON.stringify(d)); process.exit(1); }
' "$DRAFT" "$REPO" "$MONTH" || { log "ERROR: entry failed validation"; cat "$DRAFT" >> "$LOG_FILE"; exit 1; }

if [ "$DRY" = "1" ]; then cat "$DRAFT"; exit 0; fi

# --- write, build, commit on the branch -----------------------------------------
mkdir -p "$WT/$LOGDIR"
cp "$DRAFT" "$WT/$ENTRY"
( cd "$WT" && npm ci --silent >/dev/null 2>&1 && npm run build >/dev/null 2>>"$LOG_FILE" ) || { log "ERROR: build failed with the new entry"; exit 1; }
git -C "$WT" add "$ENTRY"
git -C "$WT" commit -q -m "job($TAG): $MONTH entry (drafted by the monthly job, awaiting Eddie's read)" || log "nothing new to commit"

# --- review page + ping Eddie ----------------------------------------------------
REVIEW="$STATE/review-$SITE-$MONTH.html"
python3 - "$WT/$ENTRY" "$REVIEW" "$MONTH" "$NAME" "$BR" <<'PY'
import html, sys, re
src, out, month, name, branch = sys.argv[1:]
body = html.escape(open(src).read())
open(out, "w").write(f"""<!doctype html><html><head><meta charset="utf-8"><title>{name} draft {month}</title>
<style>:root{{--ink:#111;--paper:#fff;--mute:#666}}body{{margin:0;padding:32px 16px;background:var(--paper);color:var(--ink);font:15px/1.6 ui-monospace,Menlo,monospace}}
main{{max-width:760px;margin:0 auto}}pre{{white-space:pre-wrap;border:2px solid var(--ink);box-shadow:4px 4px 0 var(--ink);padding:16px}}p{{color:var(--mute)}}</style></head>
<body><main><h1>{name}: {month} draft</h1>
<p>Drafted by the monthly job on branch {branch}. Nothing is live. Edit anything, then say "ship the log" in a Claude session.</p>
<pre>{body}</pre></main></body></html>""")
PY
"$HOME/.hydra/daemons/notify-eddie.sh" urgent "$NAME draft" "Your $MONTH $NAME entry is drafted and waiting for your read. Say 'ship the log' to publish." "$REVIEW" || true
log "done: branch $BR, review $REVIEW"
