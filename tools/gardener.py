#!/usr/bin/env python3
"""gardener.py - The Gardener: tends the garden (the flower of chains on /system).

The flower is the READ layer (living sensors -> visual). The Gardener is the ACT
layer: it reads the SAME sensors, classifies every red thing, and heals it,
proposes a fix, or escalates -- by a hard autonomy boundary:

  AUTO      internal + reversible + no external effect  -> heal now, verify, log
  PROPOSE   internal + needs judgment                   -> emit the fix, do not run
  ESCALATE  client / job-dependent / irreversible       -> route out, never touch

Client/job-dependent items (D&B, Datatech, ...) are NEVER auto-touched -- they
only ever escalate. Sensor-audit law holds: a stale atlas is re-surveyed from real
state or SAID to be stale, never fake-stamped to a green it did not earn.

Writes gardener-report.json (+ a readable .md) that the flower renders as a
"Tended" strip. Run with --apply to perform auto-heals; default is a dry run.

Usage:
  gardener.py            # dry run: classify + propose, no changes
  gardener.py --apply    # perform AUTO heals (internal, reversible only)
"""
import datetime
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
HYDRA = os.path.join(HOME, ".hydra")
OUT_DIR = os.path.join(HYDRA, "briefings")
STATE_DIR = os.path.join(HYDRA, "state")
LAUNCH_AGENTS = os.path.join(HOME, "Library", "LaunchAgents")
HALOS = os.path.join(HOME, "Development", "id8-halos", "clients")
NOTIFY = os.path.join(HYDRA, "daemons", "notify-eddie.sh")
LEDGER = os.path.join(OUT_DIR, "gardener-ledger.jsonl")
LOCK = os.path.join(STATE_DIR, "gardener.lock")
ESC_STATE = os.path.join(STATE_DIR, "gardener-escalated.json")
STALE_DAYS = 3
FLAP_HEALS = 3     # same fleet item kickstart-healed this many times in FLAP_DAYS = a masked fault
FLAP_DAYS = 7

# A label/atlas is CLIENT (escalate-only) if its slug carries one of these.
CLIENT_HINTS = ("dnb", "donato", "brill", "datatech", "rose", "profesa", "lola", "nixon")

# Sensor jobs report STATUS via exit code (YELLOW=1, RED=2). Their non-zero exit
# is a reading, not a fault -- restarting them would silence a real signal, the
# same sin as fake-stamping a stale atlas. Surface the finding; never kickstart.
SENSOR_PAT = re.compile(r"(-health|-sentinel|\.health|\.sentinel)$")

APPLY = "--apply" in sys.argv


def is_sensor(label):
    return bool(SENSOR_PAT.search(label))


# Internal atlases that have a deterministic, sensor-audit-honest surveyor: the
# Gardener can AUTO re-survey these (never fake-stamp; the surveyor verifies real
# state before it stamps). Others stay PROPOSE.
ATLAS_SURVEYORS = {
    "homer": os.path.join(HALOS, "homer", "atlas", "survey.py"),
    "engineroom": os.path.join(HALOS, "engine-room", "atlas", "survey.py"),
    "id8labs": os.path.join(HALOS, "id8labs", "atlas", "survey.py"),
}


def atlas_is_stale(path, today):
    try:
        with open(path) as f:
            as_of = str(json.load(f).get("asOf", ""))[:10]
        return (today - datetime.date.fromisoformat(as_of)).days > STALE_DAYS if as_of else True
    except Exception:
        return True


