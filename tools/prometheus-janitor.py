#!/usr/bin/env python3
"""Prometheus queue health check and cleaner.

The release hook (~/.claude/hooks/prometheus_trigger.py) writes one request per
release candidate to requests/<key>.json and moves it pending -> in_review on
ack, but nothing ever closes a request. This tool keeps the queue honest.

  prometheus-janitor.py health            read-only report; exit 1 if anything is stuck
  prometheus-janitor.py clean             dry run: what would be archived
  prometheus-janitor.py clean --apply     move old requests to requests/archive/<date>/

Cleaning never deletes. It only moves request files older than --min-age-hours
(default 24) into the archive folder; receipts, polls and calls are untouched.
The gate re-reads a request only for a candidate being released now, and a
re-release of an archived candidate simply files a fresh request and needs a
fresh poll, which is the safe direction.

State dir: PROMETHEUS_STATE_DIR or ~/.claude/release-gate/prometheus.
"""
import json
import os
import shutil
import sys
import time
from collections import Counter

STATE = os.path.expanduser(os.environ.get("PROMETHEUS_STATE_DIR")
                           or "~/.claude/release-gate/prometheus")
REQ = os.path.join(STATE, "requests")
RCPT = os.path.join(STATE, "receipts")
STUCK_HOURS = 24


def load_requests():
    out = []
    for name in sorted(os.listdir(REQ)) if os.path.isdir(REQ) else []:
        path = os.path.join(REQ, name)
        if not (name.endswith(".json") and os.path.isfile(path)):
            continue
        try:
            with open(path) as f:
                req = json.load(f)
        except (OSError, ValueError):
            req = None
        age_h = (time.time() - os.path.getmtime(path)) / 3600
        key = name[:-5]
        out.append({
            "key": key, "path": path, "age_h": age_h, "req": req,
            "status": (req or {}).get("status", "UNREADABLE"),
            "engagement": ((req or {}).get("candidate") or {}).get("engagement") or "?",
            "receipt": os.path.exists(os.path.join(RCPT, key + ".json")),
        })
    return out


def bucket(age_h):
    return "<1d" if age_h < 24 else "1-7d" if age_h < 168 else ">7d"


def health():
    reqs = load_requests()
    by_status = Counter(r["status"] for r in reqs)
    print(f"Prometheus queue: {len(reqs)} requests in {REQ}")
    for status, n in sorted(by_status.items()):
        ages = Counter(bucket(r["age_h"]) for r in reqs if r["status"] == status)
        print(f"  {status:<11} {n:>4}   " + "  ".join(f"{b} {ages[b]}" for b in ("<1d", "1-7d", ">7d")))
    stuck = [r for r in reqs if r["status"] == "in_review" and not r["receipt"]
             and r["age_h"] >= STUCK_HOURS]
    unreadable = [r for r in reqs if r["status"] == "UNREADABLE"]
    stale = [r for r in reqs if r["age_h"] >= STUCK_HOURS]
    print(f"  stuck reviews (in_review, no receipt, >{STUCK_HOURS}h): {len(stuck)}")
    for r in stuck[:10]:
        print(f"    {r['key']}  {r['engagement']}  {r['age_h'] / 24:.1f}d")
    print(f"  unreadable request files: {len(unreadable)}")
    print(f"  older than {STUCK_HOURS}h (archivable): {len(stale)}")
    ok = not stuck and not unreadable and not stale
    print("HEALTH: " + ("GREEN" if ok else "RED (run: prometheus-janitor.py clean --apply)"))
    return 0 if ok else 1


def clean(apply, min_age_h):
    reqs = [r for r in load_requests() if r["age_h"] >= min_age_h]
    dest = os.path.join(REQ, "archive", time.strftime("%Y-%m-%d"))
    print(f"{'Archiving' if apply else 'Would archive'} {len(reqs)} requests older than "
          f"{min_age_h:g}h -> {dest}")
    for status, n in sorted(Counter(r["status"] for r in reqs).items()):
        print(f"  {status:<11} {n:>4}")
    if not apply:
        print("Dry run. Re-run with --apply to move them.")
        return 0
    os.makedirs(dest, exist_ok=True)
    moved = 0
    for r in reqs:
        target = os.path.join(dest, os.path.basename(r["path"]))
        if os.path.exists(target):
            print(f"  skip {r['key']}: already in the archive")
            continue
        shutil.move(r["path"], target)
        moved += 1
    print(f"Moved {moved}. Undo: mv {dest}/*.json {REQ}/")
    return 0


def main(argv):
    if not argv or argv[0] == "health":
        return health()
    if argv[0] == "clean":
        min_age = 24.0
        if "--min-age-hours" in argv:
            min_age = float(argv[argv.index("--min-age-hours") + 1])
        if min_age < 24:
            print("refusing: --min-age-hours below 24 could archive a live poll")
            return 2
        return clean("--apply" in argv, min_age)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
