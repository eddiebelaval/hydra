#!/usr/bin/env python3
"""Stale sweep: find rot across the machine's config, agents, and brain.

READ-ONLY. Changes nothing, ever. Emits a ranked markdown report.

Every check here exists because the failure it detects actually happened, not
because it seemed plausible:

  - a stale April MEMORY.md snapshot sitting in Codex's skills dir (2026-08-06)
  - 87 SKILL.md files with broken frontmatter, silently unloadable (2026-08-06)
  - ~/.claude/docs/daily-e2e.md advertised in CLAUDE.md, missing from disk
  - enforce-feature-branch.sh on disk but wired to nothing
  - 7 preflight gates written 2026-07-01, never once run, then firing false REDs
    against a live client DB 11 days before a deadline (2026-08-03)

The theme: things that LOOK authoritative and are not. A gate that never ran, a
snapshot that reads as current, a pointer to a file that no longer exists.

Usage: stale-sweep.py [--out PATH]
"""

import os, re, sys, glob, json, subprocess, plistlib
from datetime import datetime, timedelta

H = os.path.expanduser
NOW = datetime.now()
findings = []   # (severity, category, item, detail, fix)

def add(sev, cat, item, detail, fix=""):
    findings.append((sev, cat, item, detail, fix))

def run(cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              timeout=25).stdout.strip()
    except Exception:
        return ""

def tilde(p):
    return p.replace(H("~"), "~")

# Trees that are deliberately-dead, vendored, or someone else's cache. Flagging
# them is noise, and a sweep that cries wolf is worse than no sweep -- the same
# failure as a gate that reports RED on a healthy system.
SKIP = ("/quarantine/", "/marketplaces/", "/.tmp/", "/tmp/", "/plugins/",
        "/node_modules/", "/archive/", "/_archive/", "/archived_sessions/",
        "/cache/", "/.git/", "/backup", "/retired/", "/sessions/", "/projects/",
        "/logs/", "/jobs/", "/worktrees/", "/vendor_imports/", "/.venv/")

def skip(p):
    return any(s in p for s in SKIP)

# --- 1. broken symlinks ------------------------------------------------------
def check_symlinks():
    roots = [H("~/.claude"), H("~/.hydra"), H("~/.codex"), H("~/.agents")]
    for r in roots:
        if not os.path.isdir(r): continue
        for dp, dns, fns in os.walk(r):
            # skip heavy/irrelevant trees
            if any(s in dp for s in ("/node_modules", "/.git/", "/projects/",
                                     "/archived_sessions", "/cache", "/sessions")):
                dns[:] = []
                continue
            for n in dns + fns:
                p = os.path.join(dp, n)
                if skip(p): continue
                if os.path.islink(p) and not os.path.exists(p):
                    add("HIGH", "broken-symlink", tilde(p),
                        f"points at {os.readlink(p)} which does not exist",
                        "repoint or remove")

# --- 2. paths advertised in config that do not exist -------------------------
def check_dead_refs():
    docs = [H("~/.claude/CLAUDE.md"), H("~/.codex/AGENTS.md")]
    pat = re.compile(r'`(~[/\w.\-]+\.(?:md|sh|py|json|toml))`')
    for d in docs:
        if not os.path.isfile(d): continue
        txt = open(d, encoding="utf-8", errors="replace").read()
        for m in set(pat.findall(txt)):
            if not os.path.exists(H(m)):
                add("HIGH", "dead-reference", tilde(d),
                    f"advertises {m} which does not exist",
                    "fix the path or drop the line")

