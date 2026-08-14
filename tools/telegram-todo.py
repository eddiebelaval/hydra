#!/usr/bin/env python3
"""telegram-todo.py - capture a todo sent from Telegram into the master.

The Telegram input leg of the every-job-to-master-todo engine. Eddie texts a todo
from his phone; it lands as a living-sensor item that the morning briefing's master
already reads. This is the INBOX capture buffer - the one sensor the master writes
to rather than only reads, because a phone-captured todo has no upstream job store
yet. An optional leading `#job` tag routes the item's owner label.

Usage:
  telegram-todo.py "call the accountant tomorrow"      # add (default)
  telegram-todo.py "#dnb ask Jon for the log"          # add, tagged to a job
  telegram-todo.py --list                              # show open inbox items
  telegram-todo.py --done <id-prefix>                  # close one by id prefix

Emits/updates ~/.hydra/sensors/todos/inbox.json in the common schema. Human gate
intact: capture only, no side effects, nothing sent or merged anywhere.
"""

import json
import os
import re
import sys
import datetime

SENSOR = os.path.expanduser("~/.hydra/sensors/todos/inbox.json")
KNOWN_JOBS = {"dnb", "datatech", "90day", "lexicon", "llc", "homer"}
PRIORITY_RANK = {"urgent": 1, "high": 8, "normal": 20, "low": 30}


def load():
    if not os.path.exists(SENSOR):
        return {
            "job": "inbox",
            "who": "Inbox (Telegram)",
            "home": {"repo": None, "kind": "inbox"},
            "generatedAt": "",
            "counts": {"open": 0, "written": 0, "derived": 0},
            "items": [],
        }
    with open(SENSOR) as f:
        return json.load(f)


def stamp():
    return datetime.datetime.now().isoformat(timespec="minutes")


def save(sensor):
    sensor["generatedAt"] = stamp()
    items = sensor["items"]
    sensor["counts"] = {"open": len(items), "written": len(items), "derived": 0}
    os.makedirs(os.path.dirname(SENSOR), exist_ok=True)
    with open(SENSOR, "w") as f:
        json.dump(sensor, f, indent=2)


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:32]


def add(text):
    text = text.strip()
    if not text:
        print("nothing to add")
        return
    pod = None
    m = re.match(r"^#(\w+)\s+(.*)$", text)
    if m and m.group(1).lower() in KNOWN_JOBS:
        pod = m.group(1).lower()
        text = m.group(2).strip()
    # priority cue: a leading ! marks urgent
    priority = "normal"
    if text.startswith("!"):
        priority = "urgent"
        text = text[1:].strip()
    sensor = load()
    now = datetime.datetime.now()
    iid = f"tg:{now.strftime('%Y%m%d-%H%M%S')}-{slug(text)}"
    sensor["items"].append({
        "title": text,
        "priority": priority,
        "rank": PRIORITY_RANK[priority],
        "dueOn": None,
        "pod": pod,
        "source": "written",
        "completable": True,
        "id": iid,
    })
    save(sensor)
    tag = f" [{pod}]" if pod else ""
    print(f"captured{tag}: {text}")


def list_items():
    sensor = load()
    items = sensor.get("items", [])
    if not items:
        print("inbox empty")
        return
    for it in sorted(items, key=lambda x: x["rank"]):
        tag = f"#{it['pod']} " if it.get("pod") else ""
        star = "! " if it["priority"] == "urgent" else ""
        print(f"{it['id'][:22]}  {star}{tag}{it['title']}")


def done(prefix):
    sensor = load()
    before = len(sensor["items"])
    matched = [it for it in sensor["items"] if it["id"].startswith(prefix) or it["id"][3:].startswith(prefix)]
    if not matched:
        print(f"no inbox item matching '{prefix}'")
        return
    ids = {it["id"] for it in matched}
    sensor["items"] = [it for it in sensor["items"] if it["id"] not in ids]
    save(sensor)
    print(f"done: {matched[0]['title']}" + (f" (+{before - len(sensor['items']) - 1} more)" if len(matched) > 1 else ""))


def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: telegram-todo.py <text> | --list | --done <id>")
        return
    if argv[0] == "--list":
        list_items()
    elif argv[0] == "--done":
        done(argv[1] if len(argv) > 1 else "")
    else:
        add(" ".join(argv))


if __name__ == "__main__":
    main()
