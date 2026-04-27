#!/bin/bash
# milo-heartbeat.sh - Milo Proactive Intelligence Layer
#
# Wrapper script that sources credentials and runs the heartbeat TypeScript.
# Runs every 30 minutes via launchd.

set -euo pipefail

HYDRA_ROOT="$HOME/.hydra"
RESPONDER="$HYDRA_ROOT/tools/milo-respond"
LOG_FILE="$HOME/Library/Logs/claude-automation/milo-telegram/heartbeat.log"

mkdir -p "$(dirname "$LOG_FILE")"

# Load credentials
source "$HYDRA_ROOT/config/telegram.env"
source "$HYDRA_ROOT/config/milo-telegram.env"

# Export for the TypeScript heartbeat
export ANTHROPIC_API_KEY
export HYDRA_DB="$HYDRA_ROOT/hydra.db"
export MILO_TELEGRAM_BOT_TOKEN
export MILO_TELEGRAM_CHAT_ID
export MILO_CHAT_MODEL="${MILO_CHAT_MODEL:-claude-sonnet-4-20250514}"

cd "$RESPONDER"
node --import tsx/esm src/heartbeat.ts 2>>"$LOG_FILE"
