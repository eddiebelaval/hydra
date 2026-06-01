// Shared Canonical Brain Reader
// =============================
//
// ONE implementation of "read the canonical portfolio brain", imported by every
// standalone agent daemon. Replaces the loadMemoryIndex/loadRelevantTopics code
// that was copy-pasted into hydra-router and milo-respond (the originals said
// "duplicated intentionally... Factor out when a third caller appears" -- this
// is that factor-out).
//
// Plain .mjs (node-native ESM) on purpose: the daemon packages run via tsx, and
// binding named exports from a .ts-served-as-.js module across a package
// boundary is flaky. A real .mjs sidesteps the whole transform path.
//
// The canonical brain is the file-tree memory index every Claude Code session
// auto-loads: the MEMORY.md dispatcher + ~133 topic files (project_, feedback_,
// reference_ prefixes). Also mirrored into MemPalace daily
// (com.id8labs.mempalace-canonical-sync) for semantic search.
//
// ── HOW TO PUT A NEW AGENT ON THE BRAIN (the "one line") ──────────────────
//   import { loadCanonicalBrain } from '<relpath>/shared/brain-reader.mjs'
//   // then, when composing the agent's system prompt:
//   parts.push(loadCanonicalBrain(currentMessage))
// That's it -- the agent now reads the same live brain MILO/HYDRA do, current
// to <=24h, with on-message deep recall. No copy-paste, no path to get wrong.
//
// COORDINATION_ROOT env overrides the path (daemons export it explicitly). The
// default MUST be the live `-id8` tree; the pre-move path froze May 4 2026.

import fs from 'fs'
import path from 'path'

export const COORDINATION_ROOT = process.env.COORDINATION_ROOT ||
  path.join(process.env.HOME || '/Users/eddiebelaval',
    '.claude/projects/-Users-eddiebelaval-Development-id8/memory')

// Slug tokens too generic to be a useful on-message match signal.
const TOPIC_STOP_TOKENS = new Set([
  'project', 'feedback', 'reference', 'active', 'first', 'product', 'commissioned',
  'update', 'default', 'pattern', 'patterns', 'system', 'locked', 'works', 'with',
  'this', 'that', 'about', 'into', 'meeting', 'call', 'page',
])

// The dispatcher index -- the agent's window into everything the portfolio
// knows. If Eddie references a workshop, engagement, person, product, or past
// decision, it is catalogued here; the agent must read it, not ask "what?".
export function loadMemoryIndex() {
  try {
    const idx = fs.readFileSync(path.join(COORDINATION_ROOT, 'MEMORY.md'), 'utf-8').trim()
    if (!idx) return ''
    return `## Portfolio Memory Index (shared brain -- the SAME index every Claude Code session loads)

This is the canonical record of what the portfolio knows. If Eddie mentions a workshop, an engagement, a person, a product, or a past decision, it is almost certainly in this index or its linked topic files. NEVER respond as if a catalogued event did not happen -- read the index first.

${idx.substring(0, 24000)}`
  } catch {
    return ''
  }
}

// On-message deep recall: pull the full topic files whose slug keywords appear
// in the message. Surfaces only the relevant compartment (no leakage of
// unrelated topics into the prompt).
export function loadRelevantTopics(message) {
  try {
    const lower = ` ${message.toLowerCase()} `
    const files = fs.readdirSync(COORDINATION_ROOT)
      .filter(f => /^(project|feedback|reference)_.+\.md$/.test(f))
    const scored = []
    for (const f of files) {
      const tokens = f.replace(/\.md$/, '').split('_').slice(1)
        .filter(t => t.length >= 5 && !TOPIC_STOP_TOKENS.has(t))
      let hits = 0
      for (const t of tokens) {
        const esc = t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        if (new RegExp(`\\b${esc}\\b`).test(lower)) hits++
      }
      if (hits > 0) scored.push({ file: f, hits })
    }
    scored.sort((a, b) => b.hits - a.hits)
    const out = []
    for (const { file } of scored.slice(0, 4)) {
      try {
        const c = fs.readFileSync(path.join(COORDINATION_ROOT, file), 'utf-8').trim()
        if (c) out.push(`### ${file}\n\n${c.substring(0, 2500)}`)
      } catch { /* skip */ }
    }
    return out.length
      ? `## Relevant Memory Detail (pulled because the message referenced these topics)\n\n${out.join('\n\n')}`
      : ''
  } catch {
    return ''
  }
}

// The one call a new agent needs: dispatcher index + on-message deep recall,
// joined. Returns '' if the brain is unreadable (never throws -- a memory miss
// must not break an agent turn).
export function loadCanonicalBrain(currentMessage) {
  const parts = []
  const idx = loadMemoryIndex()
  if (idx) parts.push(idx)
  if (currentMessage) {
    const topics = loadRelevantTopics(currentMessage)
    if (topics) parts.push(topics)
  }
  return parts.join('\n\n')
}
