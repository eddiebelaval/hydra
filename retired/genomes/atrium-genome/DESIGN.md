# DESIGN: Atrium

> How it looks. The gene the Build and Taste loops read so assets are on-brand by construction.

Status: ASSEMBLED from canon (live/public/index.html tokens, Shipped-skin lineage), 2026-06-10.

## Palette (exact values)

| Token | Value | Role |
|---|---|---|
| paper | #FAF8F4 | the field; warm white, never pure white |
| ink | #1A1714 | text, primary buttons |
| muted | #8A8378 | secondary text, labels, metadata |
| line | #E5E0D6 | hairline borders, dividers |
| orange | #FF6B35 | the single accent: live states, decisions, alerts |
| card | #FFFFFF | item cards on the paper field |
| alert wash | #FFF3ED | background of alert cards only |
| commitment tan | #C9BFAE | commitment card accent bar |

Discipline: one accent color. Orange means alive or load-bearing (the listening
dot, decision bars, alert flags). If everything is orange, nothing is.

## Type

- Fraunces (serif, 600): headlines, hero lines, foreground board items. The thinking voice.
- Archivo (sans, 400-600): body and UI copy.
- Archivo Narrow (sans, 600, uppercase, letterspaced 0.08-0.12em): flags, zone labels, buttons.
- JetBrains Mono (400-500): timers, identity lines, metadata, anything machine-true.

## Spacing and layout

- The board is three stacked zones with visible decay: foreground at full opacity
  and serif scale, midground at 0.85, background at 0.45 and borderless. Decay is
  the design.
- Hairline rules extend zone labels to the right edge (label, then a 1px line).
- Radii: 8px controls, 10px cards, 12-14px panels. Soft, never bubbly.
- Generous paper margin; the board breathes. Density is a failure mode.

## Motion

- Arrival: 0.5s ease, rise 6px, fade in. Items arrive like thoughts, not popups.
- Pulse: the listening dot and waiting-room dot breathe at 1.6-1.8s.
- Nothing else moves. Restraint is the motion language.

## Signature motifs

- The breathing orange dot: Atrium is present and sensing.
- Type-flag cards: a small uppercase flag above the text, left accent bar by type
  (decision and alert orange, answer ink, commitment tan).
- The tide: items rising to foreground and decaying to background. Any static
  rendering of Atrium should still imply vertical salience.

## Anti-design (never do)

- No emojis anywhere in product or documents.
- No dark dashboard skin, no data-grid density, no chart junk.
- No pure white as the page field; the paper is warm.
- No second accent color. No gradients as decoration.
- Nothing that visually competes with the board; chrome stays quiet.
