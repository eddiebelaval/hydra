#!/usr/bin/env python3
"""briefing-instrument.py - render the morning briefing as the Morning Instrument (v2).

v2 (2026-07-11): HYDRA v1 work layer retired. Petals now read LIVING sensors:
  - the atlas wire (id8-halos client atlases: chains, earned states, standing alerts)
  - the launchd fleet itself (exit codes; a failing job is a crimson bead)
  - hydra.db daily_priorities (the one v1 loop kept alive on purpose)
Sensor-audit law applies (feedback_facelift_requires_sensor_audit): every source
carries its freshness; a stale atlas is SAID to be stale, never passed as current.

Injects data into briefings/instrument/template.html, writes the dated HTML twin.
Prints the output path on success (daily-briefing.sh captures it to open).
"""

import datetime
import glob
import json
import os
import plistlib
import re
import sqlite3
import subprocess
import sys

HOME = os.path.expanduser("~")
HYDRA = os.path.join(HOME, ".hydra")
DB = os.path.join(HYDRA, "hydra.db")
LOGS = os.path.join(HOME, "Library", "Logs", "claude-automation")
TEMPLATE = os.path.join(HYDRA, "briefings", "instrument", "template.html")
OUT_DIR = os.path.join(HYDRA, "briefings")
LAUNCH_AGENTS = os.path.join(HOME, "Library", "LaunchAgents")
HALOS = os.path.join(HOME, "Development", "id8-halos", "clients")

ATLAS_GLOBS = [
    os.path.join(HALOS, "*", "atlas", "atlas.json"),
    os.path.join(HALOS, "*", "engagements", "*", "atlas", "atlas.json"),
]
STALE_DAYS = 3          # an atlas older than this is flagged, not trusted silently
BEAD_CAP = 6


def q(cur, sql, params=()):
    try:
        return cur.execute(sql, params).fetchall()
    except sqlite3.Error:
        return []


# ---------------- the atlas wire: one petal per portfolio line ----------------

