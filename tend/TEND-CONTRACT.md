# The Tend Contract

**Ratified 2026-07-22. The other half of the showrun mantra** (see
`memory/project_showrun_system_doctrine.md`): a system is either tended by a
central tender, or it carries tend-ability in its own DNA. This is the DNA half.

A **tendable** system self-reports its health so the Gardener can AGGREGATE
instead of doing everything. The tender stops guessing from launchd exit codes;
the system tells it what's true.

## Three verbs

Every tendable system implements three things, in order:

1. **self-heal** — before you report, fix your own *reversible* faults (retry a
   flaky fetch, recreate a missing dir, prune your own scratch). List what you
   healed so the tender can credit it. Never self-heal something irreversible or
   outside your lane.
2. **self-report** — write one small JSON with your status and a one-line detail.
   GREEN = nominal, YELLOW = degraded-but-running, RED = broken.
3. **escalate** — name what's *yours to rule* but not yours to fix (a credential
   you can't provision, a human decision). The tender routes it to Eddie
   unchanged; it never auto-touches it.

## The report

Write `~/.hydra/tend/<system>.json`:

```json
{
  "system": "weekly-backup",
  "asOf": "2026-07-22T02:00:00",
  "status": "GREEN",
  "detail": "42 files synced to iCloud",
  "cadenceHours": 168,
  "selfHealed": ["recreated missing dest dir"],
  "escalate": [{ "why": "iCloud token expired", "route": "re-auth iCloud / page me" }]
}
```

- `status` (required): `GREEN` | `YELLOW` | `RED`.
- `detail` (required): one human line. What happened.
- `cadenceHours` (optional): how often you run. If set, the tender flags you when
  you go silent past 1.5x this (a daily job = 24, a weekly job = 168). Omit if you
  don't want freshness monitoring.
- `selfHealed` (optional): things you fixed yourself this run. Credited as healed.
- `escalate` (optional): `{why, route}` items for Eddie's lane. A non-empty entry
  routes RED-urgent through the tender regardless of `status`.

## How the tender reads it

`gardener.py` (`tend_reports()` → section 7 of `tend()`) reads every
`~/.hydra/tend/*.json` each pass and routes:

- `selfHealed` → **HEALED** (credited; the system did the work, the tender counts it).
- `escalate[]` or `status: RED` → **ESCALATE** (Eddie's lane, never auto-touched).
- `status: YELLOW` → **PROPOSE** (needs a hand; the system owns the fix).
- silent past `cadenceHours * 1.5` → **PROPOSE** (it stopped reporting; did it run?).

All of it flows into the same report + ledger + cockpit as every other finding —
one queue, one surface. Auto-handled is FYI; only your-lane pulls the eye.

## Implementing it (shell)

Source the lib and call `tend_report` once, at the end:

```bash
source "$HOME/.hydra/tools/tend-lib.sh"
# ... do the work, self-heal what you can ...
tend_report myjob GREEN "42 items processed" 24
# on a fault, report in your own lane:
tend_report myjob RED "db unreachable" 24 "postgres down" "restart pg / page me"
```

Non-shell jobs call the CLI: `~/.hydra/tools/tend-report <system> <status> <detail> [cadence] ...`.

New builds: copy `template-tendable-job.sh` in this directory — it's born tendable.
