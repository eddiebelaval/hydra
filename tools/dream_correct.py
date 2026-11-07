#!/usr/bin/env python3
"""dream_correct: the misses half of the dream. Reads the day's transcripts for what went WRONG, checks each miss
against the lessons we already hold, and fixes memory itself where the fix is reversible.

Why (Eddie 11/07 01:39 "let's build it"; review ops/memory/DREAMING-REVIEW-2026-11-06.md): the dream measured only
wins, and the 3am dream-pass is report-only, so the same findings repeated for months (feedback_two_main_lines on
83 nights). Anthropic's agent-memory work (11/06): memory improves when an offline pass checks notes against the
transcript and rewrites them; the injected index must stay small.

Each night:
  1. MINE      Eddie's own messages (typed, queued mid-turn) and side-agent notes from every Claude account's
               transcripts in the window, each with what the assistant had just said.
  2. MATCH     each miss to the closest existing lessons (signatures, name, description).
  3. JUDGE     one model pass (subscription, mid tier) classifies each: recurred | new | fact | noise.
  4. FIX       reversible only, every touched file backed up first (undo: dream_correct.py undo <date>):
                 recurred -> the lesson gets a dated Recurrences line + the new symptom as a signature;
                             recurred twice -> ONE board row: G3 guard candidate (human-gated, per outer-loop SPEC)
                 new      -> a lesson DRAFT in ~/.claude/dream/drafts/ (never live memory: over-recording is the
                             failure Anthropic measured), listed in the dream
                 fact     -> ONE board row for Eddie (a money fact or a client rule is his to settle)
               plus hygiene: MEMORY.md is held under the load limit by moving dated Unfiled entries into that
               month's dispatch file, leaving a pointer; a dream-pass finding seen on 3+ nights becomes ONE board row.
  5. REPORT    ~/.claude/dream/correct-<date>.md and misses-<date>.json (dream-sweep puts the misses in DREAM.md).

Never deletes a memory file, never edits a lesson's rule text, never writes outside the memory folder, the dream
folder and the board. Fails soft: a broken step is reported, the rest still runs.

  python3 dream_correct.py [--hours 24] [--dry-run] [--no-llm]
  python3 dream_correct.py undo <YYYY-MM-DD>
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
MEM = os.path.join(HOME, ".claude", "projects", "-Users-eddiebelaval-Development-id8", "memory")
INDEX = os.path.join(MEM, "MEMORY.md")
DREAM = os.path.join(HOME, ".claude", "dream")
BOARD = os.path.join(HOME, "Development", "id8", "TODO.md")
ROOTS = [os.path.join(HOME, d, "projects") for d in (".claude", ".claude-id8labs", ".claude-main")]
# Claude Code loads the first 25 KB / 200 lines of MEMORY.md (Anthropic 11/06); the harness warned at 24.4 KB.
INDEX_LIMIT = 24000
INDEX_TARGET = 22000            # leave room for the day's new lines
INDEX_LINES = 190
BATCH = 40                      # messages per model pass
MAX_MESSAGES = 400               # a day past this is itself the finding
SKIP_PREFIXES = ("This session is being continued", "<command-", "<local-command", "<task-notification>",
                 "You are Eddie's", "/compact", "Caveat:", "[Request interrupted")
SIDE_NOTE = "Here is a note offered by a side agent"
STOP = set("the a an and or but to of in on at for with is are was were be been it this that these those i you we "
           "he she they my your our me us do does did not no yes so if as by from up out just can will would "
           "should could have has had then than there here what why how when which who all any its it's im".split())


# ---------------------------------------------------------------- 1. mine
def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
    return ""


def _ts(s):
    try:
        return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def mine(roots=ROOTS, since=0.0, until=None):
    """Every message Eddie wrote (typed or queued mid-turn) and every side-agent note in the window."""
    until = until or 9e12
    out = []
    for root in roots:
        for f in glob.glob(os.path.join(root, "*", "*.jsonl")):
            try:
                if os.path.getmtime(f) < since:
                    continue
                fh = open(f, errors="replace")
            except OSError:
                continue
            last = ""
            with fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("isSidechain") or str(d.get("entrypoint", "")).startswith("sdk"):
                        continue        # subagents and headless `claude -p` jobs are not Eddie
                    kind = d.get("type")
                    if kind == "assistant":
                        t = _text((d.get("message") or {}).get("content")).strip()
                        if t:
                            last = t
                        continue
                    text, src = "", None
                    a = d.get("attachment")
                    if kind == "attachment" and isinstance(a, dict) and a.get("type") == "queued_command" \
                            and (a.get("origin") or {}).get("kind") == "human":
                        text, src = str(a.get("prompt") or ""), "eddie"
                    elif kind == "user" and not d.get("isMeta"):
                        text, src = _text((d.get("message") or {}).get("content")), "eddie"
                    text = text.strip()
                    if not text or text.startswith(SKIP_PREFIXES) or re.fullmatch(r"(\[Image #\d+\]\s*)+", text):
                        continue
                    if text.startswith(SIDE_NOTE):
                        src = "side-agent"
                    t = _ts(d.get("timestamp"))
                    if t is None or not since <= t < until:
                        continue
                    out.append({"ts": t, "session": d.get("sessionId") or os.path.basename(f)[:36],
                                "project": os.path.basename(os.path.dirname(f)), "source": src,
                                "text": text[:900], "before": last[-400:]})
    out.sort(key=lambda m: m["ts"])
    return out


# ---------------------------------------------------------------- 2. lessons + match
def parse_lesson(path):
    try:
        with open(path, errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return None
    m = re.match(r"---\n(.*?)\n---\n?(.*)", raw, re.S)
    if not m:
        return None
    head, body = m.group(1), m.group(2)
    def field(k):
        f = re.search(r"^\s*%s:\s*(.+)$" % k, head, re.M)        # type sits under metadata:, indented
        return f.group(1).strip().strip('"') if f else ""
    sigs, in_sigs = [], False
    for ln in head.splitlines():
        if re.match(r"\s+signatures:\s*$", ln):
            in_sigs = True
            continue
        if in_sigs:
            s = re.match(r"\s+-\s+(.+)$", ln)
            if s:
                sigs.append(s.group(1).strip().strip('"\''))
                continue
            in_sigs = False
    return {"file": os.path.basename(path), "path": path, "name": field("name"), "description": field("description"),
            "type": field("type"), "signatures": sigs, "recurrences": len(re.findall(r"^- \d{4}-\d\d-\d\d: ", body, re.M))}


def lessons(mem=MEM):
    out = []
    for p in sorted(glob.glob(os.path.join(mem, "*.md"))):
        b = os.path.basename(p)
        if b == "MEMORY.md" or b.startswith("_"):
            continue
        les = parse_lesson(p)
        if les and les["type"] in ("feedback", "project", "user", "reference"):
            out.append(les)
    return out


def _words(s):
    return {w for w in re.findall(r"[a-z0-9']{3,}", s.lower()) if w not in STOP}


def match(miss, pool, k=6):
    """The k lessons whose signatures, name and description share the most words with the miss (and what preceded it)."""
    mw = _words(miss["text"] + " " + miss["before"][-200:])
    scored = []
    for les in pool:
        sig = _words(" ".join(les["signatures"]))
        rest = _words(les["name"].replace("-", " ").replace("_", " ") + " " + les["description"])
        s = 2 * len(mw & sig) + len(mw & rest)
        if s:
            scored.append((s, les["file"]))
    return [f for _, f in sorted(scored, key=lambda x: (-x[0], x[1]))[:k]]


# ---------------------------------------------------------------- 3. judge
PROMPT = """You are the nightly correcting pass over an AI assistant's memory (the assistant works for Eddie).
Below are the messages Eddie wrote today (and notes from side agents that reviewed the assistant), each with what the
assistant had just said and the closest existing memory lessons. Decide, for EACH message, one kind:

