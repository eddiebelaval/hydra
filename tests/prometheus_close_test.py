"""A Prometheus request closes (go / hold) when its sixth station seals, and recycle reopens it.
Usage: python3 prometheus_close_test.py [path/to/prometheus_trigger.py]"""
import importlib.util, json, os, sys, tempfile
src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/hooks/prometheus_trigger.py")
spec = importlib.util.spec_from_file_location("pt", src); pt = importlib.util.module_from_spec(spec); spec.loader.exec_module(pt)
sd = tempfile.mkdtemp(); cfg = pt.config(); cfg["state_dir"] = sd
os.makedirs(os.path.join(sd, "requests"))
key = "deadbeefdeadbeef"; path = os.path.join(sd, "requests", key + ".json")
json.dump({"status": "pending", "candidate": {"key": key}}, open(path, "w"))
assert pt.ack(cfg, key, "run-test")[0]
def call(st, verdict, who):
    c = {"reviewer": who, "verdict": verdict,
         "evidence": [{"method": "ran the unit check", "command": "python3 -c 'print(1)'"}],
         "inputs_seen": ["the request json"], "scope_rationale": "x" * 25}
    ok, msg = pt.file_call(cfg, key, st, c); assert ok, msg
sts = list(pt.STATIONS)
for i, s in enumerate(sts[:-1]):
    call(s, "GO", f"rev{i}")
    assert json.load(open(path))["status"] == "in_review", "closed before all six sealed"
call(sts[-1], "GO", "revlast")
r = json.load(open(path)); assert r["status"] == "go" and r["closed"]["outcome"] == "GO", r
assert pt.recycle(cfg, key, "testing the reopen path")[0]
r = json.load(open(path)); assert r["status"] == "in_review" and "closed" not in r, r
for i, s in enumerate(sts):
    call(s, "NO-GO" if i == 2 else "GO", f"b{i}")
assert json.load(open(path))["status"] == "hold"
print("PASS")