def slug(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def is_client(name):
    s = slug(name)
    return any(h in s for h in CLIENT_HINTS)


def sh(args, timeout=15):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


# ---------------------------------------------------------------- fleet sensor
def fleet_failures():
    out = sh(["launchctl", "list"])
    fails = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        pid, status, label = parts
        if not (label.startswith("com.hydra.") or label.startswith("com.id8labs.")):
            continue
        if pid.strip() != "-":            # currently running: not a failure
            continue
        if status.strip() not in ("0", "-"):
            fails.append({"label": label, "code": status.strip()})
    return fails


def job_logs(label):
    plist = os.path.join(LAUNCH_AGENTS, f"{label}.plist")
    if not os.path.isfile(plist):
        return None, ""
    paths = []
    for key in ("StandardErrorPath", "StandardOutPath"):
        p = sh(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", plist]).strip()
        if p and os.path.isfile(p):
            paths.append(p)
    tail = ""
    for p in paths:
        try:
            with open(p, errors="replace") as f:
                lines = [l.rstrip() for l in f if l.strip()]
            if lines:
                tail = "\n".join(lines[-4:])
                break
        except OSError:
            pass
    return (paths[0] if paths else None), tail


def diagnose(label):
    """Read the job's logs and name a likely cause + suggested fix."""
    logpath, tail = job_logs(label)
    low = tail.lower()
    cause, fix = "unknown", "read the log and reproduce by hand"
    if "credential" in low or "vercel login" in low or "no existing credentials" in low:
        cause = "not authenticated (missing token/login)"
        fix = "provision a token for the job's env (interactive login is Eddie's)"
    elif "-1712" in low or "timed out" in low or "appleevent" in low:
        cause = "a notify path (Messages/osascript) times out under launchd"
        fix = "make the notify non-fatal: append ` || true` to the osascript/messenger call"
    elif "command not found" in low or "no such file" in low or ": not found" in low:
        cause = "a command is missing from the launchd PATH"
        fix = "export a full PATH at the top of the script (launchd has a minimal PATH)"
    elif "traceback" in low or "error:" in low:
        cause = "a runtime error"
        last = [l for l in tail.splitlines() if l.strip()]
        fix = f"last line: {last[-1][:120]}" if last else "see the log"
    return {"cause": cause, "fix": fix, "evidence": tail[-300:], "log": logpath}


def kickstart_and_verify(label):
    """AUTO remediation for a transient failure: restart, then read the new exit.
    Returns 'healed' if it comes back clean, else 'persistent'."""
    sh(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"])
    # poll up to ~8s for the run to finish (pid returns to '-')
    for _ in range(16):
        out = sh(["launchctl", "list"])
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[2] == label:
                pid, status = parts[0].strip(), parts[1].strip()
                if pid == "-":                      # finished
                    return "healed" if status in ("0", "-") else "persistent"
        time.sleep(0.5)
    return "persistent"


# --------------------------------------------------------------- atlas sensor
def stale_atlases(today):
    out = []
    globs = [os.path.join(HALOS, "*", "atlas", "atlas.json"),
             os.path.join(HALOS, "*", "engagements", "*", "atlas", "atlas.json")]
    for path in sorted(set(p for g in globs for p in glob.glob(g))):
        try:
            with open(path) as f:
                atlas = json.load(f)
        except Exception:
            continue
        name = atlas.get("engagement") or atlas.get("client") or os.path.basename(os.path.dirname(os.path.dirname(path)))
        as_of = str(atlas.get("asOf", ""))[:10]
        stale = False
        if as_of:
            try:
                stale = (today - datetime.date.fromisoformat(as_of)).days > STALE_DAYS
            except ValueError:
                stale = True
        else:
            stale = True
        if stale:
            out.append({"name": str(name), "asOf": as_of or "missing", "path": path})
    return out


# ------------------------------------------------------- ledger + flap + notify
def recent_heal_counts(days=FLAP_DAYS):
    """Per-item count of fleet kickstart-heals in the last N days, off the ledger.
    Atlas re-surveys are excluded: an atlas re-staling on the freshness clock is
    normal maintenance; a daemon that needs repeated restarts is a masked fault."""
    counts = {}
    cutoff = (datetime.datetime.now() - datetime.timedelta(days=days)).isoformat()
    try:
        with open(LEDGER) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("ts", "") < cutoff:
                    continue
                for h in e.get("healed", []):
                    if h.get("kind") == "fleet":
                        counts[h["item"]] = counts.get(h["item"], 0) + 1
    except OSError:
        pass
    return counts


def notify_escalations(escalated):
    """Deliver ESCALATE for real: notify Eddie when the escalated SET changes
    (a new fire, not the same standing one three times a day). State survives
    across passes; a resolved item drops off and re-notifies if it re-fires."""
    current = {e["item"]: e.get("why", "") for e in escalated}
    prev = {}
    try:
        with open(ESC_STATE) as f:
            prev = json.load(f).get("items", {})
    except Exception:
        pass
    new = {k: v for k, v in current.items() if k not in prev}
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(ESC_STATE, "w") as f:
        json.dump({"items": current, "at": datetime.datetime.now().isoformat()}, f)
    if not new or not os.access(NOTIFY, os.X_OK):
        return bool(new)
    worst = "urgent" if any(re.search(r"\bp0\b|exit 2", w) for w in new.values()) else "high"
    lines = [f"- {k}: {v}" for k, v in new.items()]
    msg = "The Gardener escalates (new, not auto-touched):\n" + "\n".join(lines)
    subprocess.run([NOTIFY, worst, "The Gardener", msg], capture_output=True, timeout=30)
    return True


# ------------------------------------------------------------------ the tend
def tend():
    today = datetime.date.today()
    now = datetime.datetime.now()
    healed, proposed, escalated = [], [], []
    flap = recent_heal_counts()

    # 1) the fleet
    for f in fleet_failures():
        label, code = f["label"], f["code"]
        sensor = is_sensor(label)
        if is_client(label):
            why = (f"exit {code} — status reading, not a broken job" if sensor
                   else f"exit {code}; client/job-dependent job")
            escalated.append({"kind": "reading" if sensor else "fleet", "item": label,
                              "why": why, "route": "the engagement track (never auto-touched)"})
            continue
        if sensor:
            # its exit code IS the reading; surface it, never restart to "fix"
            logpath, _ = job_logs(label)
            proposed.append({"kind": "reading", "item": label,
                             "why": f"exit {code} — status sensor reporting non-nominal",
                             "cause": "the exit code is the reading (not a fault)",
                             "fix": "resolve the underlying finding; do not restart the sensor",
                             "log": logpath})
            continue
        if flap.get(label, 0) >= FLAP_HEALS:
            # restarts keep "working": that's a masked fault, not a heal
            d = diagnose(label)
            proposed.append({"kind": "flap", "item": label,
                             "why": f"exit {code}, kickstart-healed {flap[label]}x in {FLAP_DAYS}d — flapping",
                             "cause": "repeated restarts are masking a real fault",
                             "fix": d["fix"], "log": d["log"]})
            continue
        if APPLY:
            result = kickstart_and_verify(label)
            if result == "healed":
                healed.append({"kind": "fleet", "item": label, "action": "kickstart", "now": "exit 0"})
                continue
        d = diagnose(label)
        proposed.append({"kind": "fleet", "item": label, "why": f"exit {code} (persistent)",
                         "cause": d["cause"], "fix": d["fix"], "log": d["log"]})

    # 2) the atlas wire (freshness)
    for a in stale_atlases(today):
        if is_client(a["name"]):
            escalated.append({"kind": "atlas", "item": a["name"],
                              "why": f"stale (asOf {a['asOf']})",
                              "route": "the engagement track"})
            continue
        surveyor = ATLAS_SURVEYORS.get(slug(a["name"]))
        if APPLY and surveyor and os.path.isfile(surveyor):
            rc = subprocess.run([sys.executable, surveyor, "--apply"],
                                capture_output=True, text=True, timeout=45).returncode
            if rc == 0 and not atlas_is_stale(a["path"], today):
                healed.append({"kind": "atlas", "item": a["name"], "action": "re-survey", "now": "asOf refreshed"})
                continue
            if rc == 3:
                proposed.append({"kind": "atlas", "item": a["name"], "why": f"stale (asOf {a['asOf']})",
                                 "cause": "the surveyor needs a human (Homer moved, or a gate to rule on)",
                                 "fix": "re-author the bloom / clear the gate", "log": a["path"]})
                continue
        # no surveyor, or dry run: propose a real re-survey (never fake-stamp)
        proposed.append({"kind": "atlas", "item": a["name"], "why": f"stale (asOf {a['asOf']})",
                         "cause": "internal atlas not re-surveyed",
                         "fix": "regenerate from real state (re-survey), then stamp asOf",
                         "log": a["path"]})

    # today's sweeps: each real (--apply) pass leaves a mark on the day dial.
    report_path = os.path.join(OUT_DIR, "gardener-report.json")
    prior = []
    try:
        with open(report_path) as f:
            old = json.load(f)
        if old.get("date") == today.isoformat():
            prior = old.get("sweeps", [])
    except Exception:
        pass
    sweeps = list(prior)
    if APPLY:
        sweeps.append({"at": now.strftime("%H:%M"), "h": round(now.hour + now.minute / 60.0, 3),
                       "healed": len(healed), "proposed": len(proposed), "escalated": len(escalated)})
    sweeps = sweeps[-12:]

    report = {
        "date": today.isoformat(),
        "generatedAt": now.strftime("%Y-%m-%d %H:%M"),
        "applied": APPLY,
        "healed": healed,
        "proposed": proposed,
        "escalated": escalated,
        "sweeps": sweeps,
        "summary": {"healed": len(healed), "proposed": len(proposed), "escalated": len(escalated)},
    }
    # ESCALATE delivers: notify on set-change only (never re-spam a standing fire)
    if APPLY:
        report["notified"] = notify_escalations(escalated)

    with open(report_path, "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)

    # append-only ledger: the audit trail the daily report can't be (it resets).
    # Feeds flap detection and any future eval of the Gardener's own judgment.
    with open(LEDGER, "a") as f:
        f.write(json.dumps({"ts": now.isoformat(timespec="seconds"), "applied": APPLY,
                            "healed": healed, "proposed": proposed, "escalated": escalated},
                           ensure_ascii=False) + "\n")

    # readable twin
    md = [f"# The Gardener - {'tended' if APPLY else 'dry run'} {report['generatedAt']}",
          f"healed {len(healed)} | proposed {len(proposed)} | escalated {len(escalated)}", ""]
    if healed:
        md += ["## Healed (auto)"] + [f"- {h['item']}: {h['action']} -> {h['now']}" for h in healed] + [""]
    if proposed:
        md += ["## Proposed (needs a hand)"] + [f"- {p['item']} - {p['why']}: {p['cause']}. FIX: {p['fix']}" for p in proposed] + [""]
    if escalated:
        md += ["## Escalated (client / job-dependent - not touched)"] + [f"- {e['item']} - {e['why']} -> {e['route']}" for e in escalated] + [""]
    with open(os.path.join(OUT_DIR, "gardener-report.md"), "w") as f:
        f.write("\n".join(md))

    return report


if __name__ == "__main__":
    # one gardener at a time: the scheduled pass and a "Tend" click must not
    # both rewrite atlases/report concurrently. Non-blocking; the loser yields.
    os.makedirs(STATE_DIR, exist_ok=True)
    _lockf = open(LOCK, "w")
    try:
        fcntl.flock(_lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Gardener: another pass is running; yielding.")
        sys.exit(0)
    r = tend()
    s = r["summary"]
    print(f"Gardener {'APPLIED' if r['applied'] else '(dry run)'}: "
          f"healed {s['healed']} | proposed {s['proposed']} | escalated {s['escalated']}")
    for bucket, tag in (("healed", "HEAL"), ("proposed", "PROPOSE"), ("escalated", "ESCALATE")):
        for it in r[bucket]:
            extra = it.get("now") or it.get("cause") or it.get("why", "")
            print(f"  [{tag:8}] {it['item']:38} {extra}")
