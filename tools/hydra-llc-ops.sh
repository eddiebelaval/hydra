#!/bin/bash
# hydra-llc-ops.sh - Bridge: HYDRA Telegram -> llc-ops-cli.sh
#
# Called by telegram-listener.sh dispatch for "llc:" commands.
# Maps Telegram arguments to llc-ops-cli.sh commands.
#
# Usage: hydra-llc-ops.sh <command> [args...]
#
# Commands:
#   status              Dashboard
#   deadlines / list    Full deadline list
#   complete <id>       Mark done
#   snooze <id> <days>  Snooze reminder
#   detail <id>         Full detail
#   docs                List documents
#   add "title" cat date  Add deadline
#   help                Command reference

set -euo pipefail

LLC_CLI="$HOME/.llc-ops/scripts/llc-ops-cli.sh"

if [[ ! -x "$LLC_CLI" ]]; then
    echo "LLC-Ops CLI not found. Run llc-ops-init.sh first."
    exit 1
fi

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    status|s)
        "$LLC_CLI" status
        ;;
    deadlines|list|l)
        "$LLC_CLI" deadlines
        ;;
    complete|done)
        "$LLC_CLI" complete "$@"
        ;;
    snooze)
        "$LLC_CLI" snooze "$@"
        ;;
    detail|d)
        "$LLC_CLI" detail "$@"
        ;;
    docs)
        "$LLC_CLI" docs
        ;;
    add)
        "$LLC_CLI" add "$@"
        ;;
    help|h|*)
        echo "LLC-Ops via Telegram:"
        echo ""
        echo "  llc: status       - Dashboard"
        echo "  llc: deadlines    - All deadlines"
        echo "  llc: detail <id>  - Full info"
        echo "  llc: complete <id>- Mark done"
        echo "  llc: snooze <id> <days>"
        echo "  llc: docs         - Documents"
        echo "  llc: help         - This help"
        echo ""
        echo "IDs: first 4+ chars of UUID"
        ;;
esac
