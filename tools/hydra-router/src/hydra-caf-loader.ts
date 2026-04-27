/**
 * CaF Loader for HYDRA Entity
 *
 * Loads HYDRA's consciousness from ~/.hydra/mind/.
 * Two composition contexts:
 *   - 'route': Lean prompt for intent classification (~1200 tokens).
 *              Only loads models/entities.md + models/routing.md.
 *   - 'respond': Full consciousness for direct handling (~2500 tokens).
 *              Loads all 5 layers: kernel, drives, models, relationships, memory.
 *
 * Pattern adapted from milo-respond/src/caf-loader.ts.
 */

import fs from 'fs'
import path from 'path'
import type { HydraContext } from './types.js'

const MIND_ROOT = process.env.HYDRA_MIND_ROOT || path.join(
  process.env.HOME || '/Users/eddiebelaval',
  '.hydra/mind'
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

// Layer 1: Kernel (identity, purpose, values, voice)
function composeKernel(): string {
  return readDir('kernel')
}

// Layer 2: Drives (goals, fears)
function composeDrives(): string {
  return readDir('drives')
}

// Layer 3: Models (self, entities, routing)
function composeModels(): string {
  return readDir('models')
}

// Routing-only subset: just the entity registry and heuristics
function composeRoutingModels(): string {
  const entities = readFile('models/entities')
  const routing = readFile('models/routing')
  return [entities, routing].filter(Boolean).join('\n\n')
}

// Layer 4: Relationships (eddie)
function composeRelationships(): string {
  return readFile('relationships/eddie')
}

// Layer 5: Memory Architecture (MaF -- how HYDRA thinks about memory)
function composeMemoryArchitecture(): string {
  return readFile('memory/architecture')
}

// -- Agent Coordination Layer Reader --
//
// HYDRA is the centralized router and operational entity. She must see the
// same shared state that Claude Code sessions and Milo see, so when Eddie
// asks HYDRA about tasks, people, or recent bulletin events, she responds
// from the same source of truth. Mirror of milo-respond/caf-loader.ts
// loadCoordinationContext -- duplicated intentionally because the two
// packages do not share a common module today. Factor out when a third
// caller appears.

const COORDINATION_ROOT = process.env.COORDINATION_ROOT ||
  path.join(process.env.HOME || '/Users/eddiebelaval',
    '.claude/projects/-Users-eddiebelaval-Development/memory')

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

Eddie is returning to this conversation after a gap of at least 2 hours. Before responding to his current message, scan the Shared Task Board and All-Hands Bulletin above. If there are new bulletin entries or meaningful task changes since the last time you spoke to him, proactively acknowledge them in your opening. HYDRA-specific phrasing: lead with the operational state change, not small talk. Example: "The Florida Realty partnership landed yesterday, and the legal track now has a hard deadline on Rose."

If there is nothing genuinely new worth mentioning, respond to Eddie's actual question without inventing a catch-up.`)
  }

  return parts.filter(Boolean).join('\n\n')
}

export interface ComposeHydraPromptOptions {
  currentMessage?: string
  lockinFresh?: boolean
}

/**
 * Compose HYDRA's system prompt.
 *
 * @param context - 'route' for lean classification, 'respond' for full direct handling
 * @param options - Optional currentMessage (for people-index matching) and lockinFresh (for 2hr+ gap catch-up)
 * @returns Composed system prompt string
 */
export function composeHydraPrompt(
  context: HydraContext = 'respond',
  options: ComposeHydraPromptOptions = {}
): string {
  const parts: string[] = []

  switch (context) {
    case 'route': {
      // Lean prompt: just enough to classify intent
      // Skip kernel/drives/relationships AND coordination layer to minimize tokens
      parts.push(composeRoutingModels())
      break
    }
    case 'respond': {
      // Full consciousness for direct handling
      parts.push(composeKernel())
      parts.push(composeDrives())
      parts.push(composeModels())
      parts.push(composeRelationships())
      parts.push(composeMemoryArchitecture())
      // Shared coordination layer -- only in respond context, not route
      parts.push(loadCoordinationContext(options.currentMessage, options.lockinFresh))
      break
    }
  }

  return parts.filter(Boolean).join('\n\n')
}
