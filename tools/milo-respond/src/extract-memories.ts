#!/usr/bin/env tsx
/**
 * Memory & Mood Extractor
 *
 * Runs async after each conversation turn. Uses Haiku for cheap extraction.
 * Extracts persistent memories and mood signals from the exchange.
 */

import Anthropic from '@anthropic-ai/sdk'
import Database from 'better-sqlite3'
import { findSupersessionTarget } from './supersede.js'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const TRIVIAL = /^(ok|yes|no|thanks|cool|got it|sure|yep|nah|k|lol|haha|nice)$/i

function parseArgs(): { userMessage: string; assistantMessage: string } {
  const args = process.argv.slice(2)
  let userMessage = ''
  let assistantMessage = ''

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--user-message' && args[i + 1]) userMessage = args[++i]
    else if (args[i] === '--assistant-message' && args[i + 1]) assistantMessage = args[++i]
  }

  return { userMessage, assistantMessage }
}

type MemoryCategory = 'fact' | 'preference' | 'relationship' | 'decision' | 'project' | 'pattern' | 'antipattern' | 'milestone' | 'observation' | 'feedback' | 'location' | 'trip' | 'event_memory' | 'routine' | 'financial' | 'health'

interface Extraction {
  memories: Array<{
    content: string
    category: MemoryCategory
    importance: number
    domain: string | null
  }>
  mood: string | null
  energy: string | null
  mood_context: string | null
}

async function extract(userMessage: string, assistantMessage: string): Promise<Extraction> {
  const client = new Anthropic()

  const response = await client.messages.create({
    model: process.env.MILO_EXTRACTION_MODEL || 'claude-haiku-4-5-20251001',
    max_tokens: 500,
    messages: [{
      role: 'user',
      content: `Extract memories and mood from this exchange between Eddie and his AI assistant Milo.

Eddie: ${userMessage}
Milo: ${assistantMessage}

Return ONLY valid JSON (no markdown):
{
  "memories": [
    {"content": "one sentence fact worth remembering", "category": "fact", "importance": 5, "domain": "homer"}
  ],
  "mood": "one word mood or null",
  "energy": "high|medium|low or null",
  "mood_context": "brief context for the mood or null"
}

Memory categories (pick the most specific one):
- fact: verifiable biographical fact about Eddie
- preference: how Eddie likes things done
- relationship: who someone is and how Eddie relates to them
- decision: a choice Eddie committed to, with reasoning
- project: current state or key detail about a specific project
- pattern: something that works, a repeatable approach
- antipattern: something that fails, a trap or bad habit
- milestone: a significant past event or achievement
- observation: something you notice about Eddie (your own analysis)
- feedback: how Eddie told you to behave differently
- location: a place that matters to Eddie
- trip: a journey or travel experience
- event_memory: a notable past event (not a trip or milestone)
- routine: a recurring habit or ritual
- financial: money-related fact or event
- health: physical or mental health observation

Domain is optional -- the project or life area this relates to (e.g., homer, parallax, trading, cpn, fitness, family). Use null if not specific.

Rules:
- Only extract memories that are NEW information worth keeping long-term
- Skip trivial exchanges, greetings, or information already obvious from context
- Importance 8-10 = life/business changing. 5-7 = notable. 1-4 = minor but worth noting.
- If nothing worth extracting, return empty memories array
- Mood should reflect Eddie's emotional state, not the topic`,
    }],
  })

  const text = response.content[0].type === 'text' ? response.content[0].text : ''
  try {
    const jsonMatch = text.match(/\{[\s\S]*\}/)
    if (jsonMatch) return JSON.parse(jsonMatch[0])
  } catch { /* fall through */ }

  return { memories: [], mood: null, energy: null, mood_context: null }
}

async function main() {
  const { userMessage, assistantMessage } = parseArgs()

  // Skip trivial messages
  if (!userMessage || userMessage.length < 10 || TRIVIAL.test(userMessage.trim())) return

  const extraction = await extract(userMessage, assistantMessage)
  const db = new Database(DB_PATH, { readonly: false })

  try {
    // Save memories with supersession-based dedup (see supersede.ts).
    for (const mem of extraction.memories) {
      const incoming = {
        content: mem.content,
        category: mem.category,
        domain: mem.domain || null,
        importance: mem.importance
      }
      // Find target BEFORE inserting so we don't match the new row.
      const targetId = findSupersessionTarget(db, incoming)
      const targetImportance = targetId !== null
        ? (db.prepare('SELECT importance FROM milo_memories WHERE id = ?').get(targetId) as { importance: number } | undefined)?.importance ?? incoming.importance
        : incoming.importance
      const finalImportance = Math.max(incoming.importance, targetImportance)

      const info = db.prepare(
        'INSERT INTO milo_memories (content, category, importance, domain) VALUES (?, ?, ?, ?)'
      ).run(incoming.content, incoming.category, finalImportance, incoming.domain)
      const newId = info.lastInsertRowid as number

      if (targetId !== null) {
        db.prepare('UPDATE milo_memories SET superseded_by = ?, updated_at = datetime(\'now\') WHERE id = ?').run(newId, targetId)
      }
    }

    // Save mood
    if (extraction.mood) {
      db.prepare('INSERT INTO milo_mood_journal (mood, energy_level, context) VALUES (?, ?, ?)').run(
        extraction.mood, extraction.energy, extraction.mood_context
      )
    }
  } finally {
    db.close()
  }
}

main().catch(err => {
  process.stderr.write(`Memory extraction error: ${err.message}\n`)
})