# --- 3. launchd: agents whose program is missing -----------------------------
def check_launchd():
    loaded = run(["launchctl", "list"])
    loaded_labels = {l.split("\t")[-1] for l in loaded.splitlines()[1:] if l.strip()}
    for p in glob.glob(H("~/Library/LaunchAgents/*.plist")):
        try:
            with open(p, "rb") as fh: d = plistlib.load(fh)
        except Exception as e:
            add("MED", "launchd-unparseable", tilde(p), str(e)[:60], "fix the plist")
            continue
        label = d.get("Label", os.path.basename(p))
        if not any(k in label for k in ("id8labs", "hydra", "eddieb", "deepstack")):
            continue
        args = d.get("ProgramArguments") or []
        target = None
        for a in args:
            # A shell -c payload is a command, not a path. Only treat a bare,
            # space-free filesystem path as a program to existence-check.
            if not isinstance(a, str) or "/" not in a: continue
            if a in ("/bin/bash", "/bin/sh", "/usr/bin/env", "-c"): continue
            if " " in a or "&&" in a or ";" in a or a.startswith("export "): continue
            target = a; break
        if target and not os.path.exists(target):
            add("HIGH", "launchd-missing-program", label,
                f"ProgramArguments points at {tilde(target)} which does not exist",
                "fix the path or unload the agent")
        if label not in loaded_labels:
            add("LOW", "launchd-not-loaded", label,
                "plist on disk but not registered with launchctl",
                "launchctl load it, or archive the plist")
        # scheduled but never produced output
        out = d.get("StandardOutPath")
        if out and target and os.path.exists(target):
            if not os.path.exists(out):
                add("MED", "launchd-never-ran", label,
                    "loaded and program exists, but its log has never been written",
                    "run it by hand once and confirm it works")
            else:
                age = NOW - datetime.fromtimestamp(os.path.getmtime(out))
                iv = d.get("StartInterval")
                # only flag if it should have run recently
                if iv and age > timedelta(seconds=int(iv) * 8):
                    add("MED", "launchd-stale-log", label,
                        f"interval {iv}s but log last written {age.days}d ago",
                        "check whether it is silently failing")

# --- 4. hooks: wired-but-missing, and on-disk-but-orphaned -------------------
def check_hooks():
    st = H("~/.claude/settings.json")
    if not os.path.isfile(st): return
    try: d = json.load(open(st))
    except Exception as e:
        add("HIGH", "settings-unparseable", "settings.json", str(e)[:60], "fix the JSON"); return
    wired = set()
    for evt, arr in (d.get("hooks") or {}).items():
        for grp in (arr if isinstance(arr, list) else []):
            for hk in grp.get("hooks", []):
                cmd = hk.get("command", "")
                cmd = cmd.replace("${HOME}", H("~")).replace("$HOME", H("~"))
                m = re.search(r'((?:~|/)[\w/.\-]*\.(?:sh|py))', cmd)
                if not m: continue
                p = H(m.group(1).strip('"'))
                wired.add(os.path.basename(p))
                if not os.path.exists(p):
                    add("HIGH", "hook-missing", f"{evt}:{os.path.basename(p)}",
                        f"settings.json wires {tilde(p)} but it does not exist",
                        "restore the script or remove the hook")
    for p in glob.glob(H("~/.claude/hooks/*.sh")) + glob.glob(H("~/.claude/hooks/*.py")):
        if os.path.basename(p) not in wired:
            add("LOW", "hook-orphan", os.path.basename(p),
                "hook script on disk, not referenced by settings.json",
                "wire it or archive it")

# --- 5. stale brain copies ---------------------------------------------------
def check_brain_copies():
    live = H("~/.claude/projects/-Users-eddiebelaval-Development-id8/memory/MEMORY.md")
    roots = [H("~/.claude"), H("~/.codex"), H("~/.agents"), H("~/.hydra")]
    for r in roots:
        if not os.path.isdir(r): continue
        for dp, dns, fns in os.walk(r):
            if any(s in dp for s in ("/.git/", "/node_modules", "/archived_sessions", "/cache")):
                dns[:] = []; continue
            for n in fns:
                if n != "MEMORY.md": continue
                p = os.path.join(dp, n)
                if os.path.realpath(p) == os.path.realpath(live): continue
                age = (NOW - datetime.fromtimestamp(os.path.getmtime(p))).days
                head = open(p, encoding="utf-8", errors="replace").read(400).lower()
                marked = "stale" in head or "do not treat" in head or "archive" in head
                add("HIGH" if not marked else "LOW", "brain-copy", tilde(p),
                    f"a second MEMORY.md, {age}d old" + ("" if marked else
                    " and NOT marked stale -- an agent could read it as current"),
                    "mark it stale in its first lines, or delete it")

