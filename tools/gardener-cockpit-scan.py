#!/usr/bin/env python3
"""gardener-cockpit-scan.py -- the deterministic refresher behind the Cockpit.

The Gardener acts (heal / propose / escalate) three times a day and leaves two
trails: gardener-report.json (the CURRENT pass, resets each day) and
gardener-ledger.jsonl (append-only, every pass ever -- the real asset). The
ledger has no visual. This scan turns both into one data file the standalone
cockpit renders: live state now, the chronic view (what's stuck, what flaps,
escalation MTTR), and a per-day trend.

Deterministic, no LLM. Same cadence as the tender: gardener.py kicks it after
each pass, and it can be re-run by hand to rebuild the viz from the ledger.

Reads:  ~/.hydra/briefings/gardener-report.json
        ~/.hydra/briefings/gardener-ledger.jsonl
Writes: ~/.hydra/briefings/gardener-cockpit-data.js  (window.GARDENER_COCKPIT = {...})

Usage:  gardener-cockpit-scan.py
"""
import datetime
import json
import os

HOME = os.path.expanduser("~")
OUT_DIR = os.path.join(HOME, ".hydra", "briefings")
REPORT = os.path.join(OUT_DIR, "gardener-report.json")
LEDGER = os.path.join(OUT_DIR, "gardener-ledger.jsonl")
DATA_JS = os.path.join(OUT_DIR, "gardener-cockpit-data.js")

TREND_DAYS = 21          # how far the per-day trend looks back
STUCK_PASSES = 3         # proposed in this many recent consecutive passes = stuck
FLAP_HEALS = 3           # fleet heals in FLAP_DAYS = a masked fault (mirrors the tender)
FLAP_DAYS = 7
STALE_HOURS = 16         # report older than this = a scheduled tend was missed


def load_report():
    try:
        with open(REPORT) as f:
            return json.load(f)
    except Exception:
        return {}


def load_passes():
    passes = []
    try:
        with open(LEDGER) as f:
            for line in f:
                try:
                    passes.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return passes


def item_key(entry):
    """Stable identity for an item across passes (item + kind)."""
    return f"{entry.get('kind', '?')}::{entry.get('item', '?')}"


def parse_ts(ts):
    try:
        return datetime.datetime.fromisoformat(ts)
    except (ValueError, TypeError):
        return None


def freshness(report, now):
    gen = report.get("generatedAt", "")
    dt = None
    try:
        dt = datetime.datetime.strptime(gen, "%Y-%m-%d %H:%M")
    except (ValueError, TypeError):
        pass
    if not dt:
        return {"generatedAt": gen or "unknown", "ageHours": None, "stale": True}
    age_h = round((now - dt).total_seconds() / 3600, 1)
    return {"generatedAt": gen, "ageHours": age_h, "stale": age_h > STALE_HOURS}


def build_trend(passes, now):
    """Per-day series: healed events summed, proposed/escalated = end-of-day standing."""
    cutoff = (now - datetime.timedelta(days=TREND_DAYS)).date()
    by_day = {}
    for p in passes:
        dt = parse_ts(p.get("ts", ""))
        if not dt or dt.date() < cutoff:
            continue
        day = dt.date().isoformat()
        d = by_day.setdefault(day, {"date": day, "healed": 0, "proposed": 0, "escalated": 0, "_last": ""})
        d["healed"] += len(p.get("healed", []))
        if p.get("ts", "") >= d["_last"]:           # last pass of the day wins for standing sets
            d["_last"] = p.get("ts", "")
            d["proposed"] = len(p.get("proposed", []))
            d["escalated"] = len(p.get("escalated", []))
    out = [{k: v for k, v in d.items() if k != "_last"} for d in by_day.values()]
    return sorted(out, key=lambda x: x["date"])


