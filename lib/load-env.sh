#!/bin/bash
# load-env.sh — Environment variable extraction from .env files
#
# Handles: KEY=value, export KEY=value, KEY="value", KEY='value'

# Load a single variable from a .env file
# Usage: VALUE=$(load_env_var "/path/to/.env" "KEY_NAME")
load_env_var() {
    local file="$1" key="$2"
    [[ ! -f "$file" ]] && echo "" && return
    grep -E "^(export )?${key}=" "$file" 2>/dev/null \
        | head -1 \
        | sed 's/^export //' \
        | cut -d'=' -f2- \
        | sed "s/^['\"]//;s/['\"]$//"
}

# Require an env file to exist, exit with error if missing
# Usage: require_env_file "/path/to/.env"
require_env_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log "ERROR: Required env file not found: $file"
        exit 1
    fi
}
