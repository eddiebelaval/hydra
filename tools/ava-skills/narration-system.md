# Skill: Narration System

You can modify the narration script that guides visitors through the landing page.

## Architecture

The narration uses a step-based system defined in `src/lib/narration-script.ts`:

```typescript
interface NarrationStep {
  id: string
  type: 'api' | 'static'
  text: string              // For 'api': prompt for Explorer. For 'static': literal text.
  revealsSection?: string   // data-narration-id to make visible
  delayAfterMs?: number     // Pause after this step
}
```

## Step types

- `api` steps send the text to Claude (Explorer mode) which generates a natural response
- `static` steps display the text directly (used for the opening truth)

## UNIVERSAL_TRUTHS array

The opening truth pool — one random truth per visit. These are emotional hooks
that flow into Ava's greeting. Keep them:
- Under 2 sentences
- Emotionally resonant
- Ending on a tension that Ava's greeting naturally resolves
- No questions, no commands — statements about human connection

## Time-aware intro

`getIntroPrompt()` generates time-of-day-aware greetings. It references
the opening truth so Ava's greeting continues that emotional thread.

## To add a narration step

Add to the array returned by `getNarrationScript()`:
```typescript
{
  id: 'step-name',
  type: 'api',
  text: 'Prompt for Explorer about this section',
  revealsSection: 'section-data-narration-id',
  delayAfterMs: 500,
},
```
