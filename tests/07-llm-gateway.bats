#!/usr/bin/env bats
# Hydra LLM gateway (lib/hydra_llm.py). Never calls a real model: the claude CLI
# is a fake that answers per $FAKE_MODE, the API URL points at a closed port, and
# the db, breaker and config live in the test's temp dir.

setup() {
    T="$BATS_TEST_TMPDIR"
    GW="$HOME/.hydra/lib/hydra_llm.py"
    export HYDRA_DB="$T/hydra.db" HYDRA_LLM_BREAKER="$T/breaker.json" HYDRA_LLM_NO_ALERT=1
    export HYDRA_LLM_API_URL="http://127.0.0.1:9/v1/messages" HYDRA_LLM_API_KEY="test-not-a-key"
    export HYDRA_LLM_CLAUDE_BIN="$T/claude" HYDRA_LLM_SUB_STATUS="$T/no-status"
    sed 's/"calls_per_day": 200/"calls_per_day": 3/' "$HOME/.hydra/config/llm.json" > "$T/llm.json"
    export HYDRA_LLM_CONFIG="$T/llm.json"
    cat > "$T/claude" <<'FAKE'
#!/bin/bash
cat > /dev/null
[ -n "$ANTHROPIC_API_KEY" ] && { echo '{"is_error":true,"result":"LEAKED API KEY"}'; exit 0; }
case "$FAKE_MODE" in
  ok)    echo '{"is_error":false,"result":"hello from sub","total_cost_usd":0.0002,"usage":{"input_tokens":10,"output_tokens":3},"modelUsage":{"claude-haiku-5-5":{}}}' ;;
  limit) echo 'Claude AI usage limit reached|1999999999'; exit 1 ;;
  *)     echo 'boom'; exit 1 ;;
esac
FAKE
    chmod +x "$T/claude"
}

run_gw() { run python3 "$GW" "$@"; }
rows() { sqlite3 "$HYDRA_DB" "$1"; }

@test "subscription lane answers, meters the call, never sees an API key" {
    export FAKE_MODE=ok ANTHROPIC_API_KEY=should-be-stripped
    run_gw --job t1 <<< "hi"
    [ "$status" -eq 0 ]
    [ "$output" = "hello from sub" ]
    [ "$(rows "select lane||':'||status||':'||model from llm_calls")" = "sub:ok:claude-haiku-5-5" ]
}

@test "sub failure falls through to api; both metered as errors; exit 1" {
    export FAKE_MODE=bad
    run_gw --job t2 <<< "hi"
    [ "$status" -eq 1 ]
    [ "$(rows "select group_concat(lane||':'||status) from llm_calls")" = "sub:error,api:error" ]
}

@test "usage limit opens the lane until the named reset, then later calls skip it" {
    export FAKE_MODE=limit
    run_gw --job t3 --lanes sub <<< "hi"
    [ "$status" -eq 1 ]
    grep -q '"reason": "usage_limit"' "$HYDRA_LLM_BREAKER"
    grep -q '2033-05-18' "$HYDRA_LLM_BREAKER"
    export FAKE_MODE=ok
    run_gw --job t3 --lanes sub <<< "hi"
    [ "$status" -eq 75 ]
    [[ "$output" == *"skipped"* ]]
}

@test "api usage-limit body parses the reset time" {
    run python3 -c "
import sys; sys.path.insert(0, '$HOME/.hydra/lib'); import hydra_llm as h
e = h._classify_http(400, 'You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC.')
print(e.kind, e.until.isoformat())"
    [ "$output" = "usage_limit 2026-11-01T00:00:00+00:00" ]
}

@test "five straight errors open the lane; a success closes it" {
    export FAKE_MODE=bad
    for i in 1 2 3; do python3 "$GW" --job "s$i" --lanes sub <<< "hi" || true; done
    sed -i '' 's/"calls_per_day": 3/"calls_per_day": 50/' "$HYDRA_LLM_CONFIG"
    for i in 4 5; do python3 "$GW" --job "s$i" --lanes sub <<< "hi" || true; done
    grep -q '"open_until"' "$HYDRA_LLM_BREAKER"
    python3 "$GW" breaker --reset sub > /dev/null
    export FAKE_MODE=ok
    run_gw --job s6 --lanes sub <<< "hi"
    [ "$status" -eq 0 ]
    ! grep -q '"streak"' "$HYDRA_LLM_BREAKER"
}

@test "over budget skips quietly with exit 75 and meters a skip" {
    export FAKE_MODE=ok
    for i in 1 2 3; do python3 "$GW" --job capped <<< "hi" > /dev/null; done
    run_gw --job capped <<< "hi"
    [ "$status" -eq 75 ]
    [ "$(rows "select count(*) from llm_calls where job='capped' and status='skipped'")" = "1" ]
}

@test "subq lane is skipped while disabled" {
    export FAKE_MODE=ok
    run_gw --job d1 --task decide <<< "yes or no?"
    [ "$status" -eq 0 ]
    [ "$(rows "select group_concat(lane) from llm_calls")" = "sub" ]
}

@test "report runs" {
    export FAKE_MODE=ok
    python3 "$GW" --job r1 <<< "hi" > /dev/null
    run_gw report
    [ "$status" -eq 0 ]
    [[ "$output" == *"r1"* ]]
}

@test "urllib compat: old raw-API heredoc shape works unchanged through the gateway" {
    export FAKE_MODE=ok
    run python3 -c "
import json, sys; sys.path.insert(0, '$HOME/.hydra/lib'); import hydra_llm
data = json.dumps({'model': 'claude-sonnet-4-5-20250929', 'max_tokens': 50, 'system': 'be brief',
                   'messages': [{'role': 'user', 'content': 'a'}, {'role': 'assistant', 'content': 'b'},
                                {'role': 'user', 'content': [{'type': 'text', 'text': 'c'}]}]}).encode()
req = hydra_llm.Request('compat-job', data, task='extract')
assert req.tier == 'mid' and req.system == 'be brief', (req.tier, req.system)
assert 'Eddie: a' in req.prompt and 'You: b' in req.prompt and req.prompt.endswith('c'), req.prompt
with hydra_llm.urlopen(req, timeout=5) as resp:
    print(json.loads(resp.read().decode())['content'][0]['text'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "hello from sub" ]
    [ "$(rows "select job||':'||task||':'||tier||':'||lane from llm_calls")" = "compat-job:extract:mid:sub" ]
}
