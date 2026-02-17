# Skill: CSS and Styling

You can modify styles in `src/app/globals.css` and component-level Tailwind classes.

## Where styles live

- Global tokens and animations: `src/app/globals.css`
- Component styles: Tailwind utility classes inline
- Design system tokens: CSS custom properties (`:root` and `.light` blocks)

## Rules for style changes

1. New CSS custom properties go in the `:root` block (dark mode default)
   AND the `.light` block (light mode override)
2. New animations go as `@keyframes` in globals.css
3. Component styling is Tailwind-first — only use globals.css for:
   - New CSS variables
   - New keyframe animations
   - Complex selectors that can't be expressed in Tailwind

## Common patterns

### Adding a new glow variant
```css
:root {
  --glow-new: rgba(R, G, B, 0.35);
  --glow-new-soft: rgba(R, G, B, 0.12);
  --glow-new-ambient: rgba(R, G, B, 0.06);
}
.light {
  --glow-new: rgba(R, G, B, 0.45);
  --glow-new-soft: rgba(R, G, B, 0.22);
  --glow-new-ambient: rgba(R, G, B, 0.10);
}
```

### Adding a new animation
```css
@keyframes animation-name {
  0%, 100% { /* start/end state */ }
  50% { /* peak state */ }
}
```
Use in components: `style={{ animation: 'animation-name 3s ease-in-out infinite' }}`

## What NOT to do
- Don't use `@apply` — Tailwind v4 discourages it
- Don't create new color tokens outside the warm palette
- Don't use `box-shadow` — use border + radial-gradient glow instead