def build_chronic(passes, report, now):
    """Stuck (long-standing proposals), flapping (repeat heals), escalation MTTR."""
    # first/last seen per item across every pass, split by which bucket it landed in
    seen = {}                                # key -> {first, last, kind, item, why, heal_count, seen_proposed, seen_escalated}
    for p in passes:
        ts = p.get("ts", "")
        for bucket in ("healed", "proposed", "escalated"):
            for e in p.get(bucket, []):
                k = item_key(e)
                s = seen.setdefault(k, {"first": ts, "last": ts, "kind": e.get("kind", "?"),
                                        "item": e.get("item", "?"), "why": e.get("why", ""),
                                        "heals": 0, "proposed_passes": 0, "escalated_passes": 0})
                s["first"] = min(s["first"], ts) if s["first"] else ts
                s["last"] = max(s["last"], ts)
                s["why"] = e.get("why", "") or s["why"]
                if bucket == "healed" and e.get("kind") == "fleet":
                    s["heals"] += 1
                if bucket == "proposed":
                    s["proposed_passes"] += 1
                if bucket == "escalated":
                    s["escalated_passes"] += 1

    latest = passes[-1] if passes else {}
    now_proposed = {item_key(e) for e in latest.get("proposed", [])}
    now_escalated = {item_key(e) for e in latest.get("escalated", [])}

    # STUCK: currently proposed AND seen in many passes -> a standing hand-fix owed
    stuck = []
    for k in now_proposed:
        s = seen.get(k)
        if s and s["proposed_passes"] >= STUCK_PASSES:
            stuck.append({"item": s["item"], "kind": s["kind"], "why": s["why"],
                          "passes": s["proposed_passes"], "since": (s["first"] or "")[:10]})
    stuck.sort(key=lambda x: -x["passes"])

    # FLAPPING: fleet items kickstart-healed >= FLAP_HEALS within FLAP_DAYS
    flap_cutoff = (now - datetime.timedelta(days=FLAP_DAYS)).isoformat()
    flap_counts = {}
    for p in passes:
        if p.get("ts", "") < flap_cutoff:
            continue
        for h in p.get("healed", []):
            if h.get("kind") == "fleet":
                fk = item_key(h)
                flap_counts[fk] = flap_counts.get(fk, 0) + 1
    flapping = [{"item": seen.get(k, {}).get("item", k), "heals": n}
                for k, n in flap_counts.items() if n >= FLAP_HEALS]
    flapping.sort(key=lambda x: -x["heals"])

    # ESCALATIONS: every item that ever escalated, with resolve state + MTTR
    escalations = []
    for k, s in seen.items():
        if s["escalated_passes"] == 0:
            continue
        first, last = parse_ts(s["first"]), parse_ts(s["last"])
        ongoing = k in now_escalated
        end = now if ongoing else (last or now)
        mttr_h = round(((end - first).total_seconds() / 3600), 1) if first else None
        escalations.append({"item": s["item"], "kind": s["kind"], "why": s["why"],
                            "first": (s["first"] or "")[:16], "last": (s["last"] or "")[:16],
                            "ongoing": ongoing, "hours": mttr_h})
    escalations.sort(key=lambda x: (not x["ongoing"], -(x["hours"] or 0)))

    return {"stuck": stuck, "flapping": flapping, "escalations": escalations}


def main():
    now = datetime.datetime.now()
    report = load_report()
    passes = load_passes()

    data = {
        "generated": now.isoformat(timespec="seconds"),
        "cadence": ["08:50", "14:00", "20:00"],
        "freshness": freshness(report, now),
        "live": {
            "date": report.get("date", ""),
            "applied": report.get("applied", False),
            "summary": report.get("summary", {"healed": 0, "proposed": 0, "escalated": 0}),
            "healed": report.get("healed", []),
            "proposed": report.get("proposed", []),
            "escalated": report.get("escalated", []),
            "sweeps": report.get("sweeps", []),
        },
        "trend": build_trend(passes, now),
        "chronic": build_chronic(passes, report, now),
        "ledger": {"passes": len(passes),
                   "first": (passes[0].get("ts", "")[:10] if passes else ""),
                   "last": (passes[-1].get("ts", "")[:16] if passes else "")},
    }

    with open(DATA_JS, "w") as f:
        f.write("window.GARDENER_COCKPIT = " + json.dumps(data, ensure_ascii=False) + ";\n")

    c = data["chronic"]
    print(f"cockpit: {len(passes)} passes | live {data['live']['summary']} | "
          f"stuck {len(c['stuck'])} flapping {len(c['flapping'])} "
          f"escalations {len(c['escalations'])} -> {DATA_JS}")


if __name__ == "__main__":
    main()