- "recurred": Eddie corrects, rejects or is frustrated by something an EXISTING candidate lesson already covers (the
  lesson was filed and did not hold). Give that lesson's file.
- "new": a real correction or a side-agent catch of a mistake that NO candidate lesson covers, and that is likely to
  happen again. Draft the lesson.
- "fact": Eddie states a fact that contradicts something the assistant believed (a date, an account, a person, a
  status). Say what the fact is, and set "lesson" to the candidate lesson file the fact CONTRADICTS (null if none).
- "noise": an instruction, a question, approval, chit-chat, or a one-off with nothing to learn. MOST messages are noise.

Be strict: a request is not a miss. Only real misses count. Return ONLY a JSON array, one object per message:
{"i": <index>, "kind": "...", "lesson": "<file or null>", "symptom": "<2-6 word lowercase phrase: the FAILURE as it
would appear if it happened again, e.g. 'shipped without running tests'>", "summary": "<one plain sentence: what went
wrong>", "rule": "<for new only: the rule, one sentence>", "why": "<for new only: one sentence>"}

MESSAGES:
"""


def judge(misses, cands, model, run=None):
    items = []
    for i, m in enumerate(misses):
        items.append({"i": i, "source": m["source"], "message": m["text"][:700], "assistant_before": m["before"][-300:],
                      "candidate_lessons": cands[i]})
    prompt = PROMPT + json.dumps(items, indent=1)
    run = run or _claude
    raw = run(prompt, model)
    arr = re.search(r"\[.*\]", raw or "", re.S)
    if not arr:
        raise ValueError("model returned no JSON array")
    out = json.loads(arr.group(0))
    return [v for v in out if isinstance(v, dict) and isinstance(v.get("i"), int) and 0 <= v["i"] < len(misses)]


def _claude(prompt, model):
    p = subprocess.run(["claude", "-p", "--model", model, "--output-format", "json"], input=prompt,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=900)
    if p.returncode != 0:
        raise RuntimeError("claude rc=%d: %s" % (p.returncode, p.stderr[-300:]))
    try:
        return json.loads(p.stdout).get("result", "")
    except ValueError:
        return p.stdout


# ---------------------------------------------------------------- 4. fix (reversible)
class Changes(object):
    """Every write goes through here: back up first, log it, so `undo <date>` restores the night exactly."""

    def __init__(self, date, dry=False, root=DREAM):
        self.date, self.dry = date, dry
        self.bak = os.path.join(root, "backups", date)
        self.log = []

    def backup(self, path):
        if self.dry:
            return
        os.makedirs(self.bak, exist_ok=True)
        key = hashlib.sha1(path.encode()).hexdigest()[:12] + "-" + os.path.basename(path)
        dst = os.path.join(self.bak, key)
        if not os.path.exists(dst):
            if os.path.exists(path):
                shutil.copy2(path, dst)
            else:
                open(dst + ".absent", "w").close()
            with open(os.path.join(self.bak, "manifest.jsonl"), "a") as fh:
                fh.write(json.dumps({"path": path, "backup": dst, "existed": os.path.exists(path)}) + "\n")

    def write(self, path, text, what):
        self.log.append({"path": path, "what": what})
        if self.dry:
            return
        self.backup(path)
        tmp = path + ".dream-tmp"
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)


def undo(date, root=DREAM):
    man = os.path.join(root, "backups", date, "manifest.jsonl")
    if not os.path.exists(man):
        return ["nothing to undo for %s" % date]
    done = []
    with open(man) as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    for r in reversed(rows):
        if r["existed"]:
            shutil.copy2(r["backup"], r["path"])
            done.append("restored %s" % r["path"])
        elif os.path.exists(r["path"]):
            os.rename(r["path"], r["path"] + ".undone-" + date)     # never delete: a file we created is set aside
            done.append("set aside %s" % r["path"])
    return done


def add_recurrence(les, verdict, date, ch):
    """A lesson that did not hold gets the evidence in its body and the new symptom in its signatures."""
    with open(les["path"], errors="replace") as fh:
        raw = fh.read()
    line = "- %s: %s" % (date, verdict.get("summary", "").strip()[:240])
    if line in raw:
        return False
    sym = (verdict.get("symptom") or "").strip().lower()[:80]
    if sym and sym not in [s.lower() for s in les["signatures"]]:
        if re.search(r"^\s+signatures:\s*$", raw, re.M):
            raw = re.sub(r"^(\s+)signatures:\s*$", lambda m: "%ssignatures:\n%s  - %s" % (m.group(1), m.group(1), sym),
                         raw, count=1, flags=re.M)
        elif re.search(r"^metadata:\s*$", raw, re.M):
            raw = re.sub(r"^metadata:\s*$", "metadata:\n  signatures:\n    - %s" % sym, raw, count=1, flags=re.M)
    if "\n## Recurrences\n" not in raw:
        raw = raw.rstrip("\n") + "\n\n## Recurrences\n(the nightly correcting dream logs each time this lesson did not hold)\n"
    raw = raw.rstrip("\n") + "\n" + line + "\n"
    ch.write(les["path"], raw, "recurrence + signature: %s" % les["file"])
    return True


DRAFT_EXPIRE_DAYS = 21


def _status(path):
    try:
        with open(path, errors="replace") as fh:
            m = re.search(r"^\s*status:\s*(\S+)", fh.read(2000), re.M)
    except OSError:
        return None
    return m.group(1) if m else None


def waiting_drafts(root=DREAM):
    out = []
    for p in sorted(glob.glob(os.path.join(root, "drafts", "*.md"))):
        if _status(p) == "draft":
            d = parse_lesson(p)
            if d:
                out.append(d)
    return out


def draft_match(verdict, drafts):
    """The waiting draft that describes the same failure (shared symptom words), or None."""
    vs = _words(verdict.get("symptom") or "")
    vr = _words(" ".join([verdict.get("rule") or "", verdict.get("summary") or ""]))
    best, score = None, 0
    for d in drafts:
        ds = _words(" ".join(d["signatures"]))
        s = 2 * len(vs & ds) + len((vs | vr) & _words(d["description"]))
        if (len(vs & ds) >= 2 or s >= 5) and s > score:
            best, score = d, s
    return best


def promote(d, verdict, miss, date, ch, mem=MEM, index=INDEX):
    """A new mistake that happened again earns its place: the draft becomes a live lesson (grain G1 -> G2 on
    recurrence, outer-loop SPEC), with both dates as evidence, and gets a line on the memory index."""
    with open(d["path"], errors="replace") as fh:
        raw = fh.read()
    first = os.path.basename(d["path"])[:10]
    base = d["name"] if d["name"].startswith("feedback-") else "feedback-" + d["name"]
    dst = os.path.join(mem, base + ".md")
    n = 2
    while os.path.exists(dst):
        dst = os.path.join(mem, "%s-%d.md" % (base, n))
        n += 1
    live = re.sub(r"^\s*status:\s*draft\s*\n", "", raw, count=1, flags=re.M)
    live = live.replace("**How to apply:** (review before filing into memory)",
                        "**How to apply:** follow the rule above; filed by the correcting dream after it happened twice.")
    live = live.rstrip("\n") + ("\n\n## Recurrences\n(the nightly correcting dream logs each time this lesson did not hold)\n"
                                "- %s: first seen (drafted)\n- %s: %s\n" % (first, date, (verdict.get("summary") or "").strip()[:240]))
    ch.write(dst, live, "promoted draft -> live lesson %s" % os.path.basename(dst))
    ch.write(d["path"], re.sub(r"^(\s*)status:\s*draft", r"\1status: promoted", raw, count=1, flags=re.M)
             .rstrip("\n") + "\n\nPromoted %s to %s.\n" % (date, os.path.basename(dst)), "draft marked promoted")
    with open(index) as fh:
        idx = fh.read().split("\n")
    at = next((i for i, l in enumerate(idx) if l.startswith("## Unfiled")), None)
    title = (d["description"] or base)[:90].rstrip(".")
    line = "- [%s (%s)](%s): promoted by the correcting dream after it recurred" % (
        title, dt.date.fromisoformat(date).strftime("%m/%d"), os.path.basename(dst))
    if at is None:
        idx += ["", "## Unfiled (sentinel)", line]
    else:
        idx.insert(at + 1, line)
    ch.write(index, "\n".join(idx), "index line for %s" % os.path.basename(dst))
    return dst


def expire_drafts(now, ch, root=DREAM, days=DRAFT_EXPIRE_DAYS):
    """A draft that never happened again in `days` days was a one-off: marked expired, kept, never deleted."""
    n = 0
    for d in waiting_drafts(root):
        try:
            born = dt.datetime.strptime(os.path.basename(d["path"])[:10], "%Y-%m-%d").timestamp()
        except ValueError:
            continue
        if now - born > days * 86400:
            with open(d["path"], errors="replace") as fh:
                raw = fh.read()
            ch.write(d["path"], re.sub(r"^(\s*)status:\s*draft", r"\1status: expired", raw, count=1, flags=re.M),
                     "draft expired (no recurrence in %d days)" % days)
            n += 1
    return n


def draft(verdict, miss, date, ch, root=DREAM):
    slug = re.sub(r"[^a-z0-9]+", "-", (verdict.get("symptom") or "lesson").lower()).strip("-")[:50] or "lesson"
    path = os.path.join(root, "drafts", "%s-%s.md" % (date, slug))
    text = ("---\nname: feedback-%s\ndescription: %s\nmetadata:\n  type: feedback\n  status: draft\n  signatures:\n"
            "    - %s\n---\n\n%s\n\n**Why:** %s\n\n**How to apply:** (review before filing into memory)\n\n"
            "Source: %s message, session %s, %s.\n" % (
                slug, (verdict.get("rule") or verdict.get("summary") or "").strip()[:200], slug.replace("-", " "),
                (verdict.get("rule") or "").strip(), (verdict.get("why") or verdict.get("summary") or "").strip(),
                miss["source"], miss["session"][:8], dt.datetime.fromtimestamp(miss["ts"]).strftime("%Y-%m-%d %H:%M")))
    if not ch.dry:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    ch.write(path, text, "lesson draft: %s" % os.path.basename(path))
    return path


def fit_index(date, ch, index=INDEX, mem=MEM, limit=INDEX_LIMIT, target=INDEX_TARGET, max_lines=INDEX_LINES):
    """MEMORY.md is cut from the bottom when it is over the load limit (11/06: 28.3 KB, 18 lines lost every
    session). Move the oldest dated Unfiled entries into that month's dispatch file, leaving one pointer."""
    with open(index) as fh:
        lines = fh.read().split("\n")
    size = len("\n".join(lines).encode())
    if size <= limit and len(lines) <= max_lines:
        return 0
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("## Unfiled"))
    except StopIteration:
        return 0
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    movable = [i for i in range(start + 1, end) if lines[i].startswith("- [")]   # pointers + nested lines stay
    month = dt.date.fromisoformat(date).strftime("%Y_%m")
    disp = os.path.join(mem, "_dispatch_unfiled_%s.md" % month)
    def when(i):                                         # the "(11/03)" in the label; the section is not in order
        d = re.search(r"\((\d{1,2})/(\d{1,2})\b", lines[i])
        return (int(d.group(1)), int(d.group(2))) if d else (0, 0)
    movable.sort(key=lambda i: (when(i), i))
    moved = []
    for i in movable:                                    # oldest first
        if size <= target and len(lines) - len(moved) <= max_lines:
            break
        moved.append(i)
        size -= len(lines[i].encode()) + 1
    if not moved:
        return 0
    taken = [lines[i] for i in moved]
    if os.path.exists(disp):
        with open(disp) as fh:
            dtext = fh.read().rstrip("\n") + "\n"
    else:
        dtext = ("---\nname: _dispatch_unfiled_%s\ndescription: Unfiled lessons from %s moved off MEMORY.md to keep it "
                 "under the load limit\nmetadata:\n  type: project\n---\n\n" % (month, month.replace("_", "-")))
    dtext += "\n".join(taken) + "\n"
    keep = [l for j, l in enumerate(lines) if j not in set(moved)]
    ptr = "- **Moved off the index %s** (sub-index: `%s`, %d lines): oldest Unfiled entries, by the correcting dream" % (
        date, os.path.basename(disp), len(taken))
    at = next(i for i, l in enumerate(keep) if l.startswith("## Unfiled")) + 1
    keep.insert(at, ptr)
    ch.write(disp, dtext, "index overflow -> %s (%d lines)" % (os.path.basename(disp), len(taken)))
    ch.write(index, "\n".join(keep), "MEMORY.md under the load limit (-%d lines)" % len(taken))
    return len(taken)


