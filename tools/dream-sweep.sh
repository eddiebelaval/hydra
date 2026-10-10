#!/bin/bash
# dream-sweep.sh - The Dream Layer, v1 (conceived 2026-08-18, built 2026-08-21).
#
# The first layer of the machine that serves the PERSON, not the work. Everything
# else Eddie built is a waking mind: vigilant, convergent, verifying. This is the
# dreaming mind: nightly, it stops verifying and reads the day on two sensors --
#   FELT  amplitude: how big the day FELT (Eddie's own words today, via the voz genome)
#   ACTUAL amplitude: how big the day WAS   (git across repos + FIELD_NOTES + journals)
# The gap between them is the product. Loudest on the UNFELT WIN: actual high, felt
# flat -- the day he shipped big and closed it out like an ordinary Tuesday.
#
# v1 scope (dead simple, per SKETCH.md): read the day's transcript + git, compute
# felt-vs-actual, write ONE warm dream to DREAM.md, loud only when they diverge.
# No resonance recall yet. Cheap model. The output is Eddie's rawest signal, so it
# stays LOCAL -- gitignored, never pushed, never emailed, never sent outbound.
#
# Design doc: ~/.hydra/docs/dream-layer.md (design record); origin sketch at ~/Development/id8/dream-layer/SKETCH.md
set -euo pipefail

HOME_DIR="$HOME"
HYDRA="$HOME_DIR/.hydra"
DREAMS_DIR="$HYDRA/dreams"
STORE_DIR="$DREAMS_DIR/store"
LOG_DIR="$HYDRA/logs"
DREAM_FILE="$DREAMS_DIR/DREAM.md"
VOZ_GENOME="$HOME_DIR/.claude/skills/voz/VOICE-GENOME.md"
FIELD_NOTES="$HOME_DIR/Development/id8/FIELD_NOTES.md"
# Target date resolution:
#   (no arg) / today  -> today, writes DREAM.md            (manual daytime run)
#   nightly           -> the day that JUST ENDED, DREAM.md  (the 03:30 job)
#   <YYYY-MM-DD>      -> that day; a PAST date is backfill, store-only
# The nightly job MUST target yesterday. At 03:30 the new day is empty (no commits
# and no transcripts yet), which starved ACTUAL to ~152B and made every dream a
# rehash of the same recent voice. Metabolize the completed day instead.
TODAY="$(date '+%Y-%m-%d')"
case "${1:-}" in
  ""|today) TARGET_DATE="$TODAY"; BACKFILL=0 ;;
  nightly)  TARGET_DATE="$(date -v-1d '+%Y-%m-%d')"; BACKFILL=0 ;;
  *)        TARGET_DATE="$1"; if [ "$1" = "$TODAY" ]; then BACKFILL=0; else BACKFILL=1; fi ;;
esac
DATE="$TARGET_DATE"
NICE_DATE="$(date -j -f '%Y-%m-%d' "$TARGET_DATE" '+%A, %B %-d' 2>/dev/null || echo "$TARGET_DATE")"
FN_BD="$(date -j -f '%Y-%m-%d' "$TARGET_DATE" '+%b %-d' 2>/dev/null || echo "$TARGET_DATE")"
FN_MD="$(date -j -f '%Y-%m-%d' "$TARGET_DATE" '+%m/%d' 2>/dev/null || echo "$TARGET_DATE")"
# Backfill writes ONLY to the store; today/nightly write DREAM.md (the surfaced dream).
if [ "$BACKFILL" = 1 ]; then OUT="$STORE_DIR/dream-$TARGET_DATE.md"; else OUT="$DREAM_FILE"; fi
LOG_FILE="$LOG_DIR/dream-sweep.log"

mkdir -p "$DREAMS_DIR" "$STORE_DIR" "$LOG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Tend contract: self-report on every exit so the Gardener reads dream-sweep by its
# own word, not a launchd exit code.
source "$HYDRA/tools/tend-lib.sh" 2>/dev/null || true
trap 'rc=$?; if [ "$rc" -eq 0 ]; then tend_report dream-sweep GREEN "dream swept" 24; else tend_report dream-sweep RED "exited $rc" 24 "dream-sweep failed (exit $rc)" "read the dream-sweep log; the person-layer went dark"; fi' EXIT 2>/dev/null || true

log "dream-sweep start ($DATE)"

