#!/usr/bin/env bats
# insights-cycle Phase 1 (fixed 2026-11-05): /insights must analyze the MAIN account's sessions, be billed
# to the id8labs token (never the personal login), and a missing or stale report must stop the cycle with
# an alert BEFORE Phase 2 internalizes anything. Runs the real script against a fake HOME with stubs.

SCRIPT="$HOME/.hydra/daemons/insights-cycle.sh"

setup() {
  S="$(mktemp -d)"
  H="$S/home"
  mkdir -p "$H/.hydra/daemons" "$H/.hydra/bin" "$H/.hydra/tools" "$H/.claude/projects/p" "$H/.claude/usage-data" "$H/.claude/skills/x" \
           "$H/.claude-id8labs/usage-data" "$S/bin"
  echo '{}' > "$H/.claude/projects/p/s.jsonl"
  echo 'old' > "$H/.claude/usage-data/report.html"
  touch -t 202010150900 "$H/.claude/usage-data/report.html"
  # notify stub records alerts
  printf '#!/bin/bash\necho "$1|$2|$3" >> "%s/notify"\n' "$S" > "$H/.hydra/daemons/notify-eddie.sh"
  printf '#!/bin/bash\necho test-model\n' > "$H/.hydra/bin/hydra-llm"
  printf 'tend_report() { :; }\n' > "$H/.hydra/tools/tend-lib.sh"
  # loader stub: like the real one, points at the id8labs dir and exports a token (unless NO_TOKEN)
  cat > "$H/.claude/id8labs-sub.env" <<EOF
export CLAUDE_CONFIG_DIR="\$HOME/.claude-id8labs"
[ "\${NO_TOKEN:-0}" = "1" ] || export CLAUDE_CODE_OAUTH_TOKEN=test-token
EOF
  # claude stub. Phase 1 (/insights): records its env and writes a report where MODE says; phase 2: records a call.
  cat > "$S/bin/claude" <<EOF
#!/bin/bash
if [ "\$3" = "/insights" ] || [ "\$4" = "/insights" ]; then
  echo "cfg=\$CLAUDE_CONFIG_DIR tok=\${CLAUDE_CODE_OAUTH_TOKEN:-none} projects=\$(readlink "\$CLAUDE_CONFIG_DIR/projects") creds=\$(ls -A "\$CLAUDE_CONFIG_DIR" | tr '\n' ,)" >> "$S/p1"
  case "\${MODE:-good}" in
    good) f="\$CLAUDE_CONFIG_DIR/usage-data/report-new.html"; echo new > "\$f"; echo "Your report: file://\$(echo "\$f" | tr -s /)" ;;  # real claude prints a normalized path
    realpath) f="$H/.claude/usage-data/report-real.html"; echo new > "\$f"; echo "Your report: file://\$f" ;;
    elsewhere) f="$H/.claude-id8labs/usage-data/report-x.html"; echo new > "\$f"; echo "Your report: file://\$f" ;;
    stale) echo "Your report: file://$H/.claude/usage-data/report.html" ;;
    silent) echo "done" ;;
  esac
  exit 0
fi
echo "phase2 \$*" >> "$S/p2"
EOF
  chmod +x "$S/bin/claude" "$H/.hydra/daemons/notify-eddie.sh" "$H/.hydra/bin/hydra-llm"
  cp "$SCRIPT" "$H/.hydra/daemons/insights-cycle.sh"
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/sqlite3"; chmod +x "$S/bin/sqlite3"
}

teardown() { rm -rf "$S"; }

runit() { run env HOME="$H" PATH="$S/bin:/usr/bin:/bin" TMPDIR="$S" "$@" /bin/bash "$H/.hydra/daemons/insights-cycle.sh"; }

@test "good run: /insights reads MAIN sessions with only the id8labs token, then Phase 2 reads the fresh report" {
  runit MODE=good
  [ "$status" -eq 0 ]
  grep -q "tok=test-token" "$S/p1"
  grep -q "projects=$H/.claude/projects" "$S/p1"
  ! grep -q "cfg=$H/.claude-id8labs" "$S/p1"
  grep -q "creds=projects,usage-data," "$S/p1"   # nothing else in the config dir: no stored login to fall back to
  [ -f "$H/.claude/usage-data/report-new.html" ]
  grep -q "report-new.html" "$S/p2"
  ! grep -q "|Phase 1 failed" "$S/notify"
  [ -z "$(ls "$S" | grep insights-p1)" ]          # temp config dir removed
}

@test "a TMPDIR ending in / (macOS default) still maps the printed report path" {
  run env HOME="$H" PATH="$S/bin:/usr/bin:/bin" TMPDIR="$S/" MODE=good /bin/bash "$H/.hydra/daemons/insights-cycle.sh"
  [ "$status" -eq 0 ]
  grep -q "report-new.html" "$S/p2"
}

@test "report path printed as the real folder is accepted" {
  runit MODE=realpath
  [ "$status" -eq 0 ]
  grep -q "report-real.html" "$S/p2"
}

@test "report written to the id8labs folder stops the cycle before Phase 2, with an alert" {
  runit MODE=elsewhere
  [ "$status" -eq 1 ]
  [ ! -e "$S/p2" ]
  grep -q "high|Insights Cycle|Phase 1 failed: report written outside the main usage-data folder" "$S/notify"
}

@test "stale report (the Oct 15 file) stops the cycle before Phase 2" {
  runit MODE=stale
  [ "$status" -eq 1 ]
  [ ! -e "$S/p2" ]
  grep -q "older than this run (stale)" "$S/notify"
}

@test "no report path printed stops the cycle" {
  runit MODE=silent
  [ "$status" -eq 1 ]
  [ ! -e "$S/p2" ]
  grep -q "printed no report path" "$S/notify"
}

@test "no id8labs token: refuses to run /insights at all (never bills the personal login)" {
  runit NO_TOKEN=1
  [ "$status" -eq 1 ]
  [ ! -e "$S/p1" ]
  grep -q "no id8labs token" "$S/notify"
}

@test "PHASE1_ONLY stops after a verified report" {
  runit MODE=good PHASE1_ONLY=1
  [ "$status" -eq 0 ]
  [ ! -e "$S/p2" ]
  grep -q "report-new.html" "$H/Library/Logs/claude-automation/hydra-insights-cycle/insights-cycle-"*.log
}
