#!/usr/bin/env python3
"""Hydra LLM gateway: every model call through one door.

Jobs name a TASK (decide, summarize, extract, write, chat) and a TIER
(small, mid, large). The gateway walks the task's lane order from
config/llm.json, skipping lanes whose breaker is open, and returns the
first answer. Every attempt is metered to hydra.db `llm_calls`.

    from hydra_llm import complete, Skipped
    text = complete("hydra-observer", prompt, system=SYS, task="summarize")

Shell:  echo "$PROMPT" | hydra-llm --job NAME [--task T] [--tier T] [--system-file F]
        hydra-llm report [--days N]     hydra-llm breaker [--reset LANE]

Exit codes (shell): 0 ok, 75 skipped (breaker open / over budget: log and
move on), 1 error. Spec: ~/.hydra/docs/LLM-GATEWAY.md.

Runs under launchd's python3, which can be macOS 3.9: stdlib only, and no
3.10+ syntax evaluated at runtime.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HYDRA_ROOT = os.environ.get("HYDRA_ROOT", os.path.expanduser("~/.hydra"))
CONFIG = os.environ.get("HYDRA_LLM_CONFIG", os.path.join(HYDRA_ROOT, "config", "llm.json"))
DB = os.environ.get("HYDRA_DB", os.path.join(HYDRA_ROOT, "hydra.db"))
BREAKER = os.environ.get("HYDRA_LLM_BREAKER", os.path.join(HYDRA_ROOT, "state", "llm-breaker.json"))
NOTIFY = os.environ.get("HYDRA_LLM_NOTIFY", os.path.join(HYDRA_ROOT, "daemons", "notify-eddie.sh"))
API_URL = os.environ.get("HYDRA_LLM_API_URL", "https://api.anthropic.com/v1/messages")
SUB_CONFIG_DIR = os.path.expanduser("~/.claude-id8labs")
SUB_STATUS = os.environ.get("HYDRA_LLM_SUB_STATUS", os.path.expanduser("~/.claude/.id8labs-profile-status"))

# Equivalent USD per 1M tokens, for the meter only (subscription calls are
# not billed per token; the number shows what they would have cost).
PRICE = {"haiku": (1.0, 5.0), "sonnet": (3.0, 15.0), "opus": (15.0, 75.0)}


class Skipped(Exception):
    """No lane could serve: breaker open or over budget. Not a failure."""


class LLMError(Exception):
    """Every available lane failed."""


class LaneError(Exception):
    def __init__(self, msg: str, kind: str = "error", until: dt.datetime | None = None):
        super().__init__(msg)
        self.kind = kind      # error | usage_limit | rate_limit | unavailable
        self.until = until


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _cfg() -> dict:
    with open(CONFIG) as f:
        return json.load(f)


def model_for(tier: str = "small", lane: str = "api") -> str:
    """The model ID config/llm.json maps a tier to, for the few callers that must
    reach a model themselves (tool loops, images, the API health ping, `claude -p`
    jobs that need tools). Everyone else calls complete() and never sees an ID."""
    tiers = _cfg()["tiers"]
    return (tiers.get(tier) or tiers["small"])[lane]


MODEL_ID_RE = r"claude-(haiku|sonnet|opus|fable)-[0-9]"


def lint_models(root: str | None = None) -> list:
    """Every hard-coded Claude model ID in Hydra's runnable code, as 'path:line: text'.
    config/llm.json is the one place a model ID may live (phase 5 gate)."""
    import re, subprocess
    root = root or HYDRA_ROOT
    out = subprocess.run(
        ["git", "-C", root, "grep", "-nE", MODEL_ID_RE, "--", "daemons", "tools", "lib", "bin", "scripts",
         ":!*.md", ":!*.json", ":!*.jsonl", ":!*node_modules*", ":!*/tests/*", ":!*.test.ts"],
        capture_output=True, text=True).stdout
    code = lambda l: l.split(":", 2)[2].lstrip() if l.count(":") >= 2 else l
    return [l for l in out.splitlines() if l.strip() and not code(l).startswith(("#", "//", "*"))]


# --------------------------------------------------------------------- meter

SCHEMA = """CREATE TABLE IF NOT EXISTS llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  job TEXT NOT NULL, task TEXT, tier TEXT, lane TEXT, model TEXT,
  status TEXT NOT NULL,            -- ok | error | skipped
  input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
  cost_usd REAL DEFAULT 0, ms INTEGER DEFAULT 0, error TEXT
);
CREATE INDEX IF NOT EXISTS idx_llm_calls_job_ts ON llm_calls(job, ts);"""


def _db() -> sqlite3.Connection:
    con = sqlite3.connect(DB, timeout=15)
    con.executescript(SCHEMA)
    return con


def _meter(job, task, tier, lane, model, status, inp=0, out=0, cost=0.0, ms=0, error=None):
    try:
        con = _db()
        con.execute(
            "INSERT INTO llm_calls (job,task,tier,lane,model,status,input_tokens,output_tokens,cost_usd,ms,error)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (job, task, tier, lane, model, status, inp, out, round(cost, 6), ms, (error or "")[:400] or None),
        )
        con.commit()
        con.close()
    except Exception as e:  # the meter must never take a job down
        print(f"hydra-llm: meter write failed: {e}", file=sys.stderr)


def _calls_today(job: str) -> int:
    try:
        con = _db()
        day = _now().strftime("%Y-%m-%d")
        n = con.execute(
            "SELECT count(*) FROM llm_calls WHERE job=? AND status!='skipped' AND ts>=?", (job, day)
        ).fetchone()[0]
        con.close()
        return n
    except Exception:
        return 0


# ------------------------------------------------------------------- breaker

def _load_breaker() -> dict:
    try:
        with open(BREAKER) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_breaker(state: dict) -> None:
    os.makedirs(os.path.dirname(BREAKER), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(BREAKER))
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, BREAKER)


def _alert(title: str, msg: str) -> None:
    if os.environ.get("HYDRA_LLM_NO_ALERT") or not os.path.exists(NOTIFY):
        print(f"hydra-llm ALERT: {title}: {msg}", file=sys.stderr)
        return
    try:
        subprocess.run(["bash", NOTIFY, "urgent", title, msg], timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def lane_open(lane: str) -> str | None:
    """Reason string if the lane's breaker is open, else None."""
    b = _load_breaker().get(lane) or {}
    until = b.get("open_until")
    if until and dt.datetime.fromisoformat(until) > _now():
        return f"{b.get('reason', 'open')} (until {until})"
    return None