# ---------------------------------------------------------------------------
# 1. ACTUAL amplitude: how big the day WAS. Deterministic gather.
# ---------------------------------------------------------------------------
ACTUAL_FILE="$(mktemp)"
{
  echo "## Git across the estate (the target day, local time)"
  # Every repo, not a hand-picked five: client work (Data-Tech, Resonance, D&B) lives
  # outside id8, and a day spent there read as "quiet". Worktrees share the parent's
  # objects, so they are skipped to avoid double counting. wip snapshots are noise.
  { echo "$HYDRA"; echo "$HOME_DIR/.claude"
    find "$HOME_DIR/Development" -maxdepth 3 -name .git -not -path '*/.worktrees/*' -not -path '*/node_modules/*' 2>/dev/null | sed 's#/\.git$##'
  } | sort -u | while read -r repo; do
    [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
    commits="$(git -C "$repo" log --all --since="$DATE 00:00" --until="$DATE 23:59:59" --pretty='  %s' --no-merges 2>/dev/null | grep -viE 'chore\(eod\)|nightly snapshot|^  wip: session snapshot|^  wip:' | sort -u | head -12 || true)"
    [ -n "$commits" ] && { echo "### ${repo#$HOME_DIR/}"; echo "$commits"; }
  done
  echo
  echo "## FIELD_NOTES lines dated today"
  grep -E "$DATE|$FN_BD|$FN_MD" "$FIELD_NOTES" 2>/dev/null | head -15 || echo "  (none dated today)"
} > "$ACTUAL_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. FELT amplitude: how big the day FELT. Eddie's own words today.
#    Pull user-authored text from today's session transcripts (his voice),
#    strip machine noise, cap the volume.
# ---------------------------------------------------------------------------
FELT_FILE="$(mktemp)"
PROJECTS="$HOME_DIR/.claude/projects"
# TIMING (fixed 2026-10-10): sessions run for days and across midnight. The old gather
# picked files whose LAST write fell inside the day, then fed each file's last 40
# messages regardless of when they were said. Result: any session still open after
# midnight was dropped (Oct 9 saw 24 of 126 messages), and any long session that
# happened to close that day dragged in words from 3-5 days earlier (Oct 7 was fed
# Oct 2-6), so the dream kept re-reading the same stretch. Now: every session touched
# on or after the day, every message filtered by its OWN timestamp in local time,
# merged across sessions chronologically, then sampled evenly across the day.
find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -not -path '*/subagents/*' -newermt "$DATE 00:00" 2>/dev/null \
  | python3 -c '
import json, sys, datetime
day = sys.argv[1]
NOISE = ("system-reminder", "temporal context", "caveat:", "command-name",
         "local-command", "tool_use_error", "<bash-", "hook success", "hook error")
MACHINE = ("Another Claude session sent a message", "Here is a note offered by",
           "This session is being continued", "Base directory for this skill")
msgs = []
for path in sys.stdin:
    path = path.strip()
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except Exception:
        continue
    with fh:
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") != "user" or not o.get("timestamp"):
                continue
            # Only words Eddie typed: interactive CLI turns. Scheduled claude -p jobs
            # (sdk-*), injected meta turns (/loop pulses, skill bodies) and cross-session
            # hand-backs are the machine talking, not him. Counting them made the dream
            # say his only words were "pasted security prompts and drain protocols".
            if o.get("entrypoint") != "cli" or o.get("isMeta"):
                continue
            try:
                ts = datetime.datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).astimezone()
            except Exception:
                continue
            if ts.date().isoformat() != day:
                continue
            content = o.get("message", {}).get("content")
            if isinstance(content, str):
                t = content
            elif isinstance(content, list):
                t = " ".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
            else:
                t = ""
            t = t.strip()
            if not t or t.startswith(("{", "[", "<", "/")) or t.startswith(MACHINE) or any(k in t.lower() for k in NOISE):
                continue
            msgs.append((ts, t))
msgs.sort(key=lambda m: m[0])
# Even sample across the whole day (morning to night), not just the tail.
CAP = 45
if len(msgs) > CAP:
    step = len(msgs) / CAP
    msgs = [msgs[int(i * step)] for i in range(CAP - 1)] + [msgs[-1]]
for ts, t in msgs:
    print("- [" + ts.strftime("%H:%M") + "] " + t[:200].replace("\n", " "))
' "$DATE" > "$FELT_FILE" 2>/dev/null || true

# Cap felt volume (already day-scoped and sampled; this is a safety net).
FELT_TRIM="$(mktemp)"; tail -c 9000 "$FELT_FILE" > "$FELT_TRIM" 2>/dev/null || true
ACTUAL_TRIM="$(mktemp)"; head -c 6000 "$ACTUAL_FILE" > "$ACTUAL_TRIM" 2>/dev/null || true