def _slug(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def read_atlases(today):
    lines, attention = [], []
    paths = sorted(set(p for g in ATLAS_GLOBS for p in glob.glob(g)))

    loaded = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                loaded.append((path, json.load(f)))
        except Exception:
            attention.append({"who": os.path.basename(os.path.dirname(os.path.dirname(path))).upper(),
                              "text": "atlas.json unreadable", "note": path})

    # two atlases can share a client (studio bloom + engine room). Where the client
    # name collides, the atlas whose engagement is its own thing wears the engagement
    # name; the true client bloom keeps the client name.
    counts = {}
    for _, atlas in loaded:
        c = atlas.get("client") or "?"
        counts[_slug(c)] = counts.get(_slug(c), 0) + 1

    used = set()
    for path, atlas in loaded:
        client = atlas.get("client") or os.path.basename(os.path.dirname(os.path.dirname(path)))
        engagement = str(atlas.get("engagement", ""))
        if counts.get(_slug(client), 0) > 1 and engagement and _slug(engagement) != _slug(client):
            name = engagement.replace("-", " ").title()
        else:
            name = client
        if _slug(name) in used:  # last resort: directory
            name = f"{name} · {os.path.basename(os.path.dirname(os.path.dirname(path)))}"
        used.add(_slug(name))
        chains = atlas.get("chains", [])
        as_of = str(atlas.get("asOf", ""))[:10]
        stale = False
        if as_of:
            try:
                age = (today - datetime.date.fromisoformat(as_of)).days
                stale = age > STALE_DAYS
            except ValueError:
                stale = True

        live = sum(1 for c in chains if c.get("state") == "live")
        building = sum(1 for c in chains if c.get("state") == "building")
        alerted = [c for c in chains if c.get("alert")]

        for c in alerted:
            attention.append({
                "who": name,
                "text": str(c.get("alert", ""))[:130],
                "note": f"{c.get('id', '?')} · since {c.get('alertSince', '?')}"
                        + (f" · {c.get('alertSeverity')}" if c.get("alertSeverity") else ""),
            })

        # beads, base to tip: alerts first (they must be seen), then live, building, the unearned
        beads = (["alert"] * len(alerted)
                 + ["live"] * sum(1 for c in chains if c.get("state") == "live" and not c.get("alert"))
                 + ["building"] * sum(1 for c in chains if c.get("state") == "building" and not c.get("alert"))
                 + ["paper"] * sum(1 for c in chains if c.get("state") in ("proposed", "potential", "scoped") and not c.get("alert")))[:BEAD_CAP]

        state = "alert" if alerted else "live" if live else "building" if building else "idle"
        sub = f"{len(chains)} chains · {live} live"
        if as_of:
            sub += f" · asOf {as_of}"
        if stale:
            sub += " · STALE"
            attention.append({"who": name, "text": f"Atlas is stale (asOf {as_of or 'missing'}): the petal may not reflect reality",
                              "note": "sensor-audit: freshness gate"})

        lines.append({
            "name": name, "sub": sub, "state": state,
            "grow": 0.55 + 0.45 * min(1.0, len(chains) / 8.0),
            "stats": f"{live}L {building}B" + (f" {len(alerted)}!" if alerted else ""),
            "beads": beads, "alerts": len(alerted) + (1 if stale else 0),
        })
    return lines, attention


# ---------------- the fleet: launchd exit codes become a petal ----------------

def read_fleet():
    try:
        out = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return {"total": 0, "failing": []}, None
    total, failing = 0, []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        pid, status, label = parts
        if not (label.startswith("com.hydra.") or label.startswith("com.id8labs.")):
            continue
        total += 1
        # a RUNNING job (pid present) is not failing, whatever its last exit was
        if pid.strip() != "-":
            continue
        if status.strip() not in ("0", "-"):
            failing.append({"label": label, "code": status.strip()})
    fleet = {"total": total, "failing": failing}
    petal = {
        "name": "FLEET", "sub": f"{total} launchd jobs · {len(failing)} failing",
        "state": "alert" if failing else "live",
        "grow": 1.0,
        "stats": f"{total}J" + (f" {len(failing)}!" if failing else ""),
        "beads": (["alert"] * len(failing) or ["live"] * 3)[:BEAD_CAP],
        "alerts": len(failing),
    }
    return fleet, petal


# ---------------- signals: dead sensors exit loudly, not silently ----------------

def latest_report(subdir):
    files = sorted(glob.glob(os.path.join(LOGS, subdir, "report-*.md")), reverse=True)
    return files[0] if files else None


def gather_signals():
    signals = []
    rep = latest_report("seventy-percent-detector")
    if rep:
        try:
            with open(rep, encoding="utf-8") as f:
                items = sum(1 for line in f if line.startswith("- "))
            if items:
                signals.append(f"70% Projects: {items} items need finishing")
        except OSError:
            pass
    rep = latest_report("dependency-guardian")
    if rep:
        try:
            with open(rep, encoding="utf-8") as f:
                for line in f:
                    if "Urgency Level" in line:
                        urgency = line.split(":", 1)[-1].replace("*", "").strip()
                        if urgency and urgency.upper() != "LOW":
                            signals.append(f"Security: {urgency} priority updates needed")
                        break
        except OSError:
            pass
    # marketing streak: emit only if the sensor has ever actually recorded a day
    streak_file = os.path.join(LOGS, "marketing-check", ".marketing-streak")
    if os.path.isfile(streak_file):
        try:
            with open(streak_file, encoding="utf-8") as f:
                raw = f.read().strip()
            streak, _, stamp = raw.partition(":")
            if stamp.strip() and not stamp.strip().startswith("1970"):
                signals.append(f"Marketing Streak: {streak} days")
            else:
                signals.append("Marketing streak sensor never initialized (epoch date): excluded from metrics")
        except OSError:
            pass
    rep = latest_report("context-switch")
    if rep:
        try:
            with open(rep, encoding="utf-8") as f:
                for line in f:
                    if "Focus Score" in line:
                        m = re.search(r"\d+", line)
                        if m:
                            signals.append(f"Focus Score: {m.group(0)}%")
                        break
        except OSError:
            pass
    return signals


def gather_gardener(now):
    """The watcher gets watched: the Gardener (the act layer) is itself a sensor.
    If its last pass is older than the schedule tolerates (runs 8:50/14/20; max
    normal gap ~13h), the garden has quietly stopped healing -- say so loudly.
    Returns (attention_item_or_None, signal_line_or_None)."""
    path = os.path.join(HYDRA, "briefings", "gardener-report.json")
    STALE_HOURS = 18
    try:
        with open(path, encoding="utf-8") as f:
            rep = json.load(f)
        last = datetime.datetime.strptime(rep.get("generatedAt", ""), "%Y-%m-%d %H:%M")
    except Exception:
        return ({"who": "GARDENER", "text": "no gardener report at all: the act layer has never run or its report is unreadable",
                 "note": "the watcher is not watching · check com.id8labs.gardener"}, None)
    age_h = (now - last).total_seconds() / 3600.0
    if age_h > STALE_HOURS:
        return ({"who": "GARDENER", "text": f"last tending pass {age_h:.0f}h ago (> {STALE_HOURS}h): the garden has quietly stopped healing",
                 "note": "the watcher is not watching · check com.id8labs.gardener"}, None)
    s = rep.get("summary", {})
    return (None, f"Gardener: last pass {rep.get('generatedAt', '?')[-5:]} · "
                  f"healed {s.get('healed', 0)} · to tend {s.get('proposed', 0)} · escalated {s.get('escalated', 0)}")


def gather_activity():
    brain = os.path.join(HYDRA, "TECHNICAL_BRAIN.md")
    if not os.path.isfile(brain):
        return []
    try:
        with open(brain, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return []
    m = re.search(r"<!-- BRAIN-UPDATER:START -->(.*?)<!-- BRAIN-UPDATER:END -->", text, re.S)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("## Recent Git Activity") or line.startswith("*Auto-updated"):
            continue
        if line.startswith("**") and line.endswith("**"):
            out.append({"project": line.strip("*")})
        elif line.startswith("- "):
            out.append({"text": line[2:].replace("**", "")})
    return out


def gather_schedule():
    sched = {}
    for path in glob.glob(os.path.join(LAUNCH_AGENTS, "com.hydra.*.plist")) + glob.glob(
        os.path.join(LAUNCH_AGENTS, "com.id8labs.*.plist")
    ):
        try:
            with open(path, "rb") as f:
                plist = plistlib.load(f)
        except Exception:
            continue
        cal = plist.get("StartCalendarInterval")
        if not cal:
            continue
        entries = cal if isinstance(cal, list) else [cal]
        label = re.sub(r"^com\.(hydra|id8labs)\.", "", plist.get("Label", os.path.basename(path)))
        label = label.replace(".plist", "").replace("-", " ")
        for e in entries:
            hour = e.get("Hour")
            if hour is None or "Weekday" in e:
                continue
            h = hour + e.get("Minute", 0) / 60.0
            key = round(h, 2)
            if key not in sched or len(label) < len(sched[key]):
                sched[key] = label
    entries = [{"h": h, "label": lbl.split()[0][:10]} for h, lbl in sorted(sched.items())]
    merged = []
    for e in entries:
        if merged and e["h"] - merged[-1]["h"] < 0.25:
            merged[-1]["n"] = merged[-1].get("n", 1) + 1
        else:
            merged.append(e)
    return merged


def main():
    today = datetime.date.today()
    now = datetime.datetime.now()
    date_str = today.strftime("%Y-%m-%d")

    lines, attention = read_atlases(today)
    fleet, fleet_petal = read_fleet()
    if fleet_petal:
        lines.append(fleet_petal)
        for f_ in fleet["failing"]:
            attention.append({"who": "FLEET", "text": f"{f_['label']} last exit {f_['code']}",
                              "note": "launchctl list · a failing job is nobody's petal no longer"})

    # the watcher gets watched: Gardener liveness is itself a sensor
    g_att, g_sig = gather_gardener(now)
    if g_att:
        attention.append(g_att)
    signals = gather_signals()
    if g_sig:
        signals.append(g_sig)

    data = {
        "date": date_str,
        "dayName": today.strftime("%A"),
        "generatedAt": now.strftime("%H:%M"),
        "priorities": [],
        "attention": attention,
        "lines": lines,
        "fleet": {"total": fleet["total"], "failing": len(fleet["failing"])},
        "signals": signals,
        "projectActivity": gather_activity(),
        "schedule": gather_schedule(),
    }

    # the one v1 loop kept alive on purpose: the 8 AM priorities reply
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        cur = con.cursor()
        for n, desc in q(cur, "SELECT priority_number, description FROM daily_priorities WHERE date=? ORDER BY priority_number", (date_str,)):
            data["priorities"].append({"n": n, "text": desc})
        con.close()
    except sqlite3.Error:
        pass

    # --json: emit the living-sensor payload and stop. No template, no file writes.
    # Used by Mission Control's /system route to render the flower live server-side.
    if "--json" in sys.argv:
        print(json.dumps(data, ensure_ascii=False))
        return 0

    with open(TEMPLATE, encoding="utf-8") as f:
        template = f.read()
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = template.replace("__BRIEFING_JSON__", payload, 1)
    if html == template:
        print("template placeholder __BRIEFING_JSON__ not found", file=sys.stderr)
        return 1

    out_path = os.path.join(OUT_DIR, f"briefing-{date_str}.html")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)

    write_markdown_twin(data)
    write_summary(data)
    print(out_path)
    return 0


def write_markdown_twin(d):
    """The archive twin of the instrument: same sections, same sensors, plain text."""
    att, lines_ = d["attention"], d["lines"]
    verdict = f"ALERTS x{len(att)}" if att else "ALL CLEAR"
    out = [f"# Morning Briefing (Instrument twin)", f"## {d['dayName']}, {d['date']} · {verdict}", ""]
    out += ["## Today's Priorities", ""]
    out += [f"{p['n']}. {p['text']}" for p in d["priorities"]] or ["Not set yet. Reply to the 8 AM prompt."]
    if att:
        out += ["", f"## Attention ({len(att)})", ""]
        out += [f"- **{a['who']}**: {a['text']}" + (f" ({a['note']})" if a.get("note") else "") for a in att]
    out += ["", "## The Lines", ""]
    out += [f"- **{l['name']}** [{l['state'].upper()}] {l['sub']}" for l in lines_]
    out += ["", f"Fleet: {d['fleet']['total'] - d['fleet']['failing']}/{d['fleet']['total']} clean"]
    if d["projectActivity"]:
        out += ["", "## Overnight & Yesterday", ""]
        for a in d["projectActivity"]:
            out.append(f"**{a['project']}**" if "project" in a else f"- {a['text']}")
    if d["signals"]:
        out += ["", "## Signals", ""] + [f"- {s}" for s in d["signals"]]
    out += ["", "---", f"*Living sensors only (atlas wire + launchctl + daily_priorities). Generated {d['generatedAt']}.*", ""]
    with open(os.path.join(OUT_DIR, f"briefing-{d['date']}.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))


def write_summary(d):
    """Telegram/notification summary. First line = priority for notify-eddie.sh."""
    att = d["attention"]
    p0 = any("p0" in (a.get("note") or "") for a in att)
    priority = "urgent" if p0 else "high" if att else "normal"
    verdict = f"ALERTS x{len(att)}" if att else "ALL CLEAR"
    msg = [f"PRIORITY:{priority}", f"Morning Instrument - {d['dayName']} · {verdict}", ""]
    if d["priorities"]:
        msg += ["Priorities:"] + [f"{p['n']}. {p['text']}" for p in d["priorities"]] + [""]
    else:
        msg += ["Priorities: not set (reply to the 8 AM prompt)", ""]
    if att:
        msg += [f"Attention ({len(att)}):"] + [f"- {a['who']}: {a['text'][:80]}" for a in att[:6]]
        if len(att) > 6:
            msg.append(f"...and {len(att) - 6} more on the dial")
        msg.append("")
    msg += [f"Lines: " + " · ".join(f"{l['name']} {l['state'].upper()}" for l in d["lines"])]
    msg += [f"Fleet: {d['fleet']['total'] - d['fleet']['failing']}/{d['fleet']['total']} clean"]
    with open(os.path.join(OUT_DIR, "briefing-summary.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(msg))


if __name__ == "__main__":
    sys.exit(main())
