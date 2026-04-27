#!/usr/bin/env tsx
/**
 * Conversation Summarizer
 *
 * Compresses older conversation turns into summaries.
 * Called when unsummarized turns exceed threshold.
 */

import Anthropic from '@anthropic-ai/sdk'
import Database from 'better-sqlite3'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const BLOCK_SIZE = 20

async function main() {
  const db = new Database(DB_PATH, { readonly: false })

  try {
    // Find unsummarized turns beyond the rolling window
    const maxId = db.prepare('SELECT COALESCE(MAX(id), 0) as max FROM milo_conversations').get() as { max: number }
    const windowStart = maxId.max - 40 // Keep last 40 in rolling window

    if (windowStart <= 0) return

    // Find the last summarized turn
    const lastSummary = db.prepare(
      'SELECT COALESCE(MAX(turn_range_end), 0) as last_end FROM milo_conversation_summaries'
    ).get() as { last_end: number }

    const unsummarizedStart = lastSummary.last_end + 1
    if (unsummarizedStart >= windowStart) return

    // Get unsummarized turns
    const turns = db.prepare(`
      SELECT id, role, content, created_at
      FROM milo_conversations
      WHERE id >= ? AND id < ? AND role IN ('user', 'assistant')
      ORDER BY id ASC
    `).all(unsummarizedStart, windowStart) as Array<{ id: number; role: string; content: string; created_at: string }>

    if (turns.length < BLOCK_SIZE) return

    // Summarize in blocks
    const client = new Anthropic()

    for (let i = 0; i < turns.length; i += BLOCK_SIZE) {
      const block = turns.slice(i, i + BLOCK_SIZE)
      if (block.length < 5) continue // Skip tiny blocks

      const conversation = block.map(t =>
        `${t.role === 'user' ? 'Eddie' : 'Milo'}: ${t.content.substring(0, 500)}`
      ).join('\n')

      const response = await client.messages.create({
        model: process.env.MILO_EXTRACTION_MODEL || 'claude-haiku-4-5-20251001',
        max_tokens: 400,
        messages: [{
          role: 'user',
          content: `Summarize this conversation between Eddie and Milo in 2-3 sentences. Capture key topics, decisions made, and emotional tone.

${conversation}

Return ONLY valid JSON (no markdown):
{"summary": "...", "key_topics": ["..."], "key_decisions": ["..."], "emotional_tone": "..."}`,
        }],
      })

      const text = response.content[0].type === 'text' ? response.content[0].text : ''
      try {
        const jsonMatch = text.match(/\{[\s\S]*\}/)
        if (jsonMatch) {
          const parsed = JSON.parse(jsonMatch[0])
          db.prepare(`
            INSERT INTO milo_conversation_summaries
            (summary, turn_range_start, turn_range_end, turn_count, key_topics, key_decisions, emotional_tone)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          `).run(
            parsed.summary,
            block[0].id,
            block[block.length - 1].id,
            block.length,
            JSON.stringify(parsed.key_topics || []),
            JSON.stringify(parsed.key_decisions || []),
            parsed.emotional_tone || null
          )
        }
      } catch { /* skip failed parse */ }
    }
  } finally {
    db.close()
  }
}

main().catch(err => {
  process.stderr.write(`Summarization error: ${err.message}\n`)
})