def _record_failure(lane: str, err: LaneError, cfg: dict) -> None:
    state = _load_breaker()
    b = state.get(lane) or {}
    bc = cfg.get("breaker", {})
    streak = int(b.get("streak", 0)) + 1
    until = None
    if err.kind == "usage_limit":
        until = err.until or (_now() + dt.timedelta(hours=6))
    elif err.kind == "rate_limit":
        until = err.until or (_now() + dt.timedelta(minutes=bc.get("rate_limit_minutes", 30)))
    elif streak >= bc.get("error_streak", 5):
        until = _now() + dt.timedelta(minutes=bc.get("error_cooldown_minutes", 60))
    b["streak"] = streak
    b["last_error"] = str(err)[:300]
    if until:
        was_open = bool(b.get("open_until")) and dt.datetime.fromisoformat(b["open_until"]) > _now()
        b["open_until"] = until.isoformat()
        b["reason"] = err.kind
        if not was_open:
            _alert(f"Hydra LLM: {lane} lane paused",
                   f"{err.kind} until {until.strftime('%Y-%m-%d %H:%M UTC')}. "
                   f"Jobs fall through to the next lane or skip quietly. Last error: {str(err)[:160]}")
    state[lane] = b
    _save_breaker(state)


def _record_success(lane: str) -> None:
    state = _load_breaker()
    if state.get(lane):
        state[lane] = {}
        _save_breaker(state)


def _classify_http(code: int, body: str) -> LaneError:
    m = re.search(r"regain access on (\d{4}-\d{2}-\d{2}) at (\d{2}:\d{2}) UTC", body)
    if "usage limit" in body.lower():
        until = None
        if m:
            until = dt.datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M").replace(tzinfo=dt.timezone.utc)
        return LaneError(f"{code} usage limit: {body[:200]}", "usage_limit", until)
    if code in (429, 529):
        return LaneError(f"{code} rate limited: {body[:200]}", "rate_limit")
    return LaneError(f"HTTP {code}: {body[:300]}")