def repeated_findings(dream=DREAM, nights=7, need=3):
    """A file named in dream-pass findings on `need` of the last `nights` nights: report-only for too long."""
    files = sorted(glob.glob(os.path.join(dream, "synthesis-*.md")))[-nights:]
    seen = {}
    for f in files:
        with open(f, errors="replace") as fh:
            for ln in fh:
                if not ln.startswith("- **"):
                    continue
                # a finding is about its FIRST named file; the others are context (11/07: one bullet filed two rows)
                for slug in [x for x in re.findall(r"`([A-Za-z0-9_.\-]+\.md)`", ln) if x != "MEMORY.md"][:1]:
                    seen.setdefault(slug, []).append((os.path.basename(f)[10:20], re.sub(r"\*\*", "", ln[2:]).strip()[:200]))
    return {s: v for s, v in seen.items() if len({d for d, _ in v}) >= need}


def board_row(key, text, ledger, ch, board=BOARD):
    """ONE row per key, ever: the board gets the item once, then the item's own row carries its state."""
    if key in ledger:
        return False
    ledger[key] = ch.date
    with open(board, errors="replace") as fh:
        cur = fh.read()
    ch.write(board, cur.rstrip("\n") + "\n" + text + "\n", "board: %s" % key)
    return True


# ---------------------------------------------------------------- 5. run
def run(hours=24, dry=False, use_llm=True, now=None, roots=ROOTS, mem=MEM, index=INDEX, dream=DREAM, board=BOARD,
        model=None, judge_fn=None):
    now = now or dt.datetime.now().timestamp()
    date = dt.datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    ch = Changes(date, dry, dream)
    rep = {"date": date, "misses": 0, "recurred": [], "new": [], "promoted": [], "fact": [], "noise": 0, "origin": 0, "errors": [],
           "index_moved": 0, "repeat_rows": [], "expired": 0}
    led_path = os.path.join(dream, "correct-ledger.json")
    try:
        with open(led_path) as fh:
            ledger = json.load(fh)
    except (OSError, ValueError):
        ledger = {}
    seen = ledger.setdefault("seen", {})
    for k in [k for k, t in seen.items() if t < now - 4 * 86400]:
        del seen[k]                                  # a message older than the window can never come back
    msgs = [m for m in mine(roots, now - hours * 3600, now) if _key(m) not in seen]   # judged once, never twice
    rep["messages"] = len(msgs)
    if len(msgs) > MAX_MESSAGES:
        rep["errors"].append("%d messages in the window; judged the last %d" % (len(msgs), MAX_MESSAGES))
        msgs = msgs[-MAX_MESSAGES:]
    pool = lessons(mem)
    by_file = {l["file"]: l for l in pool}
    verdicts = []
    if msgs and use_llm:
        mdl = model or _model()
        for b in range(0, len(msgs), BATCH):
            chunk = msgs[b:b + BATCH]
            try:
                for v in judge(chunk, [match(m, pool) for m in chunk], mdl, judge_fn):
                    v["i"] += b
                    verdicts.append(v)
                for m in chunk:                      # only a batch that came back is marked judged
                    seen[_key(m)] = m["ts"]
            except Exception as e:                   # noqa: BLE001 a failed batch must not stop the rest or the hygiene
                rep["errors"].append("judge %d-%d: %s" % (b, b + len(chunk) - 1, e))
    for v in verdicts:
        m = msgs[v["i"]]
        kind = v.get("kind")
        if kind == "recurred" and v.get("lesson") in by_file and m["ts"] < _born(by_file[v["lesson"]]["path"]):
            rep["origin"] += 1                       # the message that CREATED the lesson is not a recurrence of it
        elif kind == "recurred" and v.get("lesson") in by_file:
            les = by_file[v["lesson"]]
            try:
                if add_recurrence(les, v, date, ch):
                    rep["recurred"].append({"lesson": les["file"], "summary": v.get("summary"), "times": les["recurrences"] + 1})
                    if les["recurrences"] + 1 >= 2 and les["type"] == "feedback":
                        board_row("g3:" + les["file"], "- [open: EDDIE] DREAM.g3-%s: lesson `%s` did not hold %d times "
                                  "(latest %s: %s). Memory alone is not enough; candidate for a guard/hook (G3, your call "
                                  "per outer-loop SPEC)." % (les["file"][:-3], les["file"], les["recurrences"] + 1, date,
                                                             (v.get("summary") or "")[:160]), ledger, ch, board)
                    les["recurrences"] += 1          # a second miss the same night counts as the second
            except OSError as e:
                rep["errors"].append("recurrence %s: %s" % (les["file"], e))
        elif kind in ("recurred", "new"):
            twin = None if ch.dry else draft_match(v, waiting_drafts(dream))
            if twin and m["source"] != "eddie" and not _from_eddie(twin["path"]):
                twin = None                          # a lesson goes live only if Eddie himself hit it at least once
            if twin:
                try:
                    rep["promoted"].append({"lesson": os.path.basename(promote(twin, v, m, date, ch, mem, index)),
                                            "summary": v.get("summary")})
                except OSError as e:
                    rep["errors"].append("promote %s: %s" % (twin["file"], e))
            else:
                rep["new"].append({"draft": draft(v, m, date, ch, dream), "summary": v.get("summary")})
        elif kind == "fact":
            les = by_file.get(v.get("lesson") or "")
            rep["fact"].append({"summary": v.get("summary"), "session": m["session"][:8], "lesson": les and les["file"]})
            if les:                                  # only a fact that contradicts a note we hold needs settling
                board_row("fact:" + les["file"], "- [open: EDDIE] DREAM.fact-%s: your message %s says: %s. Memory note "
                          "`%s` may say otherwise; confirm and the note gets corrected." % (
                              les["file"][:-3], dt.datetime.fromtimestamp(m["ts"]).strftime("%m/%d %H:%M"),
                              (v.get("summary") or "").rstrip(".")[:200], les["file"]), ledger, ch, board)
        else:
            rep["noise"] += 1
    rep["misses"] = len(rep["recurred"]) + len(rep["new"]) + len(rep["promoted"]) + len(rep["fact"])
    try:
        rep["expired"] = expire_drafts(now, ch, dream)
    except OSError as e:
        rep["errors"].append("expire: %s" % e)
    try:
        rep["index_moved"] = fit_index(date, ch, index, mem)
    except (OSError, ValueError) as e:
        rep["errors"].append("index: %s" % e)
    try:
        for slug, hits in sorted(repeated_findings(dream).items()):
            if board_row("repeat:" + slug, "- [open: OPS] DREAM.repeat-%s: dream-pass flagged `%s` on %d nights "
                         "(%s to %s) and nothing changed: %s" % (slug[:-3], slug, len({d for d, _ in hits}), hits[0][0],
                                                                 hits[-1][0], hits[-1][1]), ledger, ch, board):
                rep["repeat_rows"].append(slug)
    except OSError as e:
        rep["errors"].append("repeats: %s" % e)
    rep["changed"] = len([c for c in ch.log if not c["path"].startswith(os.path.join(dream, ""))])
    if not dry:
        os.makedirs(dream, exist_ok=True)
        with open(led_path, "w") as fh:
            json.dump(ledger, fh, indent=1)
        with open(os.path.join(dream, "misses-%s.json" % date), "w") as fh:
            json.dump(rep, fh, indent=1)
        with open(os.path.join(dream, "correct-%s.md" % date), "w") as fh:
            fh.write(render(rep, ch.log))
    rep["changes"] = ch.log
    return rep


