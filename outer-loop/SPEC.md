# The Outer Loop — spec

The cross-session learning loop. The inner loop verifies a single task before it
answers; the outer loop verifies that **the portfolio does not repeat last
week's mistake.** Built on purpose 2026-06-16 after the McDonnell loop-engineering
read named it as the half-built frontier ("persisting the right lesson, in the
right place, at the right grain, is hard, and is where a lot of value sits").

Doctrine: [[feedback_verifier_is_the_product]]. A loop you do not measure only
generates wrong answers faster.

## The cycle (7 stages, closed)

| # | Stage | Mechanism | State |
|---|-------|-----------|-------|
| S1 | **Capture** | Stop hook → tiered `pending.jsonl` (`~/.claude/hooks/auto-journal-capture.sh`) | live |
| S2 | **Distill + route** | 9am reconciler → FIELD_NOTES / JOURNEY / memory (`~/.hydra/tools/auto-journal-reconcile.sh`) | live |
| S3 | **Persist @ grain** | grain ladder + a `signature` on every lesson (this spec) | built |
| S4 | **Recall** | `MEMORY.md` dispatcher auto-injected each session | live |
| S5 | **Verify-applied** | recurrence detector — did a filed lesson actually prevent the repeat? (`outer-loop-recurrence.py`) | built |
| S6 | **Promote** | escalate grain when a lesson recurs; **human-gated at G3** | built |
| S5b | **Correct from transcripts** | nightly correcting dream reads the day's transcripts (Eddie + side-agent notes), judges each miss against existing lessons, logs recurrences + new signatures on the lesson, drafts new lessons, holds MEMORY.md under the load limit, files repeat findings once (`dream_correct.py`, run by dream-sweep 03:30) | built 2026-11-07 |
| S7 | **Observe** | `outer-loop-health.sh` — liveness + recurrence + grain census | built |

S1/S2/S4 already ran (S2 was dead 6 weeks until 2026-06-16). S3/S5/S6/S7 are the
build that closes the loop.

## The grain ladder (S3)

A lesson lives at the **lowest grain that reliably prevents recurrence.** Higher =
more durable + more enforced + more expensive. Do not over-promote (an executable
guard for a one-off is waste); do not under-persist (a hard rule left as a journal
line will recur).

| Grain | Form | Enforcement | Example |
|-------|------|-------------|---------|
| **G0 ephemeral** | in-session context | none (dies on reset) | a correction you make mid-task |
| **G1 narrative** | FIELD_NOTES / JOURNEY line | searchable, not enforced | "shipped X; learned Y" |
| **G2 semantic** | `memory/feedback_*.md`, auto-loaded | model reads + should heed | never-fabricate-last-names |
| **G3 executable** | hook / guard / lint / gate | machine-enforced, cannot be ignored | pre-commit name guard; branch-hygiene hook; liveness gate |

Default new lessons to **G1** (journal) or **G2** (a real behavioral rule). G3 is
earned by recurrence, never the first move.

## The signature (S3, makes S5 possible)

Every G2 lesson carries one or more **symptom signatures**: short, greppable
phrases describing the *failure*, in `metadata.signatures`:

```yaml
metadata:
  type: feedback
  signatures:
    - "fabricated last name"
    - "guessed a collaborator surname"
```

A signature is the failure as it would appear in the journal if it recurred — not
the rule, the *symptom*. No signature = invisible to the verifier = write-only.

## Verify-applied (S5) — the verifier OF the outer loop

`outer-loop-recurrence.py` reads every lesson's signatures + filed date, then
scans the distilled journal (auto-journal `processed/*.jsonl` + `pending.jsonl`)
for each signature **occurring after the lesson was filed.** That count is
**recurrence-after-lesson** — the only honest measure of whether the loop works:

- **0** → the lesson held. The loop works.
- **≥1** → the lesson was filed but NOT applied. Wrong grain or wrong place.
  This is RED, and it is a **promotion candidate** (S6).

The detector is a fallible grep, not an oracle (a signature match is a heuristic).
So it surfaces **candidates for human review**, never auto-acts. This is the
refuter's lesson taken seriously: the verifier is itself a fallible spec.

## Promote (S6) — escalate grain on recurrence

When S5 flags a recurrence-after-lesson:

1. **G1 → G2:** if the lesson was only a journal line, write it as a real
   `feedback_*` memory with Why / How-to-apply + signatures. (Claude's lane.)
2. **G2 → G3:** if it was already a memory and STILL recurred, the semantic grain
   is insufficient — it needs machine enforcement (a hook/guard/lint).
   **This step is HUMAN-GATED.** Auto-writing executable guards from an automated
   loop is the irreversible-action trap. The detector writes a *promotion
   candidate* with the exact proposed guard; Eddie rules. (Cf. the name-guard and
   branch-hygiene hook — both should have been G3 sooner, both were escalated by
   hand after recurrence. This systematizes that escalation; it does not automate
   the write.)

## Observe (S7)

`outer-loop-health.sh` composes the loop's own observability into one STATUS line
(see `/fleet-health` contract):
- **liveness** of S2 (`auto-journal-liveness.sh` — RED if the reconciler stalled),
- **recurrence-after-lesson** count (S5 — RED if any lesson recurred),
- **grain census** (how many lessons at G1/G2/G3; how many G2 lessons lack a
  signature and are therefore invisible to S5).

The loop's health is GREEN only when it is alive, nothing recurred, and every
behavioral lesson is signed (measurable).

## Scheduling

- S1 every Stop (hook). S2 daily 9am (launchd). S5/S7 weekly is enough (recurrence
  is a slow signal) — run from `/fleet-health` or a weekly launchd. Offered, not
  auto-installed (touching launchd is guarded).
