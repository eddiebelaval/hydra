#!/bin/bash
# craft-retro-capture.sh -- PostToolUse:Task hook.
# When a craft-loop agent (voz|faro|video|90day-beats) is spawned, record a
# delivery so the RETRO trigger can surface "RETRO due" in the briefing.
# The Attunement Law stays intact: this only SURFACES the reminder; the human
# runs the RETRO (only human signal updates the genome). Deterministic, no net.
set -uo pipefail
IN=$(cat 2>/dev/null)
TYPE=$(printf '%s' "$IN" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ':' '-')
case "$TYPE" in
  voz|faro|video|90day-beats) : ;;
  *) exit 0 ;;
esac
DIR="$HOME/.hydra/sensors/craft-retro"; mkdir -p "$DIR"
printf '{"ts":"%s","loop":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TYPE" >> "$DIR/deliveries.jsonl"
exit 0
