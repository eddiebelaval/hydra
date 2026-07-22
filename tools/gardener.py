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

# --- Phase 1 sensors (folded from the reporter into the tender) --------------
# Disk pressure is INTERNAL: it never escalates. AUTO reclaim is REGENERABLE
# ONLY (TM local snapshots, pnpm store, npm cache) and fires only below target;
# the heavy mass (Library/Development) is PROPOSE, never auto-deleted.
DATA_VOLUME = "/System/Volumes/Data"   # the real user-data volume (not the sealed system snapshot)
# Measured the SAME way the canonical check does (hydra-heartbeat.sh: df -k avail
# / 1048576 GB) so the gardener and the heartbeat never disagree on ground truth.
# 20G is heartbeat's warning line -- the gardener starts reclaiming right there.
# (df's "available" on APFS counts purgeable space, so it swings as macOS makes
# and drops local snapshots; that swing is exactly what regenerable reclaim is for.)
LOW_DISK_GB = 20                       # below this, disk is a finding worth tending
# A secret in a last-24h diff is ESCALATE (never auto-touch a secret), P0.
SECRET_REPOS = [os.path.join(HOME, "Development", "id8"),
                os.path.join(HOME, "clawd", "projects", "dae-v2")]
SECRET_PATTERN = re.compile(
    r"sk-ant-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+|"
    r"ghp_[A-Za-z0-9]{30,}|xoxb-[0-9A-Za-z-]+|https://hooks\.slack\.com/services/")
# Dependency-guardian report: critical/high need a human to bump -> PROPOSE.
DEPGUARD_DIR = os.path.join(HOME, "Library", "Logs", "claude-automation", "dependency-guardian")
# Memory brain health (the sentinel self-heals its own lane; the gardener surfaces).
OBSERVATORY_HEALTH = os.path.join(HOME, "Development", "id8", "observatory", "data", "health.json")
# The cockpit's deterministic refresher; the tender kicks it after each pass.
COCKPIT_SCAN = os.path.join(HYDRA, "tools", "gardener-cockpit-scan.py")
# Phase 3: the tend contract. Born-tendable systems self-report here; the
# Gardener AGGREGATES their reports instead of inferring health from exit codes.
TEND_DIR = os.path.join(HYDRA, "tend")
TEND_STALE_GRACE = 1.5     # a system silent past cadenceHours * this = it stopped reporting

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


def which(cmd):
    return bool(sh(["/usr/bin/which", cmd]).strip())


# ----------------------------------------------------------------- disk sensor
def free_gb(volume=DATA_VOLUME):
    """Available space on the data volume, in GB. None if it can't be read."""
    out = sh(["df", "-k", volume])
    lines = out.splitlines()
    if len(lines) < 2:
        return None
    parts = lines[1].split()
    try:                                   # df -k cols: fs blocks used AVAIL cap ...
        return int(parts[3]) / (1024 * 1024)
    except (IndexError, ValueError):
        return None


def reclaim_regenerables(need_gb):
    """AUTO disk heal: reclaim ONLY regenerable/reversible space -- never a file a
    human can't trivially get back. Returns [(name, note)] of what actually ran."""
    done = []
    # 1) purgeable Time Machine local snapshots (macOS-managed, regenerates).
    need_bytes = max(int(need_gb * 1024 ** 3), 1024 ** 3)
    r = sh(["tmutil", "thinlocalsnapshots", "/", str(need_bytes), "1"], timeout=90)
    if r.strip():
        done.append(("tm-local-snapshots", r.strip().splitlines()[-1][:80]))
    # 2) pnpm store: drop unreferenced packages (safe -- referenced ones stay).
    if which("pnpm"):
        sh(["pnpm", "store", "prune"], timeout=120)
        done.append(("pnpm-store-prune", "unreferenced packages pruned"))
    # 3) npm cache: regenerates on next install.
    if which("npm"):
        sh(["npm", "cache", "clean", "--force"], timeout=120)
        done.append(("npm-cache-clean", "cache cleared (regenerates)"))
    return done


