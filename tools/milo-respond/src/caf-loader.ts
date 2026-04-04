/**
 * CaF Loader for Telegram Milo
 *
 * Adapted from ~/Development/id8/products/milo/electron/ai/mind/loader.ts
 * Same 6-layer architecture, same loading rules, standalone for HYDRA daemon use.
 *
 * Layers:
 *   1. Brainstem  (always)     -- kernel/
 *   2. Limbic     (always)     -- emotional/ (no wounds)
 *   3. Drives     (chat only)  -- drives/
 *   4. Models     (per context) -- models/
 *   5. Relational (chat only)  -- relationships/ + wound behavioral residue
 *   6. Habits     (at edges)   -- habits/ (routines + creative, no coping)
 */

import fs from 'fs'
import path from 'path'
import type { MiloContext } from './types.js'

const MIND_ROOT = path.join(
  process.env.MILO_MIND_ROOT ||
  '/Users/eddiebelaval/Development/id8/products/milo/src/mind'
)

function readFile(relativePath: string): string {
  try {
    const ext = path.extname(relativePath) ? '' : '.md'
    const fullPath = path.join(MIND_ROOT, `${relativePath}${ext}`)
    return fs.readFileSync(fullPath, 'utf-8').trim()
  } catch {
    return ''
  }
}

function readDir(relativePath: string): string {
  try {
    const dirPath = path.join(MIND_ROOT, relativePath)
    const files = fs.readdirSync(dirPath)
      .filter(f => f.endsWith('.md') && !f.startsWith('.'))
      .sort()
    return files
      .map(file => {
        try {
          return fs.readFileSync(path.join(dirPath, file), 'utf-8').trim()
        } catch {
          return ''
        }
      })
      .filter(Boolean)
      .join('\n\n')
  } catch {
    return ''
  }
}

function extractSection(content: string, heading: string): string {
  const lines = content.split('\n')
  let capturing = false
  let headingLevel = 0
  const captured: string[] = []

  for (const line of lines) {
    const match = line.match(/^(#{1,6})\s+(.+)/)
    if (match) {
      if (match[2].trim() === heading) {
        capturing = true
        headingLevel = match[1].length
        continue
      } else if (capturing && match[1].length <= headingLevel) {
        break
      }
    }
    if (capturing) {
      captured.push(line)
    }
  }

  return captured.join('\n').trim()
}

// Layer composers (no caching -- fresh per invocation since this is a CLI tool)

function composeBrainstem(): string {
  return readDir('kernel')
}

function composeLimbic(): string {
  const state = readFile('emotional/state')
  const patterns = readFile('emotional/patterns')
  const attachments = readFile('emotional/attachments')
  return [state, patterns, attachments].filter(Boolean).join('\n\n')
}

function composeDrives(): string {
  return readDir('drives')
}

function composeModels(): string {
  return readDir('models')
}

function composeRelational(): string {
  const eddie = readFile('relationships/active/eddie')
  const wounds = readFile('emotional/wounds')
  const residue = extractSection(wounds, 'Behavioral Residue')

  const parts = [eddie]
  if (residue) {
    parts.push(`## Behavioral Patterns (Self-Monitoring)\n\n${residue}`)
  }

  return parts.filter(Boolean).join('\n\n')
}

function composeHabits(): string {
  const routines = readFile('habits/routines')
  const creative = readFile('habits/creative')
  return [routines, creative].filter(Boolean).join('\n\n')
}

// -- Training Docs (operational intelligence) --

const BRAIN_ROOT = process.env.MILO_BRAIN_ROOT || `${process.env.HOME}/.hydra/milo-brain`

function loadBrainDoc(name: string): string {
  try {
    return fs.readFileSync(path.join(BRAIN_ROOT, name), 'utf-8').trim()
  } catch {
    return ''
  }
}

function composeBrain(context: MiloContext): string {
  const parts: string[] = []

  // Always load north star (concise, ~500 tokens)
  parts.push(loadBrainDoc('NORTH_STAR.md'))

  if (context === 'chat') {
    // Full brain for conversation
    parts.push(loadBrainDoc('DRIVES.md'))
    parts.push(loadBrainDoc('EXECUTION.md'))
  } else {
    // For heartbeat/nudge, just north star + accountability rules from execution
    const exec = loadBrainDoc('EXECUTION.md')
    const accountability = extractSection(exec, 'Accountability Rules')
    if (accountability) parts.push(`## Accountability Rules\n\n${accountability}`)
  }

  return parts.filter(Boolean).join('\n\n')
}

// -- Life Triad Reader --

const LIFE_ROOT = process.env.LIFE_ROOT || `${process.env.HOME}/life`

function loadLifeContext(): string {
  const parts: string[] = []

  // Load current state snapshot
  try {
    const now = fs.readFileSync(path.join(LIFE_ROOT, 'NOW.md'), 'utf-8').trim()
    if (now) parts.push(`## Eddie's Current State (from ~/life/NOW.md)\n\n${now.substring(0, 3000)}`)
  } catch { /* optional */ }

  // Load current goals
  try {
    const goals = fs.readFileSync(path.join(LIFE_ROOT, 'GOALS.md'), 'utf-8').trim()
    if (goals) parts.push(`## Eddie's Life Goals (from ~/life/GOALS.md)\n\n${goals.substring(0, 2000)}`)
  } catch { /* optional */ }

  return parts.filter(Boolean).join('\n\n')
}

export function composeMiloPrompt(context: MiloContext = 'chat'): string {
  const parts: string[] = []

  // Layer 1: CaF Consciousness (who Milo IS)
  parts.push(composeBrainstem())

  switch (context) {
    case 'chat': {
      parts.push(composeLimbic())
      parts.push(composeDrives())
      parts.push(composeModels())
      parts.push(composeRelational())
      parts.push(composeHabits())
      break
    }
    case 'morning_briefing': {
      parts.push(composeDrives())
      break
    }
    case 'evening_review': {
      const selfModel = readFile('models/self')
      if (selfModel) parts.push(selfModel)
      break
    }
    case 'nudge': {
      break
    }
  }

  // Layer 2: Training Docs (what Milo KNOWS about the relationship)
  parts.push(composeBrain(context))

  // Layer 3: Life Triad (Eddie's life context -- chat only, too much for nudges)
  if (context === 'chat') {
    parts.push(loadLifeContext())
  }

  return parts.filter(Boolean).join('\n\n')
}