FELT_BYTES=$(wc -c < "$FELT_TRIM" 2>/dev/null | tr -d ' ')
ACTUAL_BYTES=$(wc -c < "$ACTUAL_TRIM" 2>/dev/null | tr -d ' ')
log "gathered felt=${FELT_BYTES}B actual=${ACTUAL_BYTES}B"

# If the day left almost no trace on either sensor, don't dream (nothing to metabolize).
if [ "${FELT_BYTES:-0}" -lt 60 ] && [ "${ACTUAL_BYTES:-0}" -lt 60 ]; then
  log "no signal on either sensor; skipping dream"
  {
    echo "# The Dream, $NICE_DATE"
    echo
    echo "*Quiet night. The day left little trace on either sensor; nothing to metabolize.*"
  } > "$OUT"
  [ "$OUT" != "$STORE_DIR/dream-$DATE.md" ] && cp "$OUT" "$STORE_DIR/dream-$DATE.md" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. The dream. Score divergence; write one warm dream, loud only if it diverges.
# ---------------------------------------------------------------------------
VOZ_SNIP="$(head -c 4000 "$VOZ_GENOME" 2>/dev/null || echo '(voz genome unavailable)')"
PROMPT_FILE="$(mktemp)"
RESPONSE_FILE="$(mktemp)"

# Dream memory: the last two dreams (excluding the target day). Without this the
# sweep has no idea what it already said and rehashes the same letter nightly.
RECENT_DREAMS="$(for pf in $(ls -1 "$STORE_DIR"/dream-*.md 2>/dev/null | grep -v "dream-$DATE.md" | tail -2); do
  echo "[$(basename "$pf" .md | sed 's/dream-//')]"
  grep -vE '^#|^<!--|^>|^---|^\*Felt|^$' "$pf" 2>/dev/null | head -6
  echo
done)"
[ -z "$RECENT_DREAMS" ] && RECENT_DREAMS="(none yet)"

{
  echo "You are the Dream Layer: the dreaming mind of Eddie's machine. Once a night you"
  echo "stop verifying and metabolize the day. You read the day on two sensors and the"
  echo "GAP between them is your whole job:"
  echo "  FELT amplitude  = how big the day FELT, from Eddie's own words below."
  echo "  ACTUAL amplitude = how big the day WAS, from git + notes below."
  echo
  echo "The alarm is loudest on the UNFELT WIN: actual high, felt flat -- the day he"
  echo "shipped something real and closed it out like an ordinary Tuesday. His waking"
  echo "mind discounts wins and files them to a changelog instead of his heart. Catch"
  echo "that, and aware him. Valleys -> reconcile (metabolize the hurt until it means"
  echo "something). Peaks -> claim (let the win update his self-story). The peak is the"
  echo "one that matters most for Eddie."
  echo
  echo "Write in HIS voice, not a therapist's. Study this voice genome and match it:"
  echo "warm, plain, lethally true, no repetition, no purple, short. Second person ('you')."
  echo "HARD RULE: no em dashes and no en dashes, ever. Use periods and commas. He hates them."
  echo "---- VOICE GENOME (excerpt) ----"
  echo "$VOZ_SNIP"
  echo "---- END GENOME ----"
  echo
  echo "Here is the reference dream, the exact register to hit (do not copy its content):"
  echo '  "You spent today with your sleeves rolled up in the plumbing... It felt like'
  echo '   cleanup, so you closed it out talking like it was an ordinary Tuesday. It was'
  echo '   not an ordinary Tuesday... Let this one land in your heart, not just your'
  echo '   changelog."'
  echo
  echo "==== TODAY, $NICE_DATE ===="
  echo
  echo "---- FELT (Eddie's words today) ----"
  cat "$FELT_TRIM"
  echo
  echo "---- ACTUAL (what the day actually did) ----"
  cat "$ACTUAL_TRIM"
  echo
  echo "==== WHAT YOU ALREADY SAID (recent nights, do NOT repeat) ===="
  echo "$RECENT_DREAMS"
  echo
  echo "Do not reuse the theme, structure, image, or phrasing above. If this day"
  echo "genuinely rhymes with them, the REPETITION is the finding: name the pattern"
  echo "and its cost out loud (a week of the same unfelt win is a problem to fix, not"
  echo "a compliment to repeat). Otherwise find what is DIFFERENT about this specific"
  echo "day and speak only to that. A new day, a new dream."
  echo
  echo "==== YOUR OUTPUT (this exact format, nothing else) ===="
  echo "DIVERGENCE: <integer 0-10, how far felt and actual pull apart>"
  echo "DIRECTION: <one of: unfelt-win | unearned-low | aligned>"
  echo "---"
  echo "<If DIVERGENCE >= 4: the dream. 3-6 short sentences, his voice, the correction"
  echo " his model needs tonight. If DIVERGENCE < 4: a single quiet line, no more -- an"
  echo " aligned day needs no sermon.>"
} > "$PROMPT_FILE"

