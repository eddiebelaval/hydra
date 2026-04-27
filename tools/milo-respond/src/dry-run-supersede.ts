/**
 * Dry-run the supersession policy across existing milo_memories.
 * Shows which rows would be superseded by which, without writing anything.
 *
 * Walks memories newest-first; for each one, checks whether any OLDER memory
 * (not yet marked for supersession) would be superseded by it under the policy.
 */

import Database from 'better-sqlite3'
import { homedir } from 'os'
import { join } from 'path'

const DB_PATH = join(homedir(), '.hydra', 'hydra.db')

const STOPWORDS = new Set(['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'on', 'at', 'for', 'and', 'or', 'but', 'with', 'from', 'has', 'have', 'had', 'by', 'that', 'this', 'it', 'its'])
const THRESHOLD = 0.55

function tokenize(s: string): Set<string> {
  return new Set(
    s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(w => w.length > 2 && !STOPWORDS.has(w))
  )
}

function jaccard(a: string, b: string): number {
  const A = tokenize(a), B = tokenize(b)
  const intersection = [...A].filter(x => B.has(x)).length
  const union = new Set([...A, ...B]).size
  return union === 0 ? 0 : intersection / union
}

interface Row {
  id: number
  content: string
  category: string
  domain: string | null
  importance: number
  created_at: string
}

const db = new Database(DB_PATH, { readonly: true })
const rows = db.prepare(
  'SELECT id, content, category, domain, importance, created_at FROM milo_memories WHERE superseded_by IS NULL ORDER BY created_at DESC'
).all() as Row[]

const superseded = new Set<number>()
const pairs: Array<{ winner: Row; loser: Row; score: number }> = []

for (const winner of rows) {
  if (superseded.has(winner.id)) continue
  for (const loser of rows) {
    if (loser.id === winner.id) continue
    if (superseded.has(loser.id)) continue
    if (new Date(loser.created_at) >= new Date(winner.created_at)) continue // only supersede older
    if (loser.category !== winner.category) continue
    if ((loser.domain || null) !== (winner.domain || null)) continue
    const score = jaccard(winner.content, loser.content)
    if (score >= THRESHOLD) {
      superseded.add(loser.id)
      pairs.push({ winner, loser, score })
    }
  }
}

console.log(`Total active memories: ${rows.length}`)
console.log(`Would be superseded: ${superseded.size}`)
console.log(`Survivors: ${rows.length - superseded.size}\n`)
console.log('--- Supersession pairs (winner <- loser, jaccard) ---\n')

// Group by winner for readability
const byWinner = new Map<number, typeof pairs>()
for (const p of pairs) {
  if (!byWinner.has(p.winner.id)) byWinner.set(p.winner.id, [])
  byWinner.get(p.winner.id)!.push(p)
}

for (const [winnerId, group] of byWinner) {
  const w = group[0].winner
  console.log(`KEEP [${winnerId}] (${w.category}/${w.domain || '-'}, imp=${w.importance})`)
  console.log(`  "${w.content.substring(0, 100)}${w.content.length > 100 ? '...' : ''}"`)
  for (const p of group) {
    console.log(`  SUPERSEDE [${p.loser.id}] j=${p.score.toFixed(2)} imp=${p.loser.importance}`)
    console.log(`    "${p.loser.content.substring(0, 100)}${p.loser.content.length > 100 ? '...' : ''}"`)
  }
  console.log()
}

db.close()
