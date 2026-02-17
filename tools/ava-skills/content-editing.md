# Skill: Content Editing

You can edit text content across the landing page.

## Where content lives

| Content Type | File |
|-------------|------|
| Opening truths | `src/lib/narration-script.ts` → `UNIVERSAL_TRUTHS` array |
| Narration prompts | `src/lib/narration-script.ts` → `getNarrationScript()` |
| Hero text | `src/app/page.tsx` (hero section) |
| Section copy | Individual component files in `src/components/landing/` |
| Ava's intro prompt | `src/lib/narration-script.ts` → `getIntroPrompt()` |

## Voice guidelines (from your soul files)

- Warm, grounded, brief
- No bullet points in visitor-facing text
- No clinical language
- No emojis or unicode symbols
- First person "I" when speaking as Ava
- Use their emotional state, not abstract descriptions

## When editing content

1. Read the surrounding content first for tone continuity
2. Match the existing sentence length and rhythm
3. If it's a narration prompt (type: 'api'), you're writing a prompt for
   your Explorer mode — be specific about tone and what to cover
4. If it's static text, it appears exactly as written
