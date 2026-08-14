# Staged todo-sensor emitters — BOTH WIRED (2026-08-13)

Datatech and D&B are now live in the master. The drafts that used to sit here were
superseded and removed; the shipped versions live in the tool fleet and run from the
8:30 `todo-master-refresh.sh`. This file is kept as the record of how each was wired
(and what would change the wiring).

See memory `project-every-job-sweeper-to-master-todo` for the common shape.

## Data-Tech — LIVE
- Emitter: `~/.hydra/tools/datatech-emit-todo-sensor.mjs` (dependency-free, raw
  `fetch` over PostgREST — no `@supabase/supabase-js`, so it lives in the fleet, not
  in the client repo, and needs no PR through datatech-site branch protection).
- Sources: 2 written human-decision gates (`~/.hydra/sensors/owes/datatech.json` —
  Nixon access/742-SKU, Marcos tie rule) + 2 derived live-catalog gates (imagery,
  seed->live swap) recomputed each run so they can never go stale.
- Creds: reads the client repo's `.env.local` via `node --env-file`. READ-ONLY; no
  schema is added to the RLS-hardened customer platform.
- Reconfirmed against the live catalog 2026-08-13: 1980/1980 no-image, 0 on
  `source=live`, so both derived gates are genuinely open.

## D&B (Rose Brill) — LIVE (board ADOPTED 8/13)
- Emitter: `~/.hydra/tools/dnb-emit-todo-sensor.py`.
- REGULATED client: NO comms sweep. Eddie's standing rule on the board (8/13): seeding
  is fine **so long as rows carry NO PII and stay to just tasks** — no person names,
  emails, ticket/matter numbers, or case details. Enforced by hand at write time.
- Source: the live `tasks` board (dnb-build, ref `yhzusrkiuqjvougthgrr`), read read-only
  over PostgREST. Seeded 8/13 with the 3 current open items (obsolete v1.3.5/hub rows
  closed as superseded); the emitter reads it live so cockpit edits flow to the master
  automatically. Publishable/anon key sourced from `~/.hydra/config/dnb-board.env`
  (gitignored; the key is already public in the cockpit bundle). The owes file
  `~/.hydra/sensors/owes/dnb.json` is now EMPTY (kept only as an offline fallback).
- Board read is only OFF if the config file is absent; then it degrades to owes and says so.
