#!/usr/bin/env bats
# ops-runner-refresh.sh in a sandbox: HOME is a temp dir holding a bare "origin", the main
# checkout and the runner worktree; launchctl is a fake on PATH that records its calls.
# Nothing touches the real runner or the real launchd jobs.

SCRIPT="$HOME/.hydra/tools/ops-runner-refresh.sh"

setup() {
    REAL_SCRIPT="$SCRIPT"
    # the gate's pytest lives in the real user site-packages; a moved HOME would hide it
    PYTHONUSERBASE="$(/usr/bin/python3 -m site --user-base)"; export PYTHONUSERBASE
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/bin" "$HOME/Development/.worktrees/id8" "$HOME/Library/LaunchAgents"
    printf '#!/bin/bash\necho "launchctl $*" >> "%s/launchctl.calls"\n' "$HOME" > "$HOME/bin/launchctl"
    chmod +x "$HOME/bin/launchctl"
    export PATH="$HOME/bin:$PATH"
    git init -q --bare "$HOME/origin.git"
    git clone -q "$HOME/origin.git" "$HOME/Development/id8"
    M="$HOME/Development/id8"
    git -C "$M" config user.email t@t; git -C "$M" config user.name t
    mkdir -p "$M/tools/kev-ondemand" "$M/tools/synapse"
    echo v1 > "$M/tools/kev-ondemand/kev_ondemand.py"; echo s1 > "$M/tools/synapse/synapse.py"
    git -C "$M" add -A; git -C "$M" commit -qm one; git -C "$M" push -q origin HEAD:main
    git -C "$M" worktree add -q --detach "$HOME/Development/.worktrees/id8/ops-runner" origin/main
    RUN="$HOME/Development/.worktrees/id8/ops-runner"
    STATE="$HOME/Library/Application Support/id8/ops-runner"
}

push_main() {  # push_main <file> <content>
    echo "$2" > "$M/$1"; git -C "$M" add -A; git -C "$M" commit -qm "edit $1"; git -C "$M" push -q origin HEAD:main
}

@test "moves the runner to origin/main and restarts kev when its code changed" {
    push_main tools/kev-ondemand/kev_ondemand.py v2
    run "$REAL_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$RUN/tools/kev-ondemand/kev_ondemand.py")" = v2 ]
    grep -q "kickstart -k .*com.id8labs.keystone.founder.model" "$HOME/launchctl.calls"
    [ ! -e "$STATE/HEALTH.txt" ]
}

@test "a synapse-only change moves the runner without restarting kev" {
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s2 ]
    [ ! -e "$HOME/launchctl.calls" ]
}

@test "refuses to reset a runner with uncommitted edits" {
    push_main tools/synapse/synapse.py s2
    echo local > "$RUN/tools/synapse/synapse.py"
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = local ]
    grep -q "uncommitted changes" "$STATE/HEALTH.txt"
}

@test "refuses a runner with a branch checked out" {
    git -C "$RUN" checkout -q -b someones-work
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s1 ]
    grep -q "has branch someones-work checked out" "$STATE/HEALTH.txt"
}

@test "refuses when the runner path is a symlink to the operator's checkout" {
    git -C "$M" worktree remove --force "$RUN"
    ln -s "$M" "$RUN"
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    grep -q "refusing to reset" "$STATE/HEALTH.txt"
    [ "$(git -C "$M" rev-parse HEAD)" = "$(git -C "$M" rev-parse origin/main)" ]
}

@test "keeps commits found on the runner on a runner-stray branch before resetting" {
    echo stray > "$RUN/stray.txt"
    git -C "$RUN" -c user.email=t@t -c user.name=t add stray.txt
    git -C "$RUN" -c user.email=t@t -c user.name=t commit -qm stray
    STRAY="$(git -C "$RUN" rev-parse HEAD)"
    run "$REAL_SCRIPT"
    [ ! -e "$RUN/stray.txt" ]
    git -C "$M" branch --list 'runner-stray-*' --format='%(objectname)' | grep -qx "$STRAY"
}

@test "rebuilds a missing runner from origin/main" {
    git -C "$M" worktree remove --force "$RUN"
    run "$REAL_SCRIPT"
    [ -e "$RUN/.git" ]
    [ "$(git -C "$RUN" rev-parse HEAD)" = "$(git -C "$M" rev-parse origin/main)" ]
    grep -q "rebuilt" "$HOME/Library/Logs/id8labs-ops-runner-refresh.log"
}

@test "flags a launchd plist that changed on main instead of reinstalling it" {
    push_main tools/synapse/com.id8labs.synapse-sweep.plist new-plist
    echo old-plist > "$HOME/Library/LaunchAgents/com.id8labs.synapse-sweep.plist"
    run "$REAL_SCRIPT"
    grep -q "synapse-sweep.plist changed on main" "$STATE/HEALTH.txt"
    [ "$(cat "$HOME/Library/LaunchAgents/com.id8labs.synapse-sweep.plist")" = old-plist ]
}

@test "a second run while one holds the lock is skipped" {
    mkdir -p "$STATE/.refresh.lock"
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s1 ]
    grep -q "another refresh is running" "$HOME/Library/Logs/id8labs-ops-runner-refresh.log"
}

@test "gate: main whose Synapse tests fail holds the runner and says so" {
    printf 'def test_broken():\n    assert False\n' > "$M/tools/synapse/test_gate.py"
    push_main tools/synapse/synapse.py s2-broken
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s1 ]
    grep -q "fails the Synapse/Kev tests" "$STATE/HEALTH.txt"
    [ "$(git -C "$M" worktree list | grep -c ops-runner-gate)" -eq 0 ]  # throwaway checkout cleaned up
}

@test "gate: main whose tests pass moves the runner" {
    printf 'def test_ok():\n    assert True\n' > "$M/tools/synapse/test_gate.py"
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s2 ]
    [ ! -e "$STATE/HEALTH.txt" ]
}

@test "gate: a change outside the ops tools skips the tests and moves" {
    printf 'def test_broken():\n    assert False\n' > "$M/tools/synapse/test_gate.py"
    git -C "$M" add tools/synapse/test_gate.py; git -C "$M" commit -qm "red test lands"; git -C "$M" push -q origin HEAD:main
    git -C "$RUN" fetch -q origin; git -C "$RUN" reset -q --hard origin/main
    push_main README.md docs-only
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/README.md")" = docs-only ]
}

@test "gate: a gate that cannot run says so, and still holds the runner" {
    export PYTHONUSERBASE="$BATS_TEST_TMPDIR/no-site"; export PYTHONNOUSERSITE=1
    push_main tools/synapse/synapse.py s2
    run "$REAL_SCRIPT"
    [ "$(cat "$RUN/tools/synapse/synapse.py")" = s1 ]
    grep -q "could not run the gate" "$STATE/HEALTH.txt"
}
