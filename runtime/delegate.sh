#!/bin/bash
# delegate.sh -- Bash wrapper for HYDRA delegation API
# Usage: delegate.sh <parent-run-id> <target-agent> <title> [payload-json]
set -euo pipefail

PARENT_RUN_ID="${1:?Usage: delegate.sh <parent-run-id> <agent> <title> [payload]}"
TARGET_AGENT="${2:?}"
TITLE="${3:?}"
PAYLOAD="${4:-{}}"

/usr/bin/python3 "$HOME/.hydra/runtime/delegate.py" "$PARENT_RUN_ID" "$TARGET_AGENT" "$TITLE" "$PAYLOAD"
