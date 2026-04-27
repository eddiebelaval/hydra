#!/bin/bash
# HYDRA Lab Sweep — Monthly arena sweep for Parallax Lab page
# Runs all 180 scenarios through Ava's analysis pipeline and updates public/lab/data.json
#
# Requires: ANTHROPIC_API_KEY in .env.local
# Cost: ~$20-50 per sweep (1,080 API calls)
# Duration: ~15-30 minutes

set -euo pipefail

PARALLAX_DIR="$HOME/Development/id8/products/parallax"
LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-lab-sweep"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="$LOG_DIR/sweep-$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== HYDRA Lab Sweep starting ==="
log "Directory: $PARALLAX_DIR"

# Load env vars
if [ -f "$PARALLAX_DIR/.env.local" ]; then
  export $(grep -v '^#' "$PARALLAX_DIR/.env.local" | grep ANTHROPIC_API_KEY | xargs)
  log "Loaded ANTHROPIC_API_KEY from .env.local"
else
  log "ERROR: No .env.local found"
  exit 1
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  log "ERROR: ANTHROPIC_API_KEY not set"
  exit 1
fi

cd "$PARALLAX_DIR"

# Ensure we're on dev branch and up to date
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "dev" ]; then
  log "WARNING: Not on dev branch (on $CURRENT_BRANCH). Switching to dev."
  git checkout dev
fi
git pull --ff-only origin dev 2>&1 | tee -a "$LOG_FILE"

# Run the sweep
LABEL="Monthly sweep $(date +%Y-%m-%d)"
log "Running sweep with label: $LABEL"
npx tsx scripts/lab-sweep.ts --label "$LABEL" 2>&1 | tee -a "$LOG_FILE"

# Check if data.json actually changed
if git diff --quiet public/lab/data.json; then
  log "No changes to data.json — sweep produced identical results"
  exit 0
fi

# Commit and push the updated data
git add public/lab/data.json
git commit -m "[Meta] data: monthly Lab sweep — $(date +%Y-%m-%d)

Co-Authored-By: HYDRA <noreply@id8labs.app>"

git push origin dev 2>&1 | tee -a "$LOG_FILE"

log "=== HYDRA Lab Sweep complete ==="
log "Results committed and pushed to dev"
