#!/bin/bash
# template-tendable-job.sh -- copy me to start a job that is BORN TENDABLE.
# Rename SYSTEM, fill in the work, keep the three verbs. See TEND-CONTRACT.md.
set -uo pipefail

SYSTEM="my-job"          # <- rename: becomes ~/.hydra/tend/<SYSTEM>.json
CADENCE_HOURS=24         # <- how often you run (daily=24, weekly=168; "" to opt out)

source "$HOME/.hydra/tools/tend-lib.sh"

# Report whatever we know on ANY exit, so a mid-run death still self-reports.
HEALED=""; ESC_WHY=""; ESC_ROUTE=""; STATUS="GREEN"; DETAIL="nominal"
report() { tend_report "$SYSTEM" "$STATUS" "$DETAIL" "$CADENCE_HOURS" "$ESC_WHY" "$ESC_ROUTE" "$HEALED"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && { STATUS="RED"; DETAIL="exited $rc -- ${DETAIL}"; }; report' EXIT

# 1) self-heal: fix your own reversible faults first.
#    e.g. mkdir -p "$WORK_DIR" && HEALED="recreated work dir"

# 2) do the work. Set DETAIL to a one-line summary as you go.
#    On a degraded-but-running condition: STATUS="YELLOW"; DETAIL="..."
#    On something only Eddie can rule: ESC_WHY="..."; ESC_ROUTE="..."
DETAIL="did the thing"

# 3) the EXIT trap self-reports. Nothing else to do.