# --------------------------------------------------------------- secret sensor
def secret_hits():
    """High-signal grep over the last 24h of git diffs. A hit is a P0 escalate."""
    per_repo = {}
    for repo in SECRET_REPOS:
        if not os.path.isdir(os.path.join(repo, ".git")):
            continue
        diff = sh(["git", "-C", repo, "log", "--since=24 hours ago", "-p", "--no-color"], timeout=60)
        if not diff:
            continue
        c = sum(1 for line in diff.splitlines() if SECRET_PATTERN.search(line))
        if c:
            per_repo[os.path.basename(repo)] = c
    return per_repo


# ----------------------------------------------------------- dependency sensor
def dep_counts():
    """Latest dependency-guardian report: critical/high counts (PROPOSE fodder)."""
    if not os.path.isdir(DEPGUARD_DIR):
        return None
    reports = sorted(glob.glob(os.path.join(DEPGUARD_DIR, "report-*.md")))
    if not reports:
        return None
    try:
        txt = open(reports[-1], errors="replace").read()
    except OSError:
        return None
    def grab(sev):
        m = re.search(rf"^\|\s*{sev}\s*\|[^0-9]*([0-9]+)", txt, re.M)
        return int(m.group(1)) if m else 0
    return {"critical": grab("Critical"), "high": grab("High"),
            "report": os.path.basename(reports[-1])}


# --------------------------------------------------------- memory-brain sensor
def sentinel_health():
    """The observatory's health.json: the brain sentinel's own verdict."""
    try:
        with open(OBSERVATORY_HEALTH) as f:
            return json.load(f)
    except Exception:
        return None


