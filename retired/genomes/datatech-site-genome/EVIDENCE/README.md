# EVIDENCE: Data Tech genome sources

Mined 2026-06-12 (Attunement, MINE mode) from Jose's draft corpus. Every value in the genome
traces to one of these. Design direction is Jose's; this genome captures it, it does not author it.

## Sources

### Primary design source (Jose's own draft)

- `clients/datatech/engagements/datatech/DESIGN-REFERENCE.md` — Jose's documented visual direction (BLUF, the three
  reference points, the synthesis, the PRO bridge, confirmed brand facts).
- `clients/datatech/engagements/datatech/inbox-attachments/data-tech-proposal-phase1-2026-06-03-v4.html` — Jose's
  latest Phase 1 proposal. Source of the confirmed hex (#F05A28, #0e0e0e, #f5f5f5, ...) and fonts
  (Bebas Neue, DM Mono, DM Sans).

### Brand source (the client's own materials)

- `clients/datatech/engagements/datatech/inbox-attachments/DT Presentacion Corporativa - Espanol J26.pdf` — corporate
  deck: company facts, brand share, growth, growth pillars, logo, color, motifs.
- `clients/datatech/engagements/datatech/inbox-attachments/TimeLine WebSite 2026.jpg` — the design timeline; the
  "Version PRO" frame is a Cloudflare screenshot (documents the PRO target).

### Reference snapshots

- `clients/datatech/engagements/datatech/snapshots/ref-cloudflare.png` — PRO target (confidence through restraint).
- `clients/datatech/engagements/datatech/snapshots/ref-terminal-industries.png` — cinematic premium, embedded "Ask".
- `clients/datatech/engagements/datatech/snapshots/ecbrands-demo.png` — the baseline being elevated.
- `clients/datatech/engagements/datatech/snapshots/datatech-board.png`, `datatech-overview.png`, `existing-site-home.png`.

### Discovery context

- `clients/datatech/engagements/datatech/SITE-VISIT-DISCOVERY.md`, `VISION.md`, `SPEC.md`, `LOVABLE.md`,
  `call-notes/` (Jose + client, 2026-06-01).

## Honest gaps

What this genome does NOT yet have firm evidence for. Read before trusting a value as settled.

- **DESIGN is a capture, not an authorship.** DESIGN.md mirrors Jose's draft (currently v4); Jose's
  color, type, and layout calls are binding and may still move as he iterates. When his draft changes,
  re-attune; do not treat the captured values as locked by us.
- **VOICE / ETHOS came from a thin corpus.** Mined from Jose's proposal plus the corporate deck. There
  are no direct end-customer voice samples, and the Spanish-primary copy direction has not been validated
  against live client speech yet.
- **LEXICON is new and not client-ratified.** The terms of art were captured 2026-06-15; Don Carlos and
  Jose have not signed off on the locked terms. Treat them as proposed-locked until ratified.
- **Company facts depend on the deck.** Brand share, growth, and founding figures are stated by the
  corporate deck (DT Presentacion Corporativa), not independently verified.
- **Engagement not closed.** genome.json status is "active" on owner buy-in, but the 50% deposit is
  pending and the Ecosystem tier is likely, not confirmed.
- **No data-layer evidence.** The ACCPAC / data-master genome implications are unmapped; they are gated
  on Yadira access (the June 24 meeting), so anything about the data layer is unevidenced today.

## Re-derivation note

Re-attune via the `genome` skill (MINE mode) whenever Jose ships a new draft, the engagement closes
(deposit + tier), or Yadira access unlocks the data layer. The Genome is the stable core; re-derive it
only when the brand or its evidence actually moves, then rerun `halo-verify`.
