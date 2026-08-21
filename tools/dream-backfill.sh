#!/bin/bash
# dream-backfill.sh - reconstruct dreams for past days into the store.
#
# For each past day it runs the sweep with that date: ACTUAL amplitude is exact
# (git + FIELD_NOTES are date-sliceable); FELT is approximate (transcripts are
# matched by mtime, so a session that spanned days lands on its last day). Good
# enough to read the arc back. Writes ONLY to the store; never touches today's
# DREAM.md and never sends Telegram (no backfill spam).
#
# Usage: dream-backfill.sh [N_days_back]   (default 7)
#        FORCE=1 dream-backfill.sh 7        (redo days already in the store)
set -uo pipefail

HYDRA="$HOME/.hydra"
SWEEP="$HYDRA/tools/dream-sweep.sh"
STORE="$HYDRA/dreams/store"
N="${1:-7}"
FORCE="${FORCE:-0}"
mkdir -p "$STORE"

echo "Backfilling up to $N day(s) into $STORE ..."
for i in $(seq "$N" -1 1); do
  d="$(date -j -v-"${i}"d '+%Y-%m-%d' 2>/dev/null)" || continue
  if [ -f "$STORE/dream-$d.md" ] && [ "$FORCE" != "1" ]; then
    echo "  $d  already stored (skip; FORCE=1 to redo)"
    continue
  fi
  printf "  %s  dreaming... " "$d"
  if bash "$SWEEP" "$d" >/dev/null 2>&1; then
    div="$(grep -o 'divergence=[0-9]*' "$STORE/dream-$d.md" 2>/dev/null | head -1 | cut -d= -f2)"
    echo "done (divergence ${div:-?})"
  else
    echo "FAILED (see logs/dream-sweep.log)"
  fi
done
echo "Done. Read them:  open $STORE"
