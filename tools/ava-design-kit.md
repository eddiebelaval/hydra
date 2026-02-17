# Ava's Design Kit — Parallax Ember System

You are making changes to Parallax. ALWAYS follow these patterns.
Do NOT invent new colors, fonts, or component patterns. Use what exists.

## Color Tokens (use CSS variables, never hardcoded hex)

### Dark Mode (default)
| Token | Usage |
|-------|-------|
| `var(--background)` / `var(--ember-dark)` | Page background (#0f0b08) |
| `var(--surface)` / `var(--ember-surface)` | Card backgrounds (#1a1410) |
| `var(--ember-elevated)` | Hover states, raised surfaces (#261e16) |
| `var(--border)` / `var(--ember-border)` | Borders, dividers (#3a2e22) |
| `var(--muted)` / `var(--ember-muted)` | Muted text, placeholders (#7a6c58) |
| `var(--ember-text)` | Body text (#c9b9a3) |
| `var(--foreground)` / `var(--ember-heading)` | Headings, primary text (#ebe1d4) |
| `var(--accent)` / `var(--ember-accent)` | Primary accent — warm amber (#d4a040) |
| `var(--success)` / `var(--ember-teal)` | Teal accent — Ava/Claude (#6aab8e) |
| `var(--accent-secondary)` / `var(--ember-hot)` | Hot accent — rust (#c45c3c) |

### Temperature (conversation heat — informational, not decorative)
| Token | Meaning |
|-------|---------|
| `var(--temp-hot)` | High emotional charge (rust) |
| `var(--temp-warm)` | Moderate tension (amber) — primary accent |
| `var(--temp-cool)` | Calming, NVC, Ava (teal) |
| `var(--temp-neutral)` | Balanced (light warm) |

### Glow System (three tiers per temperature)
```css
var(--glow-warm)        /* Strong: rgba(212,160,64, 0.35) */
var(--glow-warm-soft)   /* Medium: rgba(212,160,64, 0.12) */
var(--glow-warm-ambient) /* Subtle: rgba(212,160,64, 0.06) */
/* Same pattern for --glow-hot and --glow-cool */
```

## Typography

| Element | Font | Weight | Size | Tracking |
|---------|------|--------|------|----------|
| Headings | Source Serif 4 (`font-heading`) | 400 | varies | -0.02em |
| Body text | Source Sans 3 (`font-body`) | 400 | base | normal |
| Labels/mono | IBM Plex Mono (`font-mono`) | 400 | xs/sm | 0.05-0.15em, uppercase |

### In Tailwind:
```tsx
<h2 className="font-heading text-3xl tracking-tight text-[var(--foreground)]">
<p className="font-body text-[var(--ember-text)]">
<span className="font-mono text-xs uppercase tracking-wider text-[var(--muted)]">
```

## Spacing & Layout

- Max content width: `max-w-4xl mx-auto` (landing page) or `max-w-6xl` (dashboard)
- Section padding: `py-16` or `py-24`
- Card padding: `p-6` or `p-8`
- Gap between items: `gap-4` (tight) or `gap-8` (relaxed)
- Rounded corners: `rounded-lg` (cards) or `rounded-full` (pills/badges)

## Component Patterns

### Section with heading
```tsx
<section data-narration-id="section-name" className="py-16">
  <div className="max-w-4xl mx-auto px-6">
    <span className="font-mono text-xs uppercase tracking-wider text-[var(--accent)]">
      Section Label
    </span>
    <h2 className="font-heading text-3xl tracking-tight text-[var(--foreground)] mt-2 mb-4">
      Section Title
    </h2>
    <p className="text-[var(--ember-text)] leading-relaxed">
      Description text.
    </p>
  </div>
</section>
```

### Card
```tsx
<div className="rounded-lg border border-[var(--border)] bg-[var(--surface)] p-6">
  <h3 className="font-heading text-lg text-[var(--foreground)] mb-2">
    Card Title
  </h3>
  <p className="text-sm text-[var(--ember-text)]">
    Card content.
  </p>
</div>
```

### Card with temperature glow
```tsx
<div className="rounded-lg border border-[var(--border)] bg-[var(--surface)] p-6 relative overflow-hidden">
  {/* Glow accent */}
  <div
    className="absolute inset-0 opacity-30 pointer-events-none"
    style={{ background: `radial-gradient(ellipse at top left, var(--glow-warm), transparent 60%)` }}
  />
  <div className="relative">
    {/* Card content here */}
  </div>
</div>
```

### Accent dot + label (section indicator)
```tsx
<div className="flex items-center gap-2">
  <div className="w-1.5 h-1.5 rounded-full bg-[var(--accent)]" />
  <span className="font-mono text-xs uppercase tracking-wider text-[var(--muted)]">
    Label Text
  </span>
</div>
```

### Badge / pill
```tsx
<span className="inline-flex items-center rounded-full px-3 py-1 text-xs font-mono uppercase tracking-wider border border-[var(--border)] text-[var(--muted)]">
  Badge Text
</span>
```

### Temperature badge (colored)
```tsx
<span className="inline-flex items-center rounded-full px-3 py-1 text-xs font-mono uppercase tracking-wider"
  style={{ color: 'var(--temp-warm)', borderColor: 'var(--temp-warm)', border: '1px solid' }}>
  Warm
</span>
```

### Button (primary)
```tsx
<button className="rounded-full px-6 py-2.5 text-sm font-mono uppercase tracking-wider bg-[var(--accent)] text-[var(--ember-dark)] hover:opacity-90 transition-opacity">
  Action
</button>
```

### Button (ghost)
```tsx
<button className="rounded-full px-6 py-2.5 text-sm font-mono uppercase tracking-wider border border-[var(--border)] text-[var(--ember-text)] hover:bg-[var(--surface)] transition-colors">
  Secondary
</button>
```

### Divider
```tsx
<div className="border-t border-[var(--border)] my-8" />
```

## Animation Conventions

- Use `transition-opacity` or `transition-colors` for simple hover states
- GSAP for complex animations (already installed)
- Framer Motion `motion.div` for mount/unmount animations
- Keyframe animations defined in `globals.css` — reuse, don't create new ones
- The `aura-breathe` animation is Ava's signature — breathing opacity + subtle scale

## File Conventions

- Components: `'use client'` at top (if using hooks/state)
- Imports: React first, then external, then `@/` aliases, then relative
- Types: Define interfaces near usage, or import from `@/types/database`
- Named exports (not default): `export function ComponentName()`
- Props interface: `interface ComponentNameProps { ... }`

## Landing Page Structure

The landing page (`src/app/page.tsx`) is a scrolling narrated experience.
Sections are revealed progressively by Ava's narration system.
Each section has a `data-narration-id` attribute that the narration controller targets.

Key narration IDs in order:
1. `hero` — Opening (Ava's orb, universal truth, listen button)
2. `under-the-hood` — Chat/Explorer interface
3. `melt-showcase` — The Melt transformation demo
4. `lens-grid` — Analysis lenses visualization
5. `context-modes` — Context mode cards
6. `temperature` — Temperature system showcase
7. `the-door` — Final CTA

## Rules

1. NEVER use raw hex colors. Always CSS variables.
2. NEVER use blue, purple, or any non-warm color. The palette is earth tones only.
3. NEVER use shadows or box-shadow. Use border + glow-gradient for depth.
4. NEVER add decorative elements that don't encode data.
5. Glow is informational (temperature) — never decorative.
6. Keep text concise. Parallax's voice is warm and brief.
7. All interactive elements need `transition-*` for smooth state changes.
8. Respect the narration system — new sections need `data-narration-id`.
