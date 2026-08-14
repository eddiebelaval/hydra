#!/usr/bin/env python3
"""master-todo.py - merge every job's todo sensor into one ranked master.

Each job (Lexicon, D&B, Datatech, ...) emits its open todos as a living sensor
JSON in ~/.hydra/sensors/todos/<job>.json, all in one common schema. This is the
READER over those sensors: it never stores todos of its own, it only merges and
ranks what the jobs publish, so no list is ever duplicated. See the memory
project-every-job-sweeper-to-master-todo.

Output:
  - stdout / --md  : the master list as markdown, top of the stack first
  - --json <path>  : the master as JSON, for the briefing instrument to inject

Ranking: overdue first, then due-today, then the job's own rank, so the one
thing with a clock on it is always line one.
"""

import datetime
import glob
import json
import os
import sys

HOME = os.path.expanduser("~")
SENSOR_DIR = os.path.join(HOME, ".hydra", "sensors", "todos")

PRIORITY_LABEL = {"urgent": "URGENT", "high": "high", "normal": "", "low": "low", "derived": "watch"}


def today_iso():
    n = datetime.date.today()
    return n.isoformat()


def load_sensors():
    items = []
    stale = []
    today = today_iso()
    for path in sorted(glob.glob(os.path.join(SENSOR_DIR, "*.json"))):
        try:
            with open(path) as f:
                s = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            stale.append((os.path.basename(path), f"unreadable: {e}"))
            continue
        gen = str(s.get("generatedAt", ""))[:10]
        if gen and gen < today:
            # A sensor whose emitter has not run today is SAID to be stale, never
            # passed as current (sensor-audit law).
            stale.append((s.get("job", os.path.basename(path)), f"last emitted {gen}"))
        for it in s.get("items", []):
            it = dict(it)
            it["job"] = s.get("job", "?")
            it["who"] = s.get("who", it["job"])
            items.append(it)
    return items, stale


def sort_key(it, today):
    due = it.get("dueOn")
    # 0 overdue, 1 today, 2 dated-future, 3 undated
    if due and due < today:
        bucket = 0
    elif due and due == today:
        bucket = 1
    elif due:
        bucket = 2
    else:
        bucket = 3
    return (bucket, it.get("rank", 999), due or "9999-99-99", it.get("title", ""))


def render_md(items, stale, today):
    if not items:
        return "## Your list\n\nNothing on the list across any job.\n"
    ordered = sorted(items, key=lambda it: sort_key(it, today))
    hot = [it for it in ordered if it.get("dueOn") and it["dueOn"] <= today and it.get("source") != "derived"]
    lines = ["## Your list, top of the stack", ""]
    lines.append(f"_{len(items)} across {len({it['job'] for it in items})} job(s)"
                 + (f", {len(hot)} with a clock on them today" if hot else "") + "._")
    lines.append("")
    for it in ordered:
        due = it.get("dueOn")
        if due and due < today:
            tag = "**OVERDUE**"
        elif due and due == today:
            tag = "**today**"
        elif due:
            tag = due
        else:
            tag = PRIORITY_LABEL.get(it.get("priority", ""), "")
        pod = f" ({it['pod']})" if it.get("pod") else ""
        tagpart = f" - {tag}" if tag else ""
        lines.append(f"- [{it['who']}]{pod} {it['title']}{tagpart}")
    if stale:
        lines.append("")
        lines.append("_Stale sensors (shown but may be behind): "
                     + "; ".join(f"{j} ({why})" for j, why in stale) + "._")
    return "\n".join(lines) + "\n"


def main():
    today = today_iso()
    items, stale = load_sensors()
    md = render_md(items, stale, today)

    if "--json" in sys.argv:
        out = sys.argv[sys.argv.index("--json") + 1]
        ordered = sorted(items, key=lambda it: sort_key(it, today))
        with open(out, "w") as f:
            json.dump({"generatedAt": datetime.datetime.now().isoformat(timespec="minutes"),
                       "count": len(items), "items": ordered, "stale": stale}, f, indent=2)
        print(f"wrote master json: {out}")
    else:
        sys.stdout.write(md)


if __name__ == "__main__":
    main()
