#!/usr/bin/env bats
# release-gate.sh (PreToolUse Bash hook; exit 2 = block). Fixture: a fake HOME holding
# copies of the hook + release_gate.py + prometheus_trigger.py, an engagement registry
# whose git deployable is a DIRTY temp repo, and cwd inside that repo -- the state in
# which the gate is armed. Read-only commands must PASS; minting commands must BLOCK.

load helpers/common

HOOKS="$REAL_HOME/.claude/hooks"

setup() {
    setup_fake_home
    mkdir -p "$FAKE_HOME/.claude/hooks"
    for f in release-gate.sh release_gate.py prometheus_trigger.py; do
        cp "$(target "$HOOKS/$f")" "$FAKE_HOME/.claude/hooks/$f"
    done
    REPO="$FAKE_HOME/repo"; OTHER="$FAKE_HOME/repo-old"
    mkdir -p "$REPO" "$OTHER"
    git -C "$REPO" init -q
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo dirty > "$REPO/f.txt"
    printf '{"engagements":[{"key":"fx","name":"Fixture","deployables":[{"kind":"git","label":"engine","repo":"%s","main_branch":"main"},{"kind":"manual","label":"db","note":"confirm"}]}]}' \
        "$REPO" > "$FAKE_HOME/.claude/engagement-routes.json"
}

# gate <command> [cwd]  -> sets $status from the hook
gate() {
    local payload
    payload="$(/usr/bin/python3 -I -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$REPO}")"
    printf '%s' "$payload" | env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin "$TEST_BASH" "$FAKE_HOME/.claude/hooks/release-gate.sh" >/dev/null 2>&1
}

must_pass()  { local c; for c in "$@"; do run gate "$c"; [ "$status" -eq 0 ] || { echo "WRONGLY BLOCKED ($status): $c"; return 1; }; done; }
must_block() { local c; for c in "$@"; do run gate "$c"; [ "$status" -eq 2 ] || { echo "NOT BLOCKED ($status): $c"; return 1; }; done; }

@test "release-gate: plain read-only commands pass" {
    must_pass 'cat f.txt' 'git status' 'git log --oneline -5' 'ls -la' 'git diff' 'git show HEAD'
}

@test "release-gate: --help forms pass" {
    must_pass 'git push --help' 'git tag --help' 'gh release --help'
}

@test "release-gate: read-only commands that merely MENTION a release command pass" {
    must_pass \
        'git log --grep "git push origin main"' \
        'grep -rn "git tag v" .' \
        'grep -rn "git push origin main" . 2>&1' \
        'cd sub && git log --grep "git push origin main"' \
        'git log --oneline | sort | uniq -c | grep "git tag v"' \
        'echo "git tag v1"' \
        'git log -p -c --grep "git tag v1"'
}

@test "release-gate: a branch merely starting with 'main' is not main" {
    must_pass 'git push origin main-hotfix' 'git push origin mainline-fix'
}

@test "release-gate: minting commands block (positive control)" {
    must_block 'git tag v1.0' 'git tag -a v1.0 -m x' 'git push origin main' 'git push origin v1.2.3' \
        'git push origin --tags' 'gh release create v1.0'
}

@test "release-gate: minting variants the substring matcher missed now block" {
    must_block 'git push -u origin main' 'git push --force origin main' 'git push origin HEAD:main' \
        'git push origin +main' 'git push upstream main' 'git push --follow-tags origin main' \
        'git --no-pager push origin main' 'git tag -s v1.2' 'git tag -am msg v1' 'git tag 1.0.0'
}

@test "release-gate: compound / hidden minting still blocks" {
    must_block \
        'git log && git push origin main' \
        'cat f.txt; git tag v2' \
        $'grep x .\ngit push origin main' \
        'bash -c "git push origin main"' \
        'echo "git push origin main" | sh' \
        'cat <(git push origin main)' \
        'echo $(git tag v9)' \
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="git push origin main" git status' \
        'git -c core.pager="git push origin main" log' \
        'git grep -O"sh -c \"git push origin main\"" x' \
        'rg --pre sh "git push origin main" f.txt'
}

