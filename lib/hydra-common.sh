#!/bin/bash
# hydra-common.sh — Shared HYDRA daemon utilities
# Source this at the top of every daemon script, after set -euo pipefail.
#
# Provides: HYDRA_ROOT, HYDRA_DB, NOTIFY, HYDRA_LIB, log()
# Requires: LOG_FILE must be set by the daemon AFTER sourcing this file,
#           but BEFORE calling log() or any sub-library function.
#
# Sub-libraries sourced automatically:
#   load-env.sh    — load_env_var(), require_env_file()
#   manage-state.sh — read_state(), update_state()
#   log-activity.sh — log_activity()

HYDRA_ROOT="$HOME/.hydra"
HYDRA_DB="$HYDRA_ROOT/hydra.db"
NOTIFY="$HYDRA_ROOT/daemons/notify-eddie.sh"
HYDRA_LIB="$HYDRA_ROOT/lib"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

source "$HYDRA_LIB/load-env.sh"
source "$HYDRA_LIB/manage-state.sh"
source "$HYDRA_LIB/log-activity.sh"
