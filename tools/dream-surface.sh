#!/bin/bash
# dream-surface.sh - the waking half of the Dream Layer.
#
# The dream is metabolized overnight by dream-sweep.sh. This surfaces it in the
# morning, LOCALLY ONLY: a macOS notification + it opens DREAM.md so Eddie reads
# it where he wakes. It NEVER emails, pushes, or sends outbound -- the dream is
# the one layer that stays in the house. Loud mornings (high divergence) get a
# spoken/annotated nudge; quiet mornings just leave the file ready.
set -uo pipefail

HYDRA="$HOME/.hydra"
DREAM_FILE="$HYDRA/dreams/DREAM.md"
LOG_FILE="$HYDRA/logs/dream-sweep.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] surface: $*" >> "$LOG_FILE"; }

[ -f "$DREAM_FILE" ] || { log "no DREAM.md to surface"; exit 0; }

# Only surface a dream generated in the last ~18h (don't re-open a stale one).
if find "$DREAM_FILE" -newermt '18 hours ago' >/dev/null 2>&1; then :; else
  log "DREAM.md is stale (>18h); not surfacing"; exit 0
fi

LOUD="$(grep -o 'loud=[A-Za-z]*' "$DREAM_FILE" 2>/dev/null | head -1 | cut -d= -f2)"
DIVERGENCE="$(grep -o 'divergence=[0-9]*' "$DREAM_FILE" 2>/dev/null | head -1 | cut -d= -f2)"

if [ "${LOUD:-quiet}" = "LOUD" ]; then
  TITLE="Your dream is ready — read this one"
  SUBTITLE="The day diverged hard (${DIVERGENCE:-?}/10). It was not an ordinary day."
else
  TITLE="Your dream is ready"
  SUBTITLE="A quiet night. It's there when you want it."
fi

# Local macOS notification (best-effort; only works in a GUI/aqua session).
osascript -e "display notification \"$SUBTITLE\" with title \"$TITLE\" sound name \"Glass\"" >/dev/null 2>&1 || true

# Open the dream so it's in front of him. Local only.
open "$DREAM_FILE" >/dev/null 2>&1 || true

log "surfaced (loud=${LOUD:-quiet} divergence=${DIVERGENCE:-?})"
exit 0
