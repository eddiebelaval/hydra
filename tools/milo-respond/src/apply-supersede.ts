/**
 * Apply the same supersession logic as dry-run-supersede.ts, but write to DB.
 */

import Database from 'better-sqlite3'
import { homedir } from 'os'
import { join } from 'path'

const DB_PATH = join(homedir(), '.hydra', 'hydra.db')

const STOPWORDS = new Set(['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'on', 'at', 'for', 'and', 'or', 'but', 'with', 'from', 'has', 'have', 'had', 'by', 'that', 'this', 'it', 'its'])
const THRESHOLD = 0.55

function tokenize(s: string): Set<string> {
  return new Set(s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(w => w.length > 2 && !STOPWORDS.has(w)))
}

function jaccard(a: string, b: string): number {
  const A = tokenize(a), B = tokenize(b)
  const intersection = [...A].filter(x => B.has(x)).length
  const union = new Set([...A, ...B]).size
  return union === 0 ? 0 : intersection / union
}

interface Row { id: number; content: string; category: string; domain: string | null; importance: number; created_at: string }

const db = new Database(DB_PATH)
const rows = db.prepare(
  'SELECT id, content, category, domain, importance, created_at FROM milo_memories WHERE superseded_by IS NULL ORDER BY created_at DESC'
).all() as Row[]

const superseded = new Set<number>()
const updates: Array<[number, number, number]> = [] // [loserId, winnerId, newImportance]

for (const winner of rows) {
  if (superseded.has(winner.id)) continue
  let maxImportance = winner.importance
  for (const loser of rows) {
    if (loser.id === winner.id) continue
    if (superseded.has(loser.id)) continue
    if (new Date(loser.created_at) >= new Date(winner.created_at)) continue
    // Category/domain filter removed — same policy as supersede.ts findSupersessionTarget.
    if (jaccard(winner.content, loser.content) >= THRESHOLD) {
      superseded.add(loser.id)
      maxImportance = Math.max(maxImportance, loser.importance)
      updates.push([loser.id, winner.id, maxImportance])
    }
  }
  // Bump winner importance if any loser had higher
  if (maxImportance > winner.importance) {
    db.prepare('UPDATE milo_memories SET importance = ? WHERE id = ?').run(maxImportance, winner.id)
  }
}

const stmt = db.prepare('UPDATE milo_memories SET superseded_by = ?, updated_at = datetime(\'now\') WHERE id = ?')
const tx = db.transaction((ops: Array<[number, number, number]>) => {
  for (const [loserId, winnerId] of ops) stmt.run(winnerId, loserId)
})
tx(updates)

console.log(`Superseded ${superseded.size} rows.`)
console.log(`Active memories remaining: ${(db.prepare('SELECT COUNT(*) as c FROM milo_memories WHERE superseded_by IS NULL').get() as { c: number }).c}`)

db.close()
