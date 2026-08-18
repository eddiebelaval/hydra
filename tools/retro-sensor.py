#!/usr/bin/env python3
"""
retro-sensor.py -- the missing trigger for the craft-loop RETRO.

The gap: a craft loop (voz/faro/video) only closes when Eddie runs RETRO by
hand, so a delivery's human signal often never reaches the genome ("a loop
whose RETRO never runs is a generator with extra files"). This wires the Tg:
a delivery is EVENT-captured (craft-retro-capture.sh, PostToolUse:Task), and
this sensor surfaces "RETRO due" into the master briefing whenever there are
deliveries since the loop's last genome update. The human still runs RETRO --
the Attunement Law (only human signal updates the genome) is untouched.

Chain:  Tg(Task:craft-agent) -> Cp(delivery) ==> Tg(daily) -> Wa(deliveries vs
        genome mtime) -> Ro(RETRO-due per loop) -> Ps(sensor) -> No(briefing) -> Hu(RETRO)

Deterministic, $0, no network. Emits the master-todo `items` schema.
"""
import json, os, time
from datetime import datetime

HOME = os.path.expanduser("~")
DELIV = os.path.join(HOME, ".hydra/sensors/craft-retro/deliveries.jsonl")
OUT = os.path.join(HOME, ".hydra/sensors/todos/craft-retro.json")

# loop -> its genome file; last RETRO = newest mtime of the genome or its golden set
LOOPS = {
    "voz":   HOME + "/.claude/skills/voz/VOICE-GENOME.md",
    "faro":  HOME + "/.claude/skills/faro/FARO-GENOME.md",
    "video": HOME + "/.claude/skills/video/VIDEO-GENOME.md",
}


def last_retro(genome_path):
    cands = [genome_path, os.path.join(os.path.dirname(genome_path), "GOLDEN-SET.md")]
    mtimes = [os.path.getmtime(p) for p in cands if os.path.exists(p)]
    return max(mtimes) if mtimes else None


def ts_of(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def main():
    deliveries = []
    if os.path.exists(DELIV):
        for ln in open(DELIV):
            ln = ln.strip()
            if not ln:
                continue
            try:
                deliveries.append(json.loads(ln))
            except Exception:
                pass

    items = []
    for loop, gpath in LOOPS.items():
        lr = last_retro(gpath)
        if lr is None:
            continue
        since = [d for d in deliveries if d.get("loop") == loop and ts_of(d.get("ts")) > lr]
        n = len(since)
        if n > 0:
            days = (time.time() - lr) / 86400.0
            items.append({
                "id": f"retro-{loop}",
                "title": (f"RETRO due on {loop}: {n} deliver{'y' if n == 1 else 'ies'} since the last "
                          f"genome update ({days:.0f}d ago) -- feed the human signal back in"),
                "priority": "normal",
                "rank": 50,
                "pod": "eddie",
                "source": "derived",
                "completable": False,
            })

    payload = {
        "job": "craft-retro",
        "who": "eddie",
        "home": "~/.claude/skills",
        "generatedAt": datetime.now().isoformat(timespec="seconds"),
        "counts": {"open": len(items)},
        "items": items,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(payload, open(OUT, "w"), indent=2)

    # tend self-report: this sensor is itself a tended chain
    try:
        tend = os.path.join(HOME, ".hydra/tend/retro-sensor.json")
        json.dump({"system": "retro-sensor",
                   "asOf": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
                   "status": "GREEN",
                   "detail": f"{len(items)} RETRO(s) due; {len(deliveries)} deliveries tracked",
                   "cadenceHours": 24, "selfHealed": [], "escalate": []}, open(tend, "w"))
    except Exception:
        pass

    print(f"[retro-sensor] {len(items)} RETRO(s) due: {[i['id'] for i in items]}; "
          f"{len(deliveries)} deliveries tracked")


if __name__ == "__main__":
    main()
