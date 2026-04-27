#!/bin/bash
# hydra-self-enrich.sh - HYDRA Self-Enrichment Daemon
#
# Runs daily at 7:00 AM. Analyzes Milo's conversation history,
# memories, and system state to derive operational insights
# for HYDRA's routing intelligence.
#
# Fires BEFORE the morning planner (8 AM) so routing has fresh patterns.
# Follows the HYDRA daemon pattern: independent, self-recoverable.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
ROUTER_DIR="$HYDRA_ROOT/tools/hydra-router"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-self-enrich"
LOG_FILE="$LOG_DIR/enrich-$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Starting HYDRA self-enrichment..."

# Check prerequisites
if [[ ! -d "$ROUTER_DIR/node_modules" ]]; then
    log "ERROR: hydra-router not installed. Run npm install in $ROUTER_DIR"
    exit 1
fi

if [[ ! -f "$HYDRA_ROOT/hydra.db" ]]; then
    log "ERROR: hydra.db not found"
    exit 1
fi

# Run enrichment
export HYDRA_DB="$HYDRA_ROOT/hydra.db"
export HOME="$HOME"

# Pin Node.js version: prefer nvm v22 (matches native module build),
# fall back to /usr/local, then homebrew
if [[ -d "$HOME/.nvm/versions/node" ]]; then
    NODE_DIR=$(ls -d "$HOME"/.nvm/versions/node/v22.* 2>/dev/null | sort -V | tail -1)
    if [[ -n "$NODE_DIR" ]]; then
        export PATH="$NODE_DIR/bin:$PATH"
    fi
fi
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

log "Using node: $(which node) ($(node -v))"

cd "$ROUTER_DIR"

if node --import tsx/esm src/seed-memories.ts >> "$LOG_FILE" 2>&1; then
    log "Enrichment completed successfully"
else
    log "ERROR: Enrichment failed (exit code $?)"
    exit 1
fi

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "enrich-*.log" -mtime +30 -delete 2>/dev/null || true

log "Done."