@test "release-gate: heredoc piped into a shell blocks" {
    must_block $'cat <<EOF | sh\ngit push origin main\nEOF'
}

@test "release-gate: git -C <deployable> from an unrelated cwd still gates the deployable" {
    run gate "git -C $REPO push origin main" "$FAKE_HOME"
    [ "$status" -eq 2 ]
}

@test "release-gate: a sibling dir sharing the deployable's name prefix is NOT that deployable" {
    run gate 'git push origin main' "$OTHER"
    [ "$status" -eq 0 ]
}

@test "release-gate: silent for non-engagement cwd" {
    run gate 'git push origin main' "$FAKE_HOME"
    [ "$status" -eq 0 ]
}

@test "release-gate: trigger module missing -> still fails CLOSED on a mint" {
    rm -f "$FAKE_HOME/.claude/hooks/prometheus_trigger.py"
    must_block 'git tag v1.0' 'git push origin main'
}

# gate_out <command> -> the hook's printed message (both streams), status kept
gate_out() {
    local payload
    payload="$(/usr/bin/python3 -I -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$REPO")"
    printf '%s' "$payload" | env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin "$TEST_BASH" "$FAKE_HOME/.claude/hooks/release-gate.sh" 2>&1
}

# with_coordinator <name> : re-write the fixture route with a top-level coordinator
with_coordinator() {
    printf '{"engagements":[{"key":"fx","name":"Fixture","coordinator":"%s","deployables":[{"kind":"git","label":"engine","repo":"%s","main_branch":"main"}]}]}' \
        "$1" "$REPO" > "$FAKE_HOME/.claude/engagement-routes.json"
}

@test "release-gate: a route's top-level coordinator is the one the hook names" {
    mkdir -p "$FAKE_HOME/.claude/agents"; : > "$FAKE_HOME/.claude/agents/prometheus-fx.md"
    with_coordinator prometheus-fx
    run gate_out 'git push origin main'
    [ "$status" -eq 2 ]
    [[ "$output" == *'subagent_type="prometheus-fx"'* ]]
}

@test "release-gate: a coordinator with no installed charter falls back to prometheus" {
    with_coordinator prometheus-nosuch
    run gate_out 'git push origin main'
    [ "$status" -eq 2 ]
    [[ "$output" == *'subagent_type="prometheus"'* ]]
    [[ "$output" != *'prometheus-nosuch'* ]]
}

@test "release-gate: a coordinator that is not a Prometheus name falls back to prometheus" {
    mkdir -p "$FAKE_HOME/.claude/agents"; : > "$FAKE_HOME/.claude/agents/general-purpose.md"
    with_coordinator general-purpose
    run gate_out 'git push origin main'
    [ "$status" -eq 2 ]
    [[ "$output" == *'subagent_type="prometheus"'* ]]
}

@test "release-gate: a route with no coordinator still names prometheus" {
    run gate_out 'git push origin main'
    [ "$status" -eq 2 ]
    [[ "$output" == *'subagent_type="prometheus"'* ]]
}

@test "release-gate: --help with only an output redirect after it is a read" {
    must_pass 'vercel domains rm --help 2>&1' 'vercel promote --help 2>/dev/null' 'git push --help 2>&1'
}

@test "release-gate: a redirect does not launder a real mint" {
    must_block 'git push origin main 2>&1' 'git push -o --help origin main 2>&1' 'git tag v1.0 2>/dev/null'
}

@test "release-gate: the coordinator prompt carries preflight, all-six and station models" {
    run gate_out 'git push origin main'
    [ "$status" -eq 2 ]
    [[ "$output" == *"preflight; launch no station until it passes"* ]]
    [[ "$output" == *"L1 on Sonnet, L2-L6 on Opus"* ]]
    [[ "$output" == *"once ALL six sealed"* ]]
}