def _from_eddie(path):
    try:
        with open(path, errors="replace") as fh:
            return bool(re.search(r"^Source: eddie message", fh.read(), re.M))
    except OSError:
        return False


def _key(m):
    return hashlib.sha1(("%s|%s|%s" % (m["session"], m["ts"], m["text"][:80])).encode()).hexdigest()[:16]


def _born(path):
    st = os.stat(path)
    return getattr(st, "st_birthtime", st.st_mtime)


def _model():
    try:
        return subprocess.run([os.path.join(HOME, ".hydra", "bin", "hydra-llm"), "model", "mid", "--lane", "sub"],
                              stdout=subprocess.PIPE, universal_newlines=True, timeout=30).stdout.strip() or "sonnet"
    except (OSError, subprocess.SubprocessError):
        return "sonnet"


def render(rep, log):
    out = ["# Correcting dream %s" % rep["date"], "",
           "%d of %d messages were misses: %d lesson(s) did not hold, %d new, %d fact(s). %d noise." % (
               rep["misses"], rep.get("messages", 0), len(rep["recurred"]), len(rep["new"]), len(rep["fact"]), rep["noise"]), ""]
    if rep["recurred"]:
        out.append("## Lessons that did not hold")
        out += ["- `%s` (x%d): %s" % (r["lesson"], r["times"], r["summary"]) for r in rep["recurred"]]
        out.append("")
    if rep["promoted"]:
        out.append("## Drafts that happened again, now live lessons")
        out += ["- `%s`: %s" % (p["lesson"], p["summary"]) for p in rep["promoted"]]
        out.append("")
    if rep["new"]:
        out.append("## New lesson drafts (filed automatically if they happen again; expire after %d days)" % DRAFT_EXPIRE_DAYS)
        out += ["- %s: `%s`" % (n["summary"], n["draft"]) for n in rep["new"]]
        out.append("")
    if rep["fact"]:
        out.append("## Facts to confirm (on the board)")
        out += ["- %s" % f["summary"] for f in rep["fact"]]
        out.append("")
    out.append("## Memory hygiene")
    out.append("- MEMORY.md: %s" % ("%d lines moved to the month's dispatch file" % rep["index_moved"] if rep["index_moved"] else "under the limit"))
    out.append("- repeated dream-pass findings sent to the board: %s" % (", ".join(rep["repeat_rows"]) or "none new"))
    if rep["errors"]:
        out += ["", "## Errors"] + ["- %s" % e for e in rep["errors"]]
    out += ["", "## Every change (undo: dream_correct.py undo %s)" % rep["date"]] + ["- %s" % c["what"] for c in log]
    return "\n".join(out) + "\n"


