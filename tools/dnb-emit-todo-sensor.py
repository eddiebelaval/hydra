#!/usr/bin/env python3
"""dnb-emit-todo-sensor.py - emit the D&B (Donato & Brill) install engagement's open
todos as a living-sensor JSON in the common master-todo schema.

READER it feeds: ~/.hydra/tools/master-todo.py (merges every job's sensor).
OUTPUT: ~/.hydra/sensors/todos/dnb-install.json

D&B IS A REGULATED CLIENT. Hard rules baked in here:
  - NO comms sweep. This script never reads email/message bodies and never posts
    anything to a model API. It reads two sanctioned sources only.
  - NO client-DB WRITE. It only ever SELECTs (from the board, if enabled). It never
    writes to any client/prod DB, and never touches the firm's legal matter DB.

TWO SOURCES (owes first, board optional):
  1. OWES (source of truth today) - the durable, Eddie-owned open items, operator-
     maintained at ~/.hydra/sensors/owes/dnb.json. Transcribed from the engagement
     STATE doc by hand, not swept. Tickable.
  2. BOARD (opt-in, read-only) - the purpose-built `public.tasks` board on the
     "dnb-build" DB (ref yhzusrkiuqjvougthgrr, the INTERNAL Jon+Eddie build board,
     NOT the firm's privileged legal DB stpokpajkgseyphmgmnm). Only queried when
     SUPABASE_DNB_BOARD_ANON_KEY is set in the environment. As of 2026-08-13 the
     board is STALE (last row update 2026-07-13) so it stays OFF until Eddie adopts
     it as the live store; then set the env var and it merges in with zero code change.

Items from both sources are merged and de-duped by id (owes wins on collision).
If a source is enabled but unreadable, the script SAYS so on stderr and degrades to
the other source rather than faking a clean list.
"""

import datetime
import json
import os
import sys
import urllib.request
import urllib.error

JOB = "dnb-install"
WHO = "D&B (Rose Brill)"
HOME = {"repo": "eddiebelaval/donato-brill-build", "kind": "forward-deployment-install"}

OWES_PATH = os.path.expanduser("~/.hydra/sensors/owes/dnb.json")
OUT_PATH = os.path.expanduser("~/.hydra/sensors/todos/dnb-install.json")

# Board (opt-in). Ref is public/known; the anon key must come from the environment.
BOARD_URL = os.environ.get("SUPABASE_DNB_BOARD_URL", "https://yhzusrkiuqjvougthgrr.supabase.co")
BOARD_KEY = os.environ.get("SUPABASE_DNB_BOARD_ANON_KEY", "")
OPEN_STATUSES = ("todo", "in_progress", "blocked")

PRIORITY_RANK = {"urgent": 1, "high": 8, "normal": 20, "low": 30}


def priority_enum_from_int(prio, status):
    if status == "blocked":
        return "high"
    if prio <= 1:
        return "urgent"
    if prio == 2:
        return "high"
    if prio <= 4:
        return "normal"
    return "low"


def item(title, priority, rank, due_on, pod, source, completable, iid):
    return {
        "title": title,
        "priority": priority,
        "rank": rank,
        "dueOn": due_on,
        "pod": pod,
        "source": source,
        "completable": completable,
        "id": iid,
    }


# ---- source 1: owes (durable, operator-maintained) ---------------------------
def load_owes():
    if not os.path.exists(OWES_PATH):
        return []
    try:
        with open(OWES_PATH) as f:
            parsed = json.load(f)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"owes: could not read {OWES_PATH}: {e}\n")
        return []
    rows = parsed if isinstance(parsed, list) else parsed.get("owes", [])
    out = []
    for r in rows:
        if r.get("done"):
            continue
        prio = r.get("priority") if r.get("priority") in PRIORITY_RANK else "high"
        out.append(item(
            title=r["title"],
            priority=prio,
            rank=PRIORITY_RANK[prio],
            due_on=r.get("dueOn"),
            pod=r.get("owner"),
            source="written",
            completable=True,
            iid=r.get("id") or f"owes:{r['title'][:40]}",
        ))
    return out


# ---- source 2: board (opt-in, read-only) -------------------------------------
def fetch_board():
    """Returns (items, reachable). reachable False -> caller degrades to owes-only."""
    if not BOARD_KEY:
        return [], None  # disabled, not an error
    status_filter = ",".join(OPEN_STATUSES)
    url = (
        f"{BOARD_URL}/rest/v1/tasks"
        f"?select=id,title,owner,status,priority,updated_at"
        f"&status=in.({status_filter})"
        f"&order=priority.asc"
    )
    req = urllib.request.Request(url, headers={"apikey": BOARD_KEY, "Authorization": f"Bearer {BOARD_KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            rows = json.loads(resp.read().decode())
    except (urllib.error.URLError, ValueError) as e:
        sys.stderr.write(f"board: unreadable ({e}); degrading to owes-only\n")
        return [], False
    out = []
    for r in rows:
        prio = int(r.get("priority", 2) or 2)
        status = r.get("status", "todo")
        pe = priority_enum_from_int(prio, status)
        out.append(item(
            title=r["title"],
            priority=pe,
            rank=prio,               # board priority int is already lower=first
            due_on=None,             # tasks board carries no due date
            pod=r.get("owner"),
            source="written",
            completable=True,
            iid=str(r["id"]),
        ))
    return out, True


def main():
    argv = sys.argv[1:]

    owes = load_owes()
    board, board_reachable = fetch_board()

    # merge, owes wins on id collision
    by_id = {}
    for it in board:
        by_id[it["id"]] = it
    for it in owes:
        by_id[it["id"]] = it
    items = sorted(by_id.values(), key=lambda x: (x["rank"], x["title"]))

    sensor = {
        "job": JOB,
        "who": WHO,
        "home": HOME,
        "generatedAt": datetime.datetime.now().isoformat(timespec="minutes"),
        "counts": {"open": len(items), "written": len(items), "derived": 0},
        "sources": {
            "owes": len(owes),
            "board": "off" if board_reachable is None else ("reachable" if board_reachable else "UNREACHABLE"),
        },
        "items": items,
    }

    if "--dry-run" in argv:
        print(json.dumps(sensor, indent=2))
        return

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(sensor, f, indent=2)
    if board_reachable is False:
        sys.stderr.write("NOTE: board was enabled but unreachable - emitted owes-only.\n")
    if not items:
        sys.stderr.write("NOTE: emitted an EMPTY D&B sensor - no owes and no board rows. Honest, not broken.\n")
    print(f"wrote {OUT_PATH} - {len(items)} open (owes {len(owes)}, board {sensor['sources']['board']})")


if __name__ == "__main__":
    main()