# --------------------------------------------------------------------- lanes

def _price(model: str, inp: int, out: int) -> float:
    for fam, (pi, po) in PRICE.items():
        if fam in model:
            return inp / 1e6 * pi + out / 1e6 * po
    return 0.0


def _lane_sub(model: str, prompt: str, system: str | None, max_tokens: int, timeout: int):
    claude = os.environ.get("HYDRA_LLM_CLAUDE_BIN") or shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    if not os.path.exists(claude):
        raise LaneError(f"claude CLI not found ({claude})", "unavailable")
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)  # an inherited key would silently bill metered
    expired = False
    try:
        expired = open(SUB_STATUS).read().strip().upper().startswith("EXPIRED")
    except OSError:
        pass
    if expired or os.environ.get("HYDRA_LLM_SUB_DEFAULT_PROFILE"):
        env.pop("CLAUDE_CONFIG_DIR", None)
        if expired:
            print("hydra-llm: id8labs profile EXPIRED; billing the default (personal) profile until re-login",
                  file=sys.stderr)
    else:
        env["CLAUDE_CONFIG_DIR"] = SUB_CONFIG_DIR
    cmd = [claude, "-p", "--model", model, "--output-format", "json", "--tools", "",
           "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence"]
    if system:
        cmd += ["--system-prompt", system]
    if max_tokens:
        # claude -p has no max_tokens flag; the cap travels as an instruction.
        prompt = f"{prompt}\n\n(Keep the reply under about {int(max_tokens * 0.75)} words.)"
    work = tempfile.mkdtemp(prefix="hydra-llm-")  # empty cwd: no project CLAUDE.md
    try:
        p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, cwd=work, env=env)
    except subprocess.TimeoutExpired:
        raise LaneError(f"claude -p timed out after {timeout}s")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    raw = (p.stdout or "").strip()
    try:
        d = json.loads(raw)
    except ValueError:
        blob = (raw + " " + (p.stderr or "")).strip()
        low = blob.lower()
        if "usage limit" in low or "limit reached" in low:
            m = re.search(r"\|(\d{10})", blob)
            until = dt.datetime.fromtimestamp(int(m.group(1)), dt.timezone.utc) if m else None
            raise LaneError(f"subscription limit: {blob[:200]}", "usage_limit", until)
        if "login" in low or "not authenticated" in low:
            raise LaneError(f"subscription login problem: {blob[:200]}", "unavailable")
        raise LaneError(f"claude -p exit {p.returncode}: {blob[:300]}")
    text = d.get("result") or ""
    if d.get("is_error") or not text.strip():
        low = text.lower()
        kind = "usage_limit" if ("usage limit" in low or "limit reached" in low) else "error"
        raise LaneError(f"claude -p error: {text[:300] or d.get('subtype')}", kind)
    u = d.get("usage") or {}
    inp = int(u.get("input_tokens", 0)) + int(u.get("cache_creation_input_tokens", 0)) + int(u.get("cache_read_input_tokens", 0))
    out = int(u.get("output_tokens", 0))
    used = ",".join((d.get("modelUsage") or {}).keys()) or model
    return text.strip(), used, inp, out, float(d.get("total_cost_usd") or _price(model, inp, out))


def _api_key() -> str:
    key = os.environ.get("HYDRA_LLM_API_KEY")
    if key:
        return key
    try:
        key = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", "eddiebelaval"),
             "-s", "id8-automation-api-key", "-w"],
            capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        key = ""
    if not key:
        raise LaneError("no API key in Keychain (id8-automation-api-key)", "unavailable")
    return key