# ----------------------------------------------------- tend-contract aggregator
def tend_reports():
    """Read every born-tendable system's self-report (~/.hydra/tend/*.json)."""
    out = []
    for path in sorted(glob.glob(os.path.join(TEND_DIR, "*.json"))):
        try:
            with open(path) as f:
                out.append(json.load(f))
        except Exception:
            continue
    return out


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

    # born-tendable systems speak for themselves (section 7). Read their reports
    # up front so the fleet sensor can DEFER to a self-report instead of inferring
    # health from a launchd exit code -- one authoritative signal per system.
    reports = tend_reports()
    tended = {str(r.get("system", "")).strip() for r in reports if r.get("system")}

    # 1) the fleet
    for f in fleet_failures():
        label, code = f["label"], f["code"]
        sensor = is_sensor(label)
        short = label.replace("com.hydra.", "").replace("com.id8labs.", "")
        if short in tended:
            continue        # tendable: its self-report is the truth, not its exit code
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

    # 3) disk pressure (internal; regenerable-only AUTO, heavy mass PROPOSE)
    fg = free_gb()
    if fg is not None and fg < LOW_DISK_GB:
        if APPLY:
            done = reclaim_regenerables(LOW_DISK_GB - fg)
            after = free_gb() or fg
            if after - fg > 0.05:
                healed.append({"kind": "disk", "item": "data-volume", "action": "reclaim regenerables",
                               "now": f"{fg:.1f}G -> {after:.1f}G free (+{after - fg:.1f}G): "
                                      + ", ".join(n for n, _ in done)})
            if after < LOW_DISK_GB:
                proposed.append({"kind": "disk", "item": "data-volume",
                                 "why": f"{after:.1f}G free (< {LOW_DISK_GB}G target) after auto-reclaim",
                                 "cause": "regenerable caches alone can't clear it; the mass is in Library/Development",
                                 "fix": "run the disk audit: review ~/.npm ~/.cache ~/.pnpm-store, large node_modules, "
                                        "Xcode DerivedData, and stale Development repos", "log": None})
        else:
            proposed.append({"kind": "disk", "item": "data-volume",
                             "why": f"{fg:.1f}G free (< {LOW_DISK_GB}G target)",
                             "cause": "disk low; regenerable reclaim available but not applied (dry run)",
                             "fix": "the scheduled --apply pass reclaims TM snapshots + pnpm store + npm cache",
                             "log": None})

    # 4) secret scan (P0 escalate; never auto-touch a secret)
    for repo, c in secret_hits().items():
        escalated.append({"kind": "secret", "item": f"{repo} (last-24h diff)",
                          "why": f"p0 — {c} secret-shaped line(s) in commits from the last 24h",
                          "route": "rotate + scrub the history before any push (never auto-touched)"})

    # 5) dependency-guardian (needs a human to bump -> PROPOSE)
    dc = dep_counts()
    if dc and (dc["critical"] > 0 or dc["high"] > 0):
        proposed.append({"kind": "deps", "item": "dependency-guardian",
                         "why": f"critical {dc['critical']}, high {dc['high']} ({dc['report']})",
                         "cause": "vulnerable dependencies need a human to bump/patch",
                         "fix": "review the dependency-guardian report and update the flagged packages",
                         "log": None})

    # 6) memory-brain health (sentinel self-heals its lane; the gardener surfaces)
    shealth = sentinel_health()
    if shealth:
        st = str(shealth.get("status", "")).upper()
        if st == "RED":
            escalated.append({"kind": "sentinel", "item": "memory-brain",
                              "why": f"observatory health RED (as of {shealth.get('date', '?')})",
                              "route": "the brain is compromised — inspect observatory/data/health.json"})
        elif st == "YELLOW":
            bad = [c.get("id") for c in shealth.get("checks", []) if not c.get("ok")]
            proposed.append({"kind": "sentinel", "item": "memory-brain",
                             "why": f"observatory health YELLOW ({', '.join(b for b in bad if b) or 'see health.json'})",
                             "cause": "the brain sentinel flagged a non-nominal check",
                             "fix": "the sentinel self-heals its lane; review remaining flags in health.json",
                             "log": None})

    # 7) tend-contract aggregation: systems that self-report (born-tendable DNA).
    #    The tender AGGREGATES; it never re-runs their work. A system's own RED /
    #    escalate is routed unchanged; its self-heals are credited; a system that
    #    stopped reporting (past its declared cadence) is surfaced.
    for r in reports:
        system = str(r.get("system") or "?")
        status = str(r.get("status", "")).upper()
        detail = str(r.get("detail", ""))
        for h in (r.get("selfHealed") or []):
            healed.append({"kind": "tend", "item": system, "action": "self-healed", "now": str(h)})
        routed = False
        for e in (r.get("escalate") or []):
            escalated.append({"kind": "tend", "item": system,
                              "why": str(e.get("why", detail)),
                              "route": str(e.get("route", "the system's own lane"))})
            routed = True
        if status == "RED" and not routed:
            escalated.append({"kind": "tend", "item": system,
                              "why": f"self-reported RED: {detail}",
                              "route": "the system's own lane (it flagged itself)"})
        elif status == "YELLOW":
            proposed.append({"kind": "tend", "item": system,
                             "why": f"self-reported YELLOW: {detail}",
                             "cause": "the system flagged a non-nominal state",
                             "fix": "review the system's log; it owns the fix", "log": None})
        cad = r.get("cadenceHours")
        if cad:
            try:
                dt = datetime.datetime.strptime(str(r.get("asOf", ""))[:19], "%Y-%m-%dT%H:%M:%S")
                if (now - dt).total_seconds() > float(cad) * 3600 * TEND_STALE_GRACE:
                    proposed.append({"kind": "tend", "item": system,
                                     "why": f"no fresh self-report (asOf {r.get('asOf', 'missing')}, cadence {cad}h)",
                                     "cause": "a tendable system stopped reporting -- it may not be running",
                                     "fix": "check the job fired on schedule", "log": None})
            except (ValueError, TypeError):
                pass

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

    # refresh the cockpit's data (deterministic, no LLM). Best-effort: a broken
    # viz refresh must never fail a tend or block a heal.
    if os.path.isfile(COCKPIT_SCAN):
        try:
            subprocess.run([sys.executable, COCKPIT_SCAN], capture_output=True, timeout=30)
        except Exception:
            pass

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