def section(rep):
    """The misses half, as it joins the dream (DREAM.md): plain, short, no machinery."""
    if not rep.get("messages"):
        return ""
    out = ["", "## What went wrong", ""]
    if not rep["misses"]:
        out.append("Nothing worth learning from today: %d messages, no misses." % rep["messages"])
    for r in rep["recurred"]:
        out.append("- A lesson we already had did not hold (%s, x%d): %s" % (r["lesson"][:-3], r["times"], r["summary"]))
    for p in rep.get("promoted", []):
        out.append("- Happened again, so it is now a lesson (%s): %s" % (p["lesson"][:-3], p["summary"]))
    for n in rep["new"]:
        out.append("- New: %s (drafted; it becomes a lesson if it happens again)" % n["summary"])
    for f in rep["fact"]:
        out.append("- You set a fact straight: %s (on the board to confirm)" % f["summary"])
    if rep.get("index_moved"):
        out.append("- Tidied: %d old lines moved off the memory index so the whole index loads again." % rep["index_moved"])
    if rep.get("errors"):
        out.append("- The correcting pass hit %d problem(s); see ~/.claude/dream/correct-%s.md." % (len(rep["errors"]), rep["date"]))
    if rep.get("changed"):
        out += ["", "%d memory change(s) tonight, every one backed up. Undo the night: `python3 ~/.hydra/tools/dream_correct.py "
                "undo %s`. Details: ~/.claude/dream/correct-%s.md" % (rep["changed"], rep["date"], rep["date"])]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="run", choices=["run", "undo", "section"])
    ap.add_argument("date", nargs="?", help="undo: the night (YYYY-MM-DD); section: a misses-<date>.json path")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-llm", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "undo":
        if not a.date:
            ap.error("undo needs a date")
        print("\n".join(undo(a.date)))
        return 0
    if a.cmd == "section":
        with open(a.date) as fh:
            sys.stdout.write(section(json.load(fh)))
        return 0
    rep = run(hours=a.hours, dry=a.dry_run, use_llm=not a.no_llm)
    print(render(rep, rep["changes"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