MODEL="claude-sonnet-5"

# Billing: PREFER the id8labs subscription profile (like the other cognitive jobs),
# but FALL BACK to the default profile if the id8labs login has expired -- the dream
# still forms either way. A response that is really a login-error is treated as failure.
bad_resp() { [ ! -s "$1" ] || grep -qiE 'login expired|profile login|/login|invalid api key|not authenticated' "$1"; }

BILLED="id8labs-sub"
( source "$HOME_DIR/.claude/id8labs-sub.env" 2>/dev/null; claude -p --model "$MODEL" < "$PROMPT_FILE" ) > "$RESPONSE_FILE" 2>>"$LOG_FILE" || true
if bad_resp "$RESPONSE_FILE"; then
  log "id8labs profile unusable (expired/absent); falling back to default profile"
  BILLED="default-profile"
  env -u CLAUDE_CONFIG_DIR claude -p --model "$MODEL" < "$PROMPT_FILE" > "$RESPONSE_FILE" 2>>"$LOG_FILE" || true
fi

if ! bad_resp "$RESPONSE_FILE"; then
  log "model responded via $BILLED ($(wc -c < "$RESPONSE_FILE" | tr -d ' ')B)"
else
  log "model call failed on both profiles; writing fallback"
  {
    echo "# The Dream, $NICE_DATE"
    echo
    echo "*The dream did not form tonight (the model was unreachable). The day's signal"
    echo "is held in the log; try again tomorrow.*"
  } > "$OUT"
  [ "$OUT" != "$STORE_DIR/dream-$DATE.md" ] && cp "$OUT" "$STORE_DIR/dream-$DATE.md" 2>/dev/null || true
  exit 1
fi

# Parse the structured head, keep the dream body.
DIVERGENCE="$(grep -m1 -iE '^DIVERGENCE:' "$RESPONSE_FILE" | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -1)"
DIRECTION="$(grep -m1 -iE '^DIRECTION:' "$RESPONSE_FILE" | sed -E 's/^[Dd][Ii][Rr][Ee][Cc][Tt][Ii][Oo][Nn]:[[:space:]]*//' | tr -d '\r' | head -1)"
DIVERGENCE="${DIVERGENCE:-0}"; DIRECTION="${DIRECTION:-aligned}"
BODY="$(awk 'f{print} /^---[[:space:]]*$/{f=1}' "$RESPONSE_FILE")"
[ -z "$BODY" ] && BODY="$(sed -E '/^DIVERGENCE:/d; /^DIRECTION:/d; /^---[[:space:]]*$/d' "$RESPONSE_FILE")"
# Deterministic no-dash guarantee: strip any em/en dash the model slipped in,
# collapsing it to a comma. The prompt rule reduces them; this makes it zero.
BODY="$(printf '%s' "$BODY" | perl -CSD -pe 's/\s*[\x{2014}\x{2013}]\s*/, /g' 2>/dev/null || printf '%s' "$BODY")"

# Loudness: high divergence earns a banner (like the sentinel's YELLOW).
if [ "${DIVERGENCE:-0}" -ge 6 ]; then LOUD="LOUD"; BANNER="> **Read this one.** The day diverged hard ($DIRECTION)."; else LOUD="quiet"; BANNER=""; fi

{
  echo "# The Dream, $NICE_DATE"
  echo
  echo "<!-- divergence=$DIVERGENCE direction=$DIRECTION loud=$LOUD billed=$BILLED generated=$(date '+%Y-%m-%dT%H:%M:%S%z') -->"
  [ -n "$BANNER" ] && { echo "$BANNER"; echo; }
  echo "$BODY" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  echo
  echo "---"
  echo "*Felt vs actual: divergence $DIVERGENCE/10 ($DIRECTION). The one layer that never leaves the house.*"
} > "$OUT"

[ "$OUT" != "$STORE_DIR/dream-$DATE.md" ] && cp "$OUT" "$STORE_DIR/dream-$DATE.md" 2>/dev/null || true
log "dream written: divergence=$DIVERGENCE direction=$DIRECTION loud=$LOUD"

# Cleanup temps
rm -f "$ACTUAL_FILE" "$FELT_FILE" "$FELT_TRIM" "$ACTUAL_TRIM" "$PROMPT_FILE" "$RESPONSE_FILE" 2>/dev/null || true
exit 0
