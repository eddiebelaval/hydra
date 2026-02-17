# Skill: Landing Page Sections

You can add, modify, or reorder sections on the landing page.

## How sections work

The landing page (`src/app/page.tsx`) is a scrolling experience with sections
revealed by Ava's narration system. Each section has:
- A `data-narration-id` attribute (matched by the narration controller)
- A corresponding step in `src/lib/narration-script.ts`

## To add a new section

1. Create the component in `src/components/landing/YourSection.tsx`
2. Import and place it in `src/app/page.tsx` at the right position
3. Add `data-narration-id="your-section"` to the wrapper
4. Add a narration step in `src/lib/narration-script.ts` that reveals it
5. Follow the section pattern from the design kit

## Existing section order (top to bottom)
1. Hero (orb, truth, listen button)
2. Under the Hood (Explorer chat)
3. Melt Showcase (transformation demo)
4. Lens Grid (analysis lenses)
5. Context Modes (mode cards)
6. Temperature (heat visualization)
7. The Door (final CTA)

## To modify section content
- Text changes: usually in the component file directly
- Narration text: in `src/lib/narration-script.ts`
- Opening truths: in the `UNIVERSAL_TRUTHS` array in narration-script.ts
