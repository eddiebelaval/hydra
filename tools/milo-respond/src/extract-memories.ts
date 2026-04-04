#!/usr/bin/env tsx
/**
 * Memory & Mood Extractor
 *
 * Runs async after each conversation turn. Uses Haiku for cheap extraction.
 * Extracts persistent memories and mood signals from the exchange.
 */

import Anthropic from '@anthropic-ai/sdk'
import Database from 'better-sqlite3'

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

interface Extraction {
  memories: Array<{
    content: string
    category: 'fact' | 'preference' | 'project_context' | 'relationship' | 'milestone' | 'decision'
    importance: number
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
    {"content": "one sentence fact worth remembering", "category": "fact|preference|project_context|relationship|milestone|decision", "importance": 1-10}
  ],
  "mood": "one word mood or null",
  "energy": "high|medium|low or null",
  "mood_context": "brief context for the mood or null"
}

Rules:
- Only extract memories that are NEW information worth keeping long-term
- Skip trivial exchanges, greetings, or information already obvious from context
- Category "decision" = Eddie committed to doing something
- Category "milestone" = Something significant happened or was completed
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
    // Save memories (with basic dedup)
    for (const mem of extraction.memories) {
      const existing = db.prepare(
        'SELECT id FROM milo_memories WHERE content LIKE ? AND superseded_by IS NULL'
      ).get(`%${mem.content.substring(0, 30)}%`)

      if (!existing) {
        db.prepare('INSERT INTO milo_memories (content, category, importance) VALUES (?, ?, ?)').run(
          mem.content, mem.category, mem.importance
        )
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
