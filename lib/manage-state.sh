#!/bin/bash
# manage-state.sh — JSON state file read/write utilities
#
# Common pattern across HYDRA daemons: track last_sync, sync_count, etc.
# Uses Python for JSON manipulation (bash has no native JSON support).

# Read a single value from a JSON state file
# Usage: LAST_SYNC=$(read_state "$STATE_FILE" "last_sync")
read_state() {
    local state_file="$1" key="$2"
    python3 -c "
import json
try:
    with open('${state_file}') as f:
        print(json.load(f).get('${key}', ''))
except (IOError, json.JSONDecodeError, FileNotFoundError):
    print('')
" 2>/dev/null
}

# Update a JSON state file with key=value pairs
# Supports += suffix for incrementing numeric values
# Usage: update_state "$STATE_FILE" "last_sync=2026-03-13" "sync_count+=1"
update_state() {
    local state_file="$1"
    shift
    python3 - "$state_file" "$@" << 'PYEOF'
import json, sys, os

state_file = sys.argv[1]
updates = {}
increments = []

for arg in sys.argv[2:]:
    if '+=' in arg:
        key, _ = arg.split('+=', 1)
        increments.append(key)
    elif '=' in arg:
        key, val = arg.split('=', 1)
        updates[key] = val

try:
    with open(state_file) as f:
        state = json.load(f)
except (IOError, json.JSONDecodeError, FileNotFoundError):
    state = {}

state.update(updates)
for key in increments:
    state[key] = state.get(key, 0) + 1

os.makedirs(os.path.dirname(os.path.abspath(state_file)), exist_ok=True)
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}
