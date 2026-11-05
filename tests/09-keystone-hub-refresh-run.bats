#!/usr/bin/env bats
# keystone-hub-refresh-run: the runner must never call the refresh on a bad source, must alert once,
# and must hand the refresh a clean origin/main worktree plus the working-copy board.

RUNNER="$HOME/.hydra/tools/keystone-hub-refresh-run.sh"

setup() {
  S="$(mktemp -d)"
  git init -q --bare "$S/origin.git"
  git clone -q "$S/origin.git" "$S/seed" 2>/dev/null
  mkdir -p "$S/seed/tasks" "$S/seed/tools"
  echo '{"old": true}' > "$S/seed/tasks/INTERNAL-TASKS.json"
  echo 'v1' > "$S/seed/code.txt"
  git -C "$S/seed" add -A
  git -C "$S/seed" -c user.email=t@t -c user.name=t commit -q -m seed
  git -C "$S/seed" push -q origin HEAD:main 2>/dev/null
  git -C "$S/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$S/origin.git" "$S/wt" 2>/dev/null
  # Stub refresh: records that it ran, with which KS and which board.
  cat > "$S/refresh.sh" <<EOF
#!/bin/bash
echo "ran KS=\$KS board=\$(cat \$KS/tasks/INTERNAL-TASKS.json) code=\$(cat \$KS/code.txt)" >> "$S/calls"
exit \${STUB_RC:-0}
EOF
  cat > "$S/synapse" <<EOF
#!/bin/bash
echo call >> "$S/alerts"; echo "\$*" >> "$S/alerts.full"
EOF
  chmod +x "$S/refresh.sh" "$S/synapse"
  echo '{"new": true}' > "$S/board.json"
  export HUB_REFRESH_WT="$S/wt" KS_BOARD="$S/board.json" LOG="$S/log" SYNAPSE="$S/synapse" \
         HUB_REFRESH_SCRIPT="$S/refresh.sh" RUNLOCK="$S/lock" ALERT_STATE="$S/last-alert"
  unset DRY_RUN
}

teardown() { rm -rf "$S"; }

@test "good run: refresh gets origin/main code and the working-copy board" {
  echo 'v2' > "$S/seed/code.txt"
  git -C "$S/seed" -c user.email=t@t -c user.name=t commit -qam v2
  git -C "$S/seed" push -q origin HEAD:main 2>/dev/null
  echo 'local junk' > "$S/wt/code.txt"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  grep -q 'board={"new": true} code=v2' "$S/calls"
  [ ! -e "$S/alerts" ]
  [ ! -d "$S/lock" ]
}

@test "invalid board: exit 1, FAIL logged, refresh never called, one alert" {
  printf '{broken' > "$S/board.json"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  grep -q 'FAIL board is not valid JSON' "$S/log"
  [ ! -e "$S/calls" ]
  [ "$(wc -l < "$S/alerts")" -eq 1 ]
  grep -q 'What to do' "$S/alerts.full"
  [ ! -d "$S/lock" ]
}

@test "missing board: exit 1, refresh never called" {
  rm "$S/board.json"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  grep -q 'FAIL board missing' "$S/log"
  [ ! -e "$S/calls" ]
}

@test "missing worktree: exit 1, refresh never called" {
  export HUB_REFRESH_WT="$S/nowhere" HUB_REFRESH_SCRIPT="$S/refresh.sh"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  grep -q 'FAIL worktree missing' "$S/log"
  [ ! -e "$S/calls" ]
}

@test "same failure twice alerts once; a different failure alerts again" {
  printf '{broken' > "$S/board.json"
  run "$RUNNER"; run "$RUNNER"
  [ "$(wc -l < "$S/alerts")" -eq 1 ]
  rm "$S/board.json"
  run "$RUNNER"
  [ "$(wc -l < "$S/alerts")" -eq 2 ]
}

@test "refresh failure alerts; a later success clears the alert state" {
  STUB_RC=3 run "$RUNNER"
  [ "$status" -eq 1 ]
  grep -q 'FAIL hub-refresh.sh exit 3' "$S/log"
  [ -f "$S/last-alert" ]
  run "$RUNNER"
  [ "$status" -eq 0 ]
  [ ! -f "$S/last-alert" ]
}

@test "dry run never alerts" {
  printf '{broken' > "$S/board.json"
  DRY_RUN=1 run "$RUNNER"
  [ "$status" -eq 1 ]
  [ ! -e "$S/alerts" ]
}

@test "held lock: second run skips without calling refresh" {
  mkdir "$S/lock"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  grep -q 'skipping' "$S/log"
  [ ! -e "$S/calls" ]
}

@test "stale lock (over 2 h) is cleared and the run proceeds" {
  mkdir "$S/lock"
  touch -t 202001010000 "$S/lock"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  grep -q 'cleared a stale run lock' "$S/log"
  [ -e "$S/calls" ]
}
