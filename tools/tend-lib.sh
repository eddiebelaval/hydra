#!/bin/bash
# tend-lib.sh -- the tend contract, in one sourceable function.
#
# The other half of the showrun mantra: instead of the Gardener inferring a
# system's health from a launchd exit code, a TENDABLE system SELF-REPORTS. It
# writes one small JSON the Gardener aggregates. Three verbs, per the contract:
#   self-report  -- write status + detail (this file's job)
#   self-heal    -- fix your own reversible faults BEFORE reporting; list them
#   escalate     -- name what's yours-to-rule; the Gardener routes it, unchanged
#
# A born-tendable job sources this and calls tend_report once, at the end:
#   source "$HOME/.hydra/tools/tend-lib.sh"
#   tend_report myjob GREEN "42 items processed" 24
# On failure it says so in its OWN lane:
#   tend_report myjob RED "db unreachable" 24 "postgres down" "restart pg / page me"
#
# Writes: ~/.hydra/tend/<system>.json  (the Gardener reads ~/.hydra/tend/*.json)
# No heredocs (feedback_heredoc_avoidance); JSON escaping via python3.

TEND_DIR="${TEND_DIR:-$HOME/.hydra/tend}"

# minimal, correct JSON string encoder (quotes, backslashes, control chars)
_tend_json() {
  printf '%s' "${1:-}" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || printf '"%s"' "${1:-}"
}

# tend_report <system> <GREEN|YELLOW|RED> <detail> [cadence_hours] [escalate_why] [escalate_route] [healed]
#   cadence_hours  optional; if set, the Gardener flags the system when it goes
#                  silent past 1.5x this many hours (a weekly job = 168).
#   escalate_*     optional; a non-empty why routes to Eddie's lane via the tender.
#   healed         optional; one thing the system fixed itself this run (credited).
tend_report() {
  # NB: 'status' is a read-only special in zsh -- use 'st' so the lib is safe to
  # source from any shell, not just the #!/bin/bash jobs that call it.
  local system="$1" st="$2" detail="${3:-}" cadence="${4:-}" \
        esc_why="${5:-}" esc_route="${6:-}" healed="${7:-}"
  [ -n "$system" ] && [ -n "$st" ] || return 0
  mkdir -p "$TEND_DIR" 2>/dev/null || return 0
  local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"        # local naive, matches the ledger
  local esc="[]" heal="[]" cad="null"
  [ -n "$esc_why" ] && esc="[{\"why\":$(_tend_json "$esc_why"),\"route\":$(_tend_json "$esc_route")}]"
  [ -n "$healed" ] && heal="[$(_tend_json "$healed")]"
  [ -n "$cadence" ] && cad="$cadence"
  printf '{"system":%s,"asOf":%s,"status":%s,"detail":%s,"cadenceHours":%s,"selfHealed":%s,"escalate":%s}\n' \
    "$(_tend_json "$system")" "$(_tend_json "$ts")" "$(_tend_json "$st")" \
    "$(_tend_json "$detail")" "$cad" "$heal" "$esc" \
    > "$TEND_DIR/$system.json" 2>/dev/null || true
}
