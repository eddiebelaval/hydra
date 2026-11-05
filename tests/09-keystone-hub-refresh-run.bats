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
echo "ran KS=\$KS board=\$(head -c 13 \$KS/tasks/INTERNAL-TASKS.json) code=\$(cat \$KS/code.txt)" >> "$S/calls"
exit \${STUB_RC:-0}
EOF
  cat > "$S/synapse" <<EOF
#!/bin/bash
echo call >> "$S/alerts"; echo "\$*" >> "$S/alerts.full"
EOF
  cat > "$S/notify" <<EOF
#!/bin/bash
echo "\$1" >> "$S/phone"
EOF
  chmod +x "$S/refresh.sh" "$S/synapse" "$S/notify"
  echo '{"new": true, "tasks": [1, 2, 3]}' > "$S/board.json"
  export HUB_REFRESH_WT="$S/wt" KS_BOARD="$S/board.json" LOG="$S/log" SYNAPSE="$S/synapse" \
         HUB_REFRESH_SCRIPT="$S/refresh.sh" RUNLOCK="$S/lock" ALERT_STATE="$S/last-alert" \
         NOTIFY="$S/notify" MIN_TASKS=3
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
  grep -q 'board={"new": true, code=v2' "$S/calls"
  [ ! -e "$S/alerts" ]
  [ ! -e "$S/phone" ]
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
  [ "$(wc -l < "$S/phone")" -eq 1 ]
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
  grep -q 'recovered' "$S/phone"
  grep -q 'Hub refresh recovered' "$S/alerts.full"
  run "$RUNNER"
  [ "$(grep -c recovered "$S/phone")" -eq 1 ]
}

@test "dry run never alerts" {
  printf '{broken' > "$S/board.json"
  DRY_RUN=1 run "$RUNNER"
  [ "$status" -eq 1 ]
  [ ! -e "$S/alerts" ]
  [ ! -e "$S/phone" ]
}

@test "valid but thin board (under MIN_TASKS) stops before publishing" {
  echo '{"tasks": [1]}' > "$S/board.json"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  grep -q 'FAIL board has 1 tasks, under the 3 minimum' "$S/log"
  [ ! -e "$S/calls" ]
  echo '[]' > "$S/board.json"
  run "$RUNNER"
  [ "$status" -eq 1 ]
  [ ! -e "$S/calls" ]
}

@test "held lock: second run skips without calling refresh" {
  mkdir "$S/lock"
  echo $$ > "$S/lock/pid"
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

@test "old lock whose owner is still alive is never taken over" {
  mkdir "$S/lock"
  echo $$ > "$S/lock/pid"
  touch -t 202001010000 "$S/lock"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  grep -q 'skipping' "$S/log"
  [ ! -e "$S/calls" ]
}

@test "lock just under 2 h with a dead owner is not cleared" {
  mkdir "$S/lock"
  echo 999999 > "$S/lock/pid"
  touch -t "$(date -v-7140S +%Y%m%d%H%M.%S)" "$S/lock"
  run "$RUNNER"
  [ "$status" -eq 0 ]
  grep -q 'skipping' "$S/log"
  [ ! -e "$S/calls" ]
}