# --- 6. skill frontmatter (keep the 2026-08-06 fix from regressing) ----------
def check_skills():
    try: import yaml
    except ImportError:
        add("LOW", "sweep-gap", "skills", "pyyaml unavailable; frontmatter not validated", "")
        return
    seen = set(); bad = 0; total = 0
    for r in ("~/.agents/skills", "~/.claude/skills", "~/.codex/skills"):
        for f in glob.glob(H(os.path.join(r, "*", "SKILL.md"))):
            rp = os.path.realpath(f)
            if rp in seen: continue
            seen.add(rp); total += 1
            s = open(f, encoding="utf-8", errors="replace").read()
            m = re.match(r'^---\n(.*?)\n---\s*\n', s, re.S) if s.startswith("---\n") else None
            if not m:
                bad += 1
                add("HIGH", "skill-frontmatter", tilde(f), "missing or unterminated frontmatter",
                    "add/repair the --- block"); continue
            try: yaml.safe_load(m.group(1))
            except Exception as e:
                bad += 1
                add("HIGH", "skill-frontmatter", tilde(f), "invalid YAML: " + str(e).split("\n")[0][:50],
                    "quote the offending value")
    add("INFO", "skills-scanned", f"{total} unique", f"{bad} broken", "")

# --- 7. git repos: drift and unpushed work ----------------------------------
def check_repos():
    for r in ("~/.claude", "~/.hydra", "~/Development/id8", "~/Development/id8-halos"):
        p = H(r)
        if not os.path.isdir(os.path.join(p, ".git")): continue
        dirty = len([l for l in run(["git", "status", "--porcelain"], cwd=p).splitlines() if l.strip()])
        ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"], cwd=p) or "0"
        last = run(["git", "log", "-1", "--format=%ct"], cwd=p)
        if last:
            days = (NOW - datetime.fromtimestamp(int(last))).days
            if days > 14:
                add("MED", "repo-stale", tilde(p), f"no commit in {days} days", "commit or confirm dormant")
        if ahead.isdigit() and int(ahead) > 0:
            add("MED", "repo-unpushed", tilde(p), f"{ahead} commit(s) not on the remote",
                "push, or confirm deliberately local")
        if dirty > 200:
            add("MED", "repo-dirty", tilde(p), f"{dirty} uncommitted paths",
                "triage; large dirty trees hide real changes")

# --- 8. memory hygiene: unsigned lessons, and old files claiming live state ---
def check_memory():
    mem = H("~/.claude/projects/-Users-eddiebelaval-Development-id8/memory")
    if not os.path.isdir(mem): return
    unsigned = []
    for f in glob.glob(os.path.join(mem, "feedback_*.md")):
        s = open(f, encoding="utf-8", errors="replace").read(1800)
        if "signatures:" not in s:
            unsigned.append(os.path.basename(f)[:-3])
    if unsigned:
        add("MED", "memory-unsigned", f"{len(unsigned)} feedback memories",
            "no metadata.signatures, so the outer loop cannot detect recurrence: "
            + ", ".join(sorted(unsigned)[:6]) + ("..." if len(unsigned) > 6 else ""),
            "add 2-4 greppable failure-symptom phrases to each")
    idx = os.path.join(mem, "MEMORY.md")
    if os.path.isfile(idx):
        size = os.path.getsize(idx)
        if size > 17100:
            add("HIGH", "memory-index-oversize", "MEMORY.md",
                f"{size}B exceeds the ~17.1KB read limit; the tail is silently dropped on load",
                "move detail into _dispatch_*.md sub-indexes")

# --- 9. UNKNOWN-UNKNOWNS: things failing where nobody is looking -------------
# The checks above encode failures we already met. These look for ANOMALY instead:
# noise nobody reads, and copies that quietly diverged. This is where the things
# you did not know to look for actually live.

def check_error_logs():
    """Non-empty .err files. A scheduled job failing every night for a month
    looks exactly like a scheduled job succeeding, unless someone reads this."""
    for pat in ("~/.hydra/logs/*.err", "~/.claude/logs/*.err", "~/Library/Logs/*.err"):
        for f in glob.glob(H(pat)):
            try: sz = os.path.getsize(f)
            except OSError: continue
            if sz == 0: continue
            age = (NOW - datetime.fromtimestamp(os.path.getmtime(f))).days
            tail = ""
            try:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    lines = [l.strip() for l in fh.readlines() if l.strip()]
                    tail = lines[-1][:120] if lines else ""
            except OSError: pass
            sev = "HIGH" if age <= 7 else "MED"
            add(sev, "silent-failure", tilde(f),
                f"{sz}B of stderr, last written {age}d ago. Last line: {tail!r}",
                "read it; a job has been failing where nothing surfaces it")

