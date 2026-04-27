#!/bin/bash
# repos.sh -- Single source of truth for HYDRA-monitored repos
#
# Format: "DisplayName|RepoPath|MCSlug"
#   - MCSlug is empty for repos without a Mission Control product mapping
#   - Source this file from any daemon that needs the repo list
#
# Usage:
#   source "$HOME/.hydra/config/repos.sh"
#   for entry in "${HYDRA_REPOS[@]}"; do
#       repo_name="${entry%%|*}"
#       repo_path=$(echo "$entry" | cut -d'|' -f2)
#       mc_slug="${entry##*|}"
#   done

HYDRA_REPOS=(
    "Homer|$HOME/Development/Homer|homer"
    "Parallax|$HOME/Development/id8/products/parallax|parallax"
    "Rune|$HOME/Development/id8/products/rune|rune"
    "Lexicon|$HOME/Development/id8/lexicon|lexicon"
    "id8Labs Site|$HOME/Development/id8/id8labs|"
    "Kalshi Bot|$HOME/clawd/projects/kalshi-trading|deepstack"
    "DeepStack TV|$HOME/Development/deepstack-tradingview|"
    "Consciousness|$HOME/Development/consciousness-framework|consciousness-framework"
    "Claude Code Sounds|$HOME/Development/claude-code-sounds|claude-code-sounds"
    "Speak2|$HOME/Development/Speak2|"
    "Mission Control|$HOME/Development/mission-control|mission-control"
    "MILO|$HOME/Development/id8/products/milo|milo"
    "DeepStack|$HOME/Development/id8/products/deepstack|deepstack"
    "Vox|$HOME/Development/id8/products/vox|"
    "Axis|$HOME/Development/id8/products/axis|"
    "Pause|$HOME/Development/id8/products/pause|pause"
    "Tool Factory|$HOME/Development/id8/tool-factory|"
    "MemPalace|$HOME/Development/mempalace|"
)

MC_CLI="$HOME/Development/mission-control/bin/mc"

# parse_repo ENTRY -- sets REPO_NAME, REPO_PATH, MC_SLUG
parse_repo() {
    REPO_NAME="${1%%|*}"
    REPO_PATH=$(echo "$1" | cut -d'|' -f2)
    MC_SLUG="${1##*|}"
}

# push_mc_signals SIGNAL_TYPE TTL_HOURS MESSAGE_PREFIX SINCE
#   Iterates HYDRA_REPOS, pushes MC signals for repos with activity.
#   Accepts optional COMMIT_CACHE_DIR to skip re-scanning git.
push_mc_signals() {
    local signal_type="$1" ttl="$2" msg_prefix="$3" since="$4"
    local cache_dir="${5:-}"

    if [[ ! -x "$MC_CLI" ]]; then return; fi

    for entry in "${HYDRA_REPOS[@]}"; do
        parse_repo "$entry"
        [[ -z "$MC_SLUG" ]] && continue

        local commit_count=""
        local latest=""

        if [[ -n "$cache_dir" ]] && [[ -f "$cache_dir/$REPO_NAME.count" ]]; then
            commit_count=$(cat "$cache_dir/$REPO_NAME.count")
            latest=$(cat "$cache_dir/$REPO_NAME.latest" 2>/dev/null || echo "")
        elif [[ -d "$REPO_PATH/.git" ]]; then
            commit_count=$(git -C "$REPO_PATH" log --oneline --since="$since" --max-count=20 2>/dev/null | wc -l | tr -d ' ')
            latest=$(git -C "$REPO_PATH" log --oneline -1 2>/dev/null | cut -c9-)
        fi

        if [[ -n "$commit_count" ]] && [[ "$commit_count" -gt 0 ]]; then
            "$MC_CLI" signal "$MC_SLUG" "$signal_type" --source hydra --ttl "$ttl" \
                "$msg_prefix $commit_count commits${latest:+ (latest: $latest)}" 2>/dev/null || true
        fi
    done
}
