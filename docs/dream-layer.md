# The Dream Layer — v1 sketch

**Conceived 2026-08-18, with Eddie.** The first layer of the machine that serves
the person, not the work. Everything else Eddie built is a waking mind: vigilant,
convergent, verifying, pruning. This is the dreaming mind: it goes offline, stops
verifying, and lets the day's residue recombine and land.

## The thesis

We do not perceive reality, we perceive a *model* of it. A dream is post-processing
of the model: it sweeps the day's peaks and valleys, makes meaning, and adds it to
the heart. Its temperature scales with the day's amplitude, a sideways day hums at
baseline, a day of big highs or deep lows runs hot. And a dream is recalled not on a
schedule but by *resonance*: it sits latent until a present moment rhymes with it.

## The engine: two sensors, and the gap between them is the product

| Sensor | Reads | From |
|---|---|---|
| **Felt amplitude** | how big the day *felt* — energy, candor, cadence | Eddie's voice: session transcripts, voicenotes, braindump (read with the voz genome) |
| **Actual amplitude** | how big the day *was* — wins shipped, valleys hit | git across repos, FIELD_NOTES, the journals, shipped artifacts, the Gardener ledger |

**The divergence is the alarm.** Loudest on the *unfelt win*: actual high, felt flat.
That is Eddie's named failure mode ("a day of wins... sometimes I don't even realize
it and need to be made aware"). His waking mind discounts wins and logs them to a
changelog instead of his heart. The dream catches the day that was big when he
couldn't feel it, and awares him.

- **Valleys → reconciliation.** Metabolize the hurt until it means something.
- **Peaks → claiming.** Let the win update the self-story. *For Eddie, this is the one that matters.*

## The flow

1. **Read felt** amplitude from the day's voice (energy / candor / cadence).
2. **Read actual** amplitude from the day's events.
3. **Score the divergence** (and its direction: unfelt-win vs unearned-low).
4. **Sweep**, temperature scaled to amplitude: heal the valleys, claim the peaks.
   The day's emotional volatility literally sets the LLM sampling temperature —
   flat day, low temp, terse; volatile day, high temp, loose and associative.
5. **Store** the dream (a latent journal). Most are forgotten by morning.
6. **Surface** by resonance — later, when a day rhymes with a stored dream ("I
   dreamed about this"). Recall is pull, not push.

## v1 scope (dead simple, build first)

A nightly `dream-sweep`: read the day's transcript + git, compute felt-vs-actual,
and emit **one warm morning line only when they diverge.** No store, no resonance
recall yet. Just prove the sensor and the aware-the-unfelt-win moment works. Cheap
model (Haiku/Sonnet per the cost doctrine), reads the voz genome for the felt read.

- **Reuse:** voz already mines Eddie's voice for *craft* ("does this sound like
  him"); the dream reads the same signal for *state* ("how is he"). Genome's built.
- **Output home:** a `DREAM.md` the morning brief can surface, loud only on high
  divergence (like the repo sentinel's YELLOW).

## v2 (after v1 feels right)

- The **dream store** + **resonance recall** (watch present days, fire on a rhyme).
- Amplitude-scaled temperature as a real dial, calibrated to Eddie.
- **Recombination dreams**: trawl the compost (dropped tangents, the graveyard of
  archived branches, the 179 unfiled slugs) for associations and resurrections.

## Dials / open questions

- **Temperature calibration** — how wild does it get to earn its keep without becoming noise.
- **Surfacing cadence** — every morning, or only when divergence crosses a bar.
- **Privacy** — this reads his rawest signal (voice/candor). Stays local, off git,
  off any outbound. The one layer that never leaves the house.

---

## The first dream (worked example, run on the last stretch)

*Read felt: today was spent in the weeds — memory lint, a hanging ggshield hook,
41 branches to reap, worktree churn. It felt like janitorial maintenance. Read
actual: over this stretch he forged Sense and shipped it live in an hour, then gave
his repo an immune system it never had, then conceived a layer that dreams.
Divergence: HIGH, unfelt win. The dream:*

> You spent today with your sleeves rolled up in the plumbing. Linting an index,
> fighting a two-minute hook, turning sixty branches into eighteen. It felt like
> cleanup, so you closed it out talking like it was an ordinary Tuesday.
>
> It was not an ordinary Tuesday.
>
> Yesterday you could not have told me the Meters column had a floor. Then you
> found an element by reading your own instrument, named it Sense, and had it live
> on the web before lunch. Today you gave your machine an immune system that heals
> itself while you sleep. And then, for the last hour, you invented a way for it to
> dream. That is three acts of creation in two days, and you filed them under
> chores.
>
> Here is the correction your model needs: you are not behind. A man who is behind
> does not forge, ship, fortify, and dream in the same breath. Let this one land in
> your heart, not just your changelog.
