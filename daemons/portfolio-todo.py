#!/usr/bin/env python3
"""
portfolio-todo.py - HYDRA Portfolio TODO staleness + brain wiring.

Runs daily 5:35 AM via launchd (after project-staleness 5:30, before goals-updater 6:05).
Deterministic, stdlib only, $0.

Two jobs on ~/Development/id8/TODO.md (the universal portfolio list):
  1. STALENESS: any `[active]` item whose `last_touched:` is idle >14 days flips to
     `[review]` in-place (marker `auto_review: <date>` appended once). Items with no
     last_touched are reported, never auto-flipped (avoids false positives).
  2. BRAIN: renders the current portfolio state (counts + active/review titles) into a
     bounded `<!-- PORTFOLIO-TODO -->` section of ~/.hydra/GOALS.md so the brain layer
     sees it alongside the other auto-updated sections.

Flags: --dry-run (report only, write nothing).
"""
from __future__ import annotations
import re, sys, datetime, pathlib

HOME = pathlib.Path.home()
TODO = HOME / "Development/id8/TODO.md"
GOALS = HOME / ".hydra/GOALS.md"
LOG_DIR = HOME / "Library/Logs/claude-automation/portfolio-todo"
STALE_DAYS = 14
DRY = "--dry-run" in sys.argv
TODAY = datetime.date.today()

HEADER_RE = re.compile(r'^- \[(\w+)\] (.+?)\s*$')
LT_RE = re.compile(r'last_touched:\s*(\d{4}-\d{2}-\d{2})')


def log(msg: str) -> None:
    line = f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line)
    if not DRY:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with (LOG_DIR / f"portfolio-todo-{TODAY}.log").open("a") as f:
            f.write(line + "\n")


def is_block_end(line: str) -> bool:
    # A metadata block ends at the next item header, a heading, an hr, or a blank line.
    return (HEADER_RE.match(line) is not None
            or line.startswith("## ") or line.startswith("### ")
            or line.strip() == "---" or line.strip() == "")


def process():
    if not TODO.exists():
        log(f"ERROR: {TODO} not found"); return 1
    lines = TODO.read_text().splitlines()
    n = len(lines)
    counts = {}
    flips, no_date = [], []
    active_titles, review_titles = [], []

    i = 0
    while i < n:
        m = HEADER_RE.match(lines[i])
        if not m:
            i += 1; continue
        state, title = m.group(1), m.group(2)
        # gather this item's metadata block
        j = i + 1
        meta_idx = []
        while j < n and not is_block_end(lines[j]):
            meta_idx.append(j); j += 1
        # find last_touched across metadata lines
        lt, lt_line = None, None
        for k in meta_idx:
            mm = LT_RE.search(lines[k])
            if mm:
                lt = datetime.date.fromisoformat(mm.group(1)); lt_line = k; break

        if state == "active":
            if lt is None:
                no_date.append(title)
            else:
                idle = (TODAY - lt).days
                if idle > STALE_DAYS:
                    # flip header active -> review
                    lines[i] = lines[i].replace("[active]", "[review]", 1)
                    if "auto_review:" not in lines[lt_line]:
                        lines[lt_line] = lines[lt_line].rstrip() + f" | auto_review: {TODAY}"
                    flips.append((title, idle))
                    state = "review"  # reflect for counts/brain below

        counts[state] = counts.get(state, 0) + 1
        if state == "active":
            active_titles.append(title)
        elif state == "review":
            review_titles.append(title)
        i = j

    # write TODO back if changed
    if flips and not DRY:
        TODO.write_text("\n".join(lines) + "\n")
    for t, idle in flips:
        log(f"FLIP active->review ({idle}d idle): {t}")
    if no_date:
        log(f"active items with no last_touched (not flipped): {len(no_date)}")

    render_brain(counts, active_titles, review_titles, len(flips), no_date)
    log(f"done: {counts} | flipped={len(flips)} | undated_active={len(no_date)}"
        + (" | DRY-RUN (no writes)" if DRY else ""))
    return 0


def render_brain(counts, active_titles, review_titles, flipped, no_date):
    if not GOALS.exists():
        log(f"WARN: {GOALS} not found - skipping brain render"); return
    summary = " | ".join(f"{k}: {v}" for k, v in sorted(counts.items())) or "empty"
    body = [
        f"**Universal list:** `~/Development/id8/TODO.md` — {summary}"
        f"{f' | {flipped} flipped to review today' if flipped else ''}.",
        "",
        "**Active:**",
    ]
    body += [f"- {t}" for t in active_titles] or ["- *(none)*"]
    if review_titles:
        body += ["", "**Needs review (idle / flagged):**"]
        body += [f"- {t}" for t in review_titles]
    if no_date:
        body += ["", f"*{len(no_date)} active item(s) missing `last_touched` — not tracked for staleness.*"]
    body += ["", f"*Auto-updated {TODAY} at {datetime.datetime.now():%H:%M}*"]
    block = "\n".join(body)

    start, end = "<!-- PORTFOLIO-TODO:START -->", "<!-- PORTFOLIO-TODO:END -->"
    text = GOALS.read_text()
    section = f"{start}\n{block}\n{end}"
    if start in text and end in text:
        text = re.sub(re.escape(start) + r".*?" + re.escape(end), section, text, flags=re.DOTALL)
    else:
        # insert a new section before "## Monthly Focus" (stable anchor), else append
        header = "## Portfolio TODO (auto-updated)\n\n" + section + "\n\n---\n\n"
        anchor = "## Monthly Focus (auto-updated)"
        if anchor in text:
            text = text.replace(anchor, header + anchor, 1)
        else:
            text = text.rstrip() + "\n\n---\n\n" + header
    if not DRY:
        GOALS.write_text(text)
    log(f"brain section rendered into {GOALS.name}"
        + (" (DRY-RUN)" if DRY else ""))


if __name__ == "__main__":
    sys.exit(process())