def check_divergent_copies():
    """Same filename in multiple roots with DIFFERENT content. One of them is
    stale and something is reading it. This is how the April MEMORY.md survived."""
    import hashlib
    names = {}
    watch = ("AGENTS.md", "CLAUDE.md", "SKILL.md", "settings.json", "config.toml")
    for r in ("~/.claude", "~/.codex", "~/.agents", "~/.hydra"):
        root = H(r)
        if not os.path.isdir(root): continue
        for dp, dns, fns in os.walk(root):
            if any(s in dp for s in ("/.git/", "/node_modules", "/projects/",
                                     "/archived_sessions", "/cache", "/sessions")):
                dns[:] = []; continue
            if skip(dp): continue
            for n in fns:
                if n not in watch: continue
                p = os.path.join(dp, n)
                if os.path.islink(p) or skip(p): continue
                key = (n, os.path.basename(dp))
                try:
                    h = hashlib.md5(open(p, "rb").read()).hexdigest()
                except OSError: continue
                names.setdefault(key, []).append((p, h))
    for (n, parent), lst in names.items():
        if len(lst) < 2: continue
        if len({h for _, h in lst}) == 1: continue     # identical copies are fine
        newest = max(lst, key=lambda x: os.path.getmtime(x[0]))
        for p, h in lst:
            if p == newest[0]: continue
            gap = (datetime.fromtimestamp(os.path.getmtime(newest[0]))
                   - datetime.fromtimestamp(os.path.getmtime(p))).days
            add("MED" if gap < 30 else "HIGH", "divergent-copy", tilde(p),
                f"differs from {tilde(newest[0])}, which is {gap}d newer. "
                "Something may be reading the older one.",
                "reconcile, symlink to one source, or mark the stale one")

def check_orphan_scripts():
    """Scripts in tools/ that nothing references: no launchd agent, no hook, no
    other script. Either dead weight or a job someone forgot to schedule."""
    refs = ""
    for pat in ("~/Library/LaunchAgents/*.plist", "~/.claude/settings.json",
                "~/.hydra/tools/*.sh", "~/.hydra/tools/*.py", "~/.claude/hooks/*"):
        for f in glob.glob(H(pat)):
            try: refs += open(f, encoding="utf-8", errors="replace").read()
            except OSError: pass
    crontab = run(["crontab", "-l"]) or ""
    refs += crontab
    for f in glob.glob(H("~/.hydra/tools/*.sh")) + glob.glob(H("~/.hydra/tools/*.py")):
        base = os.path.basename(f)
        # a script referencing only itself is unreferenced
        if refs.count(base) <= 1:
            age = (NOW - datetime.fromtimestamp(os.path.getmtime(f))).days
            add("LOW", "orphan-script", base,
                f"nothing schedules or calls it; last touched {age}d ago",
                "schedule it, call it, or archive it")

def main():
    out = H("~/.claude/STALE-SWEEP.md")
    if "--out" in sys.argv: out = H(sys.argv[sys.argv.index("--out") + 1])
    for fn in (check_symlinks, check_dead_refs, check_launchd, check_hooks,
               check_brain_copies, check_skills, check_repos, check_memory,
               check_error_logs, check_divergent_copies, check_orphan_scripts):
        try: fn()
        except Exception as e:
            add("LOW", "sweep-error", fn.__name__, str(e)[:80], "check the sweep itself")

    order = {"HIGH": 0, "MED": 1, "LOW": 2, "INFO": 3}
    findings.sort(key=lambda x: (order.get(x[0], 9), x[1]))
    counts = {}
    for sev, *_ in findings: counts[sev] = counts.get(sev, 0) + 1

    with open(out, "w", encoding="utf-8") as fh:
        fh.write(f"# Stale sweep — {NOW.strftime('%Y-%m-%d %H:%M')}\n\n")
        fh.write("Read-only. Nothing was changed.\n\n")
        fh.write("**" + "  ".join(f"{k}: {counts.get(k,0)}" for k in ("HIGH","MED","LOW","INFO")) + "**\n\n")
        cur = None
        for sev, cat, item, detail, fix in findings:
            if sev != cur:
                fh.write(f"\n## {sev}\n\n"); cur = sev
            fh.write(f"- **{cat}** `{item}`\n  - {detail}\n")
            if fix: fh.write(f"  - _fix:_ {fix}\n")
        fh.write("\n---\n_Generated by stale-sweep.py. Re-run any time; it changes nothing._\n")

    print(f"{NOW.strftime('%Y-%m-%d %H:%M')}  {len(findings)} finding(s) -> {tilde(out)}")
    for k in ("HIGH", "MED", "LOW"):
        if counts.get(k): print(f"  {k}: {counts[k]}")

if __name__ == "__main__":
    main()
