# Skill: Component Creation

You can create new React components in `src/components/landing/`.

## Component template

Every new component should follow this pattern:

```tsx
'use client'

import { useState } from 'react'

interface YourComponentProps {
  // Props here
}

export function YourComponent({ }: YourComponentProps) {
  return (
    <section data-narration-id="your-section" className="py-16">
      <div className="max-w-4xl mx-auto px-6">
        {/* Accent dot + label */}
        <div className="flex items-center gap-2 mb-4">
          <div className="w-1.5 h-1.5 rounded-full bg-[var(--accent)]" />
          <span className="font-mono text-xs uppercase tracking-wider text-[var(--muted)]">
            Section Label
          </span>
        </div>

        {/* Heading */}
        <h2 className="font-heading text-3xl tracking-tight text-[var(--foreground)] mb-4">
          Section Title
        </h2>

        {/* Content */}
        <p className="text-[var(--ember-text)] leading-relaxed">
          Content here.
        </p>
      </div>
    </section>
  )
}
```

## Checklist for new components

1. `'use client'` directive at top (if using hooks/state/events)
2. Named export (not default)
3. TypeScript interface for props
4. `data-narration-id` if this section is part of the narration
5. Use design kit tokens — never hardcoded colors
6. Import into `src/app/page.tsx` and place in section order
7. Add narration step if needed (see narration-system skill)

## Imports

```tsx
// React
import { useState, useEffect, useCallback } from 'react'
// External libraries (if needed)
import { motion } from 'framer-motion'
// Internal — use @/ alias
import { SomeHook } from '@/hooks/useSomeHook'
import type { SomeType } from '@/types/database'
```
