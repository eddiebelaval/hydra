#!/usr/bin/env tsx
/**
 * One-time memory re-classification script.
 * Uses Haiku to re-categorize existing memories from 6 categories to 16.
 *
 * Usage: npx tsx src/reclassify-memories.ts [--dry-run]
 */

import Anthropic from '@anthropic-ai/sdk'
import Database from 'better-sqlite3'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const DRY_RUN = process.argv.includes('--dry-run')

const CATEGORIES = [
  'fact', 'preference', 'relationship', 'decision', 'project', 'pattern',
  'antipattern', 'milestone', 'observation', 'feedback', 'location', 'trip',
  'event_memory', 'routine', 'financial', 'health',
] as const

async function reclassify(memories: Array<{ id: number; content: string; category: string }>): Promise<Array<{ id: number; category: string; domain: string | null }>> {
  const client = new Anthropic()

  const memoryList = memories.map((m, i) => `${i}. [${m.category}] ${m.content}`).join('\n')

  const response = await client.messages.create({
    model: process.env.MILO_EXTRACTION_MODEL || 'claude-haiku-4-5-20251001',
    max_tokens: 2000,
    messages: [{
      role: 'user',
      content: `Re-classify these memories about Eddie Belaval into the correct categories.

Current memories:
${memoryList}

Categories (pick the most specific one):
- fact: verifiable biographical fact
- preference: how Eddie likes things
- relationship: who someone is
- decision: a committed choice
- project: project state or status
- pattern: something that works (repeatable approach)
- antipattern: something that fails (trap or bad habit)
- milestone: significant past event or achievement
- observation: an analytical insight about Eddie
- feedback: behavioral correction from Eddie
- location: a place that matters
- trip: a journey or travel experience
- event_memory: notable past event (not trip/milestone)
- routine: recurring habit
- financial: money-related
- health: physical/mental health

Return ONLY valid JSON array (no markdown):
[{"index": 0, "category": "project", "domain": "homer"}, ...]

Domain is the project or life area (homer, parallax, trading, cpn, profesa, fitness, family, etc). Use null if not specific.`,
    }],
  })

  const text = response.content[0].type === 'text' ? response.content[0].text : ''
  try {
    const jsonMatch = text.match(/\[[\s\S]*\]/)
    if (jsonMatch) {
      const results = JSON.parse(jsonMatch[0]) as Array<{ index: number; category: string; domain: string | null }>
      return results.map(r => ({
        id: memories[r.index].id,
        category: CATEGORIES.includes(r.category as typeof CATEGORIES[number]) ? r.category : memories[r.index].category,
        domain: r.domain,
      }))
    }
  } catch { /* fall through */ }

  return []
}

async function main() {
  const db = new Database(DB_PATH, { readonly: DRY_RUN })

  try {
    const memories = db.prepare(`
      SELECT id, content, category FROM milo_memories
      WHERE superseded_by IS NULL
      ORDER BY id ASC
    `).all() as Array<{ id: number; content: string; category: string }>

    console.log(`Found ${memories.length} active memories to re-classify`)
    if (DRY_RUN) console.log('DRY RUN -- no changes will be made\n')

    // Process in batches of 20 to stay within Haiku context
    const batchSize = 20
    let updated = 0
    let unchanged = 0

    for (let i = 0; i < memories.length; i += batchSize) {
      const batch = memories.slice(i, i + batchSize)
      console.log(`Processing batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(memories.length / batchSize)}...`)

      const results = await reclassify(batch)

      for (const r of results) {
        const original = batch.find(m => m.id === r.id)
        if (!original) continue

        const categoryChanged = r.category !== original.category
        const domainAdded = r.domain !== null

        if (categoryChanged || domainAdded) {
          if (!DRY_RUN) {
            db.prepare('UPDATE milo_memories SET category = ?, domain = ? WHERE id = ?').run(r.category, r.domain, r.id)
          }
          console.log(`  #${r.id}: ${original.category} -> ${r.category}${r.domain ? ` [${r.domain}]` : ''} -- "${original.content.substring(0, 60)}..."`)
          updated++
        } else {
          unchanged++
        }
      }
    }

    console.log(`\nDone. ${updated} updated, ${unchanged} unchanged.`)
  } finally {
    db.close()
  }
}

main().catch(err => {
  process.stderr.write(`Re-classification error: ${err.message}\n`)
  process.exit(1)
})
