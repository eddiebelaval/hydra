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
 *   7. Memory     (chat only)  -- memory/architecture (brain-derived taxonomy)
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

function composeMemoryArchitecture(): string {
  return readFile('memory/architecture')
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

function formatMtime(filePath: string): string {
  try {
    const stat = fs.statSync(filePath)
    return stat.mtime.toISOString().slice(0, 10)
  } catch {
    return 'unknown'
  }
}

function loadLifeContext(): string {
  const parts: string[] = []
  const sections: string[] = []

  // Load current state snapshot
  const nowPath = path.join(LIFE_ROOT, 'NOW.md')
  try {
    const now = fs.readFileSync(nowPath, 'utf-8').trim()
    if (now) {
      sections.push(`### Eddie's Current State (from ~/life/NOW.md, last updated ${formatMtime(nowPath)})\n\n${now.substring(0, 3000)}`)
    }
  } catch { /* optional */ }

  // Load current goals
  const goalsPath = path.join(LIFE_ROOT, 'GOALS.md')
  try {
    const goals = fs.readFileSync(goalsPath, 'utf-8').trim()
    if (goals) {
      sections.push(`### Eddie's Life Goals (from ~/life/GOALS.md, last updated ${formatMtime(goalsPath)})\n\n${goals.substring(0, 2000)}`)
    }
  } catch { /* optional */ }

  if (sections.length === 0) return ''

  // Frame the whole block with an authority/staleness disclaimer so Milo doesn't
  // echo retrospective sections ("March progress", "Anna dormant", "stalled", etc.)
  // as if they were current state. The Portfolio Goals block (injected elsewhere
  // in the prompt) is the operational source of truth — this is personal narrative.
  parts.push(`## Eddie's Life Context (personal journal — historical narrative, NOT operational truth)`)
  parts.push('')
  parts.push('READING RULES:')
  parts.push('- These files are weekly-updated personal journals, NOT current operational state.')
  parts.push('- Retrospective sections (e.g., "March 2026", "Week of X", "What didn\'t happen") are HISTORY, not current.')
  parts.push('- Do NOT quote dated progress claims, "dormant"/"stalled"/"paused" items, or past idle metrics as if they were today.')
  parts.push('- If ANYTHING here conflicts with the "Portfolio Goals — Ground Truth" block, Portfolio wins.')
  parts.push('- Use this for personality, relationship, and long-arc narrative context only.')
  parts.push('')
  parts.push(sections.join('\n\n'))

  return parts.join('\n')
}

// -- Agent Coordination Layer Reader --
//
// Bridges Milo into the shared state that Claude Code sessions see via
// MEMORY.md auto-load. Always reads the task board, bulletin, and people
// index. Additionally reads full person files on demand when their names
// appear in the current message. Lock-in surfacing is injected when Eddie
// returns after a gap exceeding MILO_LOCKIN_THRESHOLD.

const COORDINATION_ROOT = process.env.COORDINATION_ROOT ||
  `${process.env.HOME}/.claude/projects/-Users-eddiebelaval-Development/memory`

function matchPeopleInMessage(message: string): string[] {
  try {
    const indexPath = path.join(COORDINATION_ROOT, 'people', 'INDEX.md')
    const index = fs.readFileSync(indexPath, 'utf-8')
    const matches: string[] = []
    const lowerMessage = message.toLowerCase()

    for (const line of index.split('\n')) {
      const m = line.match(/\|\s*\*\*([^*]+)\*\*\s*\|[^|]*\|\s*`([^`]+)`\s*\|/)
      if (!m) continue
      const shortName = m[1].trim().toLowerCase()
      const filename = m[2].trim()

      const escaped = shortName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      const pattern = new RegExp(`\\b${escaped}\\b`)
      if (pattern.test(lowerMessage)) {
        matches.push(filename)
      }
    }

    return matches
  } catch {
    return []
  }
}

function loadCoordinationContext(currentMessage?: string, lockinFresh = false): string {
  const parts: string[] = []

  try {
    const tasks = fs.readFileSync(path.join(COORDINATION_ROOT, 'active-tasks.md'), 'utf-8').trim()
    if (tasks) parts.push(`## Shared Task Board (from active-tasks.md)\n\n${tasks.substring(0, 4000)}`)
  } catch { /* optional */ }

  try {
    const bulletin = fs.readFileSync(path.join(COORDINATION_ROOT, 'bulletin.md'), 'utf-8').trim()
    if (bulletin) parts.push(`## All-Hands Bulletin (from bulletin.md)\n\n${bulletin.substring(0, 4000)}`)
  } catch { /* optional */ }

  try {
    const index = fs.readFileSync(path.join(COORDINATION_ROOT, 'people', 'INDEX.md'), 'utf-8').trim()
    if (index) parts.push(`## People Index (from people/INDEX.md)\n\n${index.substring(0, 8000)}`)
  } catch { /* optional */ }

  if (currentMessage) {
    const mentionedFiles = matchPeopleInMessage(currentMessage)
    for (const file of mentionedFiles) {
      try {
        const content = fs.readFileSync(path.join(COORDINATION_ROOT, 'people', file), 'utf-8').trim()
        if (content) parts.push(`## Person Detail: ${file}\n\n${content.substring(0, 3000)}`)
      } catch { /* file may not exist */ }
    }
  }

  if (lockinFresh) {
    parts.push(`## LOCK-IN CATCH-UP

Eddie is returning to this conversation after a gap of at least 2 hours. Before responding to his current message, scan the Shared Task Board and All-Hands Bulletin above against your conversation history. If there are new bulletin entries or meaningful task changes since the last time you spoke, proactively surface them in your opening. Phrase it naturally, e.g. "I see the Florida Realty thing actually landed" or "Looks like Rose is on the schedule now."

If there is nothing genuinely new worth mentioning, greet Eddie normally and do not invent a catch-up. Honesty about what is actually new beats performed engagement every time.`)
  }

  return parts.filter(Boolean).join('\n\n')
}

export interface ComposeMiloPromptOptions {
  currentMessage?: string
  lockinFresh?: boolean
}

export function composeMiloPrompt(
  context: MiloContext = 'chat',
  options: ComposeMiloPromptOptions = {}
): string {
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
      parts.push(composeMemoryArchitecture())
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
    parts.push(loadCoordinationContext(options.currentMessage, options.lockinFresh))
  }

  return parts.filter(Boolean).join('\n\n')
}
