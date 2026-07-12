#!/bin/bash
# daily-briefing.sh - Morning Briefing (v2, living sensors)
# Runs: 8:40 AM daily (after sync at 8:30, standup at 8:35)
#
# v2 (2026-07-12): HYDRA v1 work layer retired (see ~/.hydra/retired/RETIRED-2026-07-11.md).
# All gathering now lives in briefing-instrument.py, which reads LIVING sensors only:
# the atlas wire (id8-halos client atlases), the launchd fleet (exit codes), and
# hydra.db daily_priorities (the one v1 loop kept alive on purpose). This script
# just runs the generator, opens the instrument, and notifies with its summary.
# The old markdown assembled from dead tables (agents/tasks/notifications) is gone;
# the generator writes the markdown twin from the same living data.

set -euo pipefail

HYDRA_BASE="$HOME/.hydra"
BRIEFING_DIR="$HYDRA_BASE/briefings"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
BRIEFING_FILE="$BRIEFING_DIR/briefing-$DATE.md"
SUMMARY_FILE="$BRIEFING_DIR/briefing-summary.txt"

mkdir -p "$BRIEFING_DIR"

# ============================================================================
# GENERATE (instrument HTML + markdown twin + notification summary)
# ============================================================================

INSTRUMENT_FILE=$(python3 "$HYDRA_BASE/daemons/briefing-instrument.py" || echo "")

if [[ -n "$INSTRUMENT_FILE" && -f "$INSTRUMENT_FILE" ]]; then
    echo "Briefing generated: $INSTRUMENT_FILE"
    open "$INSTRUMENT_FILE"
    echo "Opened the Morning Instrument"
elif [[ -f "$BRIEFING_FILE" ]]; then
    # generator failed but an earlier markdown exists: open it rather than nothing
    open "$BRIEFING_FILE"
    echo "Instrument generation FAILED; opened markdown fallback" >&2
else
    echo "Instrument generation FAILED and no markdown twin exists" >&2
    ~/.hydra/daemons/notify-eddie.sh urgent "Morning Briefing BROKEN" \
        "briefing-instrument.py produced nothing for $DATE. The morning has no instrument." || true
    exit 1
fi

# ============================================================================
# NOTIFY (priority + message written by the generator, from the same sensors)
# ============================================================================

PRIORITY="normal"
MESSAGE="Morning Instrument ready - $DAY_NAME"
if [[ -f "$SUMMARY_FILE" ]]; then
    PRIORITY=$(head -1 "$SUMMARY_FILE" | sed 's/^PRIORITY://')
    MESSAGE=$(tail -n +2 "$SUMMARY_FILE")
    case "$PRIORITY" in urgent|high|normal) ;; *) PRIORITY="normal" ;; esac
fi

~/.hydra/daemons/notify-eddie.sh "$PRIORITY" "Morning Instrument" "$MESSAGE" "$INSTRUMENT_FILE" || true

echo "Morning Instrument: priority=$PRIORITY"