def _lane_api(model: str, prompt: str, system: str | None, max_tokens: int, timeout: int):
    body = {"model": model, "max_tokens": max_tokens or 1024,
            "messages": [{"role": "user", "content": prompt}]}
    if system:
        body["system"] = system
    req = urllib.request.Request(API_URL, data=json.dumps(body).encode(), headers={
        "x-api-key": _api_key(), "anthropic-version": "2023-06-01", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise _classify_http(e.code, e.read().decode(errors="replace"))
    except Exception as e:
        raise LaneError(f"API request failed: {e}")
    text = "".join(c.get("text", "") for c in d.get("content", []) if c.get("type") == "text").strip()
    u = d.get("usage") or {}
    inp = int(u.get("input_tokens", 0)) + int(u.get("cache_read_input_tokens", 0) or 0)
    out = int(u.get("output_tokens", 0))
    return text, d.get("model", model), inp, out, _price(model, inp, out)


def _lane_subq(model, prompt, system, max_tokens, timeout):
    # Wired in phase 3, from docs.subq.ai, after the key is in Keychain and the
    # data-retention question is answered. Until then this lane never serves.
    raise LaneError("subq lane not wired yet", "unavailable")


LANES = {"sub": _lane_sub, "api": _lane_api, "subq": _lane_subq}


# ---------------------------------------------------------------------- core

def complete(job: str, prompt: str, system: str | None = None, task: str = "summarize",
             tier: str = "small", max_tokens: int = 1000, timeout: int = 180,
             lanes: list | None = None) -> str:
    """Return the model's text. Raises Skipped (quiet) or LLMError."""
    cfg = _cfg()
    order = lanes or cfg["tasks"].get(task) or ["sub", "api"]
    if task == "decide" or "subq" in order:
        if not cfg.get("subq", {}).get("enabled"):
            order = [l for l in order if l != "subq"]

    budget = (cfg.get("budgets", {}).get(job) or cfg.get("budgets", {}).get("default") or {}).get("calls_per_day")
    if budget and _calls_today(job) >= budget:
        _meter(job, task, tier, None, None, "skipped", error=f"over budget ({budget}/day)")
        state = _load_breaker()
        key = f"budget:{job}:{_now().strftime('%Y-%m-%d')}"
        if not state.get(key):
            state[key] = {"alerted": True}
            _save_breaker(state)
            _alert("Hydra LLM: job over budget", f"{job} hit {budget} calls today; skipping until tomorrow.")
        raise Skipped(f"{job} over budget ({budget} calls/day)")

    errors, skipped = [], []
    for lane in order:
        why = lane_open(lane)
        if why:
            skipped.append(f"{lane}: {why}")
            continue
        model = (cfg["tiers"].get(tier) or cfg["tiers"]["small"]).get(lane, "")
        t0 = time.time()
        try:
            text, used, inp, out, cost = LANES[lane](model, prompt, system, max_tokens, timeout)
        except LaneError as e:
            ms = int((time.time() - t0) * 1000)
            _meter(job, task, tier, lane, model, "error", ms=ms, error=str(e))
            if e.kind != "unavailable":
                _record_failure(lane, e, cfg)
            errors.append(f"{lane}: {e}")
            continue
        _meter(job, task, tier, lane, used, "ok", inp, out, cost, int((time.time() - t0) * 1000))
        _record_success(lane)
        return text
    if errors:
        raise LLMError("; ".join(errors + skipped))
    _meter(job, task, tier, None, None, "skipped", error="; ".join(skipped))
    raise Skipped("; ".join(skipped) or "no lane configured")


# ------------------------------------------------------------ urllib compat
# Drop-in for the old raw-API heredocs: swap `urllib.request.Request(URL, ...)`
# for `hydra_llm.Request(job, data, task=...)` and `urllib.request.urlopen`
# for `hydra_llm.urlopen`; the rest of the caller (resp.read(), parsing
# result["content"][0]["text"]) stays as written.

def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


class Request(object):
    def __init__(self, job, data, task="summarize", tier=None, **_ignored):
        payload = json.loads(data.decode() if isinstance(data, (bytes, bytearray)) else data)
        model = payload.get("model", "")
        self.job = job
        self.task = task
        self.tier = tier or ("large" if "opus" in model else "mid" if "sonnet" in model else "small")
        self.max_tokens = int(payload.get("max_tokens") or 1000)
        self.system = _text_of(payload.get("system")) or None
        msgs = payload.get("messages") or []
        if len(msgs) <= 1:
            self.prompt = _text_of(msgs[0].get("content")) if msgs else ""
        else:
            history = "\n\n".join(("Eddie" if m.get("role") == "user" else "You") + ": " + _text_of(m.get("content"))
                                  for m in msgs[:-1])
            self.prompt = ("Conversation so far:\n\n" + history
                           + "\n\nReply to this latest message:\n\n" + _text_of(msgs[-1].get("content")))


class _Response(object):
    def __init__(self, body: bytes):
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def urlopen(req: Request, timeout: int = 0, **_ignored) -> _Response:
    """Old raw-API callers used 5-60 s timeouts; the sub lane needs more."""
    text = complete(req.job, req.prompt, system=req.system, task=req.task, tier=req.tier,
                    max_tokens=req.max_tokens, timeout=max(int(timeout or 0), 120))
    return _Response(json.dumps({"type": "message", "role": "assistant",
                                 "content": [{"type": "text", "text": text}]}).encode())


# ----------------------------------------------------------------------- cli

def _report(days: int) -> None:
    con = _db()
    since = (_now() - dt.timedelta(days=days)).strftime("%Y-%m-%d")
    rows = con.execute(
        "SELECT job, lane, status, count(*), sum(input_tokens), sum(output_tokens), round(sum(cost_usd),4)"
        " FROM llm_calls WHERE ts>=? GROUP BY 1,2,3 ORDER BY 7 DESC, 4 DESC", (since,)).fetchall()
    print(f"llm_calls since {since}")
    print(f"{'job':28} {'lane':5} {'status':8} {'calls':>6} {'in_tok':>9} {'out_tok':>8} {'usd_eq':>8}")
    for r in rows:
        print(f"{r[0][:28]:28} {str(r[1]):5} {r[2]:8} {r[3]:6} {r[4] or 0:9} {r[5] or 0:8} {r[6] or 0:8}")
    for lane in LANES:
        why = lane_open(lane)
        print(f"breaker {lane}: {'OPEN ' + why if why else 'closed'}")


def main(argv: list) -> int:
    import argparse
    if argv[:1] == ["report"]:
        ap = argparse.ArgumentParser(prog="hydra-llm report")
        ap.add_argument("--days", type=int, default=1)
        _report(ap.parse_args(argv[1:]).days)
        return 0
    if argv[:1] == ["breaker"]:
        ap = argparse.ArgumentParser(prog="hydra-llm breaker")
        ap.add_argument("--reset")
        a = ap.parse_args(argv[1:])
        state = _load_breaker()
        if a.reset:
            state.pop(a.reset, None)
            _save_breaker(state)
        print(json.dumps({k: v for k, v in state.items() if not k.startswith("budget:")}, indent=1))
        return 0
    if argv[:1] == ["model"]:
        ap = argparse.ArgumentParser(prog="hydra-llm model")
        ap.add_argument("tier", nargs="?", default="small")
        ap.add_argument("--lane", default="api")
        a = ap.parse_args(argv[1:])
        print(model_for(a.tier, a.lane))
        return 0
    if argv[:1] == ["lint-models"]:
        hits = lint_models()
        for h in hits:
            print(h)
        return 1 if hits else 0
    ap = argparse.ArgumentParser(prog="hydra-llm", description="Hydra LLM gateway; prompt on stdin")
    ap.add_argument("--job", required=True)
    ap.add_argument("--task", default="summarize")
    ap.add_argument("--tier", default="small")
    ap.add_argument("--system")
    ap.add_argument("--system-file")
    ap.add_argument("--max-tokens", type=int, default=1000)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--lanes", help="comma list overriding the task's lane order")
    a = ap.parse_args(argv)
    system = a.system
    if a.system_file:
        with open(a.system_file) as f:
            system = f.read()
    prompt = sys.stdin.read()
    if not prompt.strip():
        print("hydra-llm: empty prompt on stdin", file=sys.stderr)
        return 1
    try:
        print(complete(a.job, prompt, system, a.task, a.tier, a.max_tokens, a.timeout,
                       a.lanes.split(",") if a.lanes else None))
        return 0
    except Skipped as e:
        print(f"hydra-llm: skipped: {e}", file=sys.stderr)
        return 75
    except LLMError as e:
        print(f"hydra-llm: failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
