# HYDRA — Pre-Open-Source Redaction Gate

**HARD GATE.** This repo does NOT flip public until every box below is checked and the
final grep sweep passes. Owner: Eddie. Created 2026-07-20.

This repo is Eddie's live private brain. The *code* (daemons, tools, lib, migrations) is
the open-source artifact — the *content* (goals, journey, financials, life signals) is not.

## Good news — secrets already protected (verified 2026-07-20)

These are gitignored and NOT in history, so no credential leak risk:
- `config/*.env` (plaid, telegram, resend, cloudflare, ava, milo) — API keys
- `hydra.db` + `-wal/-shm/-journal` — the SQLite brain (revenue, subscriptions, life signals, telegram_context)
- `logs/`

Do NOT untrack or rewrite these — they were never committed. The problem is content, not secrets.

## The exposure — tracked personal-narrative files (must be handled before public)

| File | What leaks |
|---|---|
| `GOALS.md` | revenue targets, personal + LLC burn ($/mo), portfolio TODO |
| `TECHNICAL_BRAIN.md` | 35 sensitive lines — financials, client/project internals |
| `JOURNEY.md` | personal narrative / decisions |
| `VISION.md`, `BUILDING.md` | strategy, money, roadmap |
| `ava-mind/goals/eddie.md`, `ava-mind/goals/ava.md` | personal goals |
| `milo-brain/*.md`, `mind/drives/goals.md` | drives, north star, execution notes |

## Mechanism — RECOMMENDED: fresh public repo, do NOT scrub-and-publish this one

History-scrubbing a private brain repo with months of personal commits is one-miss-from-leak.
Instead:

1. [ ] Create a NEW public repo `hydra` (no history from this private one).
2. [ ] Copy CODE ONLY: `daemons/ tools/ lib/ scripts/ migrations/ init-db.sql`, `config/*.example`,
       `launchd/`, and the `.example` template versions of the brain files (see `GOALS.md.example`).
3. [ ] Write a public README (setup, architecture, the daemon schedule) — no real data.
4. [ ] Ship sanitized `.example` templates for each brain file; the live files stay private here.
5. [ ] Confirm the public repo's `.gitignore` carries the same secret/db/log rules as this one.

**Fallback (only if history must be preserved):** `git filter-repo --path` to delete every file
in the exposure table above (and any `*.env`, `hydra.db*`), then force-push a scrubbed mirror.
Higher risk; requires the grep sweep to pass on the scrubbed clone, not the original.

## Final gate — must pass before public

- [ ] `git grep -iE '\$[0-9]|/mo|burn|SSN|routing|account|plaid|telegram.*token'` returns nothing sensitive
- [ ] No `.env`, no `hydra.db`, no `logs/` in `git ls-files`
- [ ] A cold clone reviewed by fresh eyes (or the security-review skill) before flipping visibility
