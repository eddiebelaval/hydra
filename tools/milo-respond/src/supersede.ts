/**
 * Supersession policy for milo_memories.
 *
 * Called by save_memory (tool-executor.ts) and extract-memories.ts before
 * inserting a new memory row. Returns the id of a memory that should be
 * superseded, or null if the new memory is distinct.
 *
 * Design: supersession preserves history (row stays, just marked as superseded).
 * Queries with `superseded_by IS NULL` skip them. This is safer than delete.
 */

import Database from 'better-sqlite3'

export interface Candidate {
  id: number
  content: string
  category: string
  domain: string | null
  importance: number
  created_at: string
}

export interface IncomingMemory {
  content: string
  category: string
  domain: string | null
  importance: number
}

/**
 * Finds the id of a memory that `incoming` supersedes, or null if the
 * incoming memory is distinct.
 *
 * This is the ONE judgment call that shapes how Milo's memory evolves.
 * The trade-off: aggressive supersession keeps recall clean but may
 * collapse distinct facts; conservative supersession preserves nuance
 * but lets duplicate-feeling entries accumulate.
 *
 * TODO(eddie): implement the policy. See the 3 candidate approaches below
 * in shouldSupersede(). Pick one or mix.
 */
export function findSupersessionTarget(
  db: Database.Database,
  incoming: IncomingMemory
): number | null {
  // Candidate pool = all active memories in the last 30 days.
  // We do NOT filter by category/domain because the extractor writes the same
  // fact with drifting tags between turns (e.g. domain=NULL then domain=homer),
  // which would hide the older row from supersession. Jaccard is the arbiter.
  const candidates = db.prepare(`
    SELECT id, content, category, domain, importance, created_at
    FROM milo_memories
    WHERE superseded_by IS NULL
      AND created_at >= datetime('now', '-30 days')
    ORDER BY created_at DESC, id DESC
    LIMIT 200
  `).all() as Candidate[]

  for (const c of candidates) {
    // Incoming must be strictly newer than the candidate. For equal timestamps,
    // a higher id wins. The mask trick in self-repair sets this row's id aside,
    // so when called from save_memory, any candidate is fair game.
    if (shouldSupersede(incoming, c)) {
      return c.id
    }
  }
  return null
}

/**
 * Returns true if `incoming` should supersede `existing`.
 *
 * === POLICY DECISION — EDDIE FILLS THIS IN ===
 *
 * Option A (conservative): exact content match only.
 *   return incoming.content === existing.content
 *
 * Option B (keyword-overlap): treat as same topic if they share >= N
 *   distinctive words (stopwords removed). Supersede older.
 *   const overlap = jaccardWords(incoming.content, existing.content)
 *   return overlap >= 0.6
 *
 * Option C (entity + count): if both mention the same named entity
 *   (e.g. "cohort", "LOLA", "Canopy") and a number, the newer one supersedes.
 *   This catches "cohort grew to 30" → "cohort grew to 47" cleanly but
 *   keeps "Eddie started a new cohort" distinct because it lacks a number.
 *
 * My recommendation: B at threshold 0.55, because it handles the actual
 * duplicates in your data (cohort variants, LOLA pivot restatements) without
 * collapsing contextual entries like "Friday Gus meeting is the convergence
 * point with LOLA dialed in, cohort at 47".
 */
const SUPERSESSION_THRESHOLD = 0.55

function shouldSupersede(incoming: IncomingMemory, existing: Candidate): boolean {
  if (incoming.content.trim().toLowerCase() === existing.content.trim().toLowerCase()) return true
  return jaccardWords(incoming.content, existing.content) >= SUPERSESSION_THRESHOLD
}

function jaccardWords(a: string, b: string): number {
  const STOPWORDS = new Set(['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'on', 'at', 'for', 'and', 'or', 'but', 'with', 'from', 'has', 'have', 'had', 'by', 'that', 'this', 'it', 'its'])
  const tokenize = (s: string) => new Set(
    s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(w => w.length > 2 && !STOPWORDS.has(w))
  )
  const A = tokenize(a), B = tokenize(b)
  const intersection = [...A].filter(x => B.has(x)).length
  const union = new Set([...A, ...B]).size
  return union === 0 ? 0 : intersection / union
}
