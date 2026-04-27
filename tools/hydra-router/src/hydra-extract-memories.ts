#!/usr/bin/env tsx
/**
 * HYDRA Memory & Routing Insight Extractor
 *
 * Runs async after HYDRA-handled conversations. Uses Haiku for cheap extraction.
 * Extracts operational memories: routing preferences, entity insights, feedback.
 *
 * Only runs for HYDRA-handled messages (system ops). Milo-handled messages
 * use Milo's own extractor (extract-memories.ts in milo-respond).
 */

import Anthropic from '@anthropic-ai/sdk'
import { saveMemory } from './hydra-memory-db.js'
import type { HydraMemoryCategory } from './hydra-memory-db.js'

const TRIVIAL = /^(ok|yes|no|thanks|cool|got it|sure|yep|nah|k|lol|haha|nice)$/i

function parseArgs(): { userMessage: string; assistantMessage: string; routeEntity: string; routeReason: string } {
  const args = process.argv.slice(2)
  let userMessage = ''
  let assistantMessage = ''
  let routeEntity = ''
  let routeReason = ''

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--user-message' && args[i + 1]) userMessage = args[++i]
    else if (args[i] === '--assistant-message' && args[i + 1]) assistantMessage = args[++i]
    else if (args[i] === '--route-entity' && args[i + 1]) routeEntity = args[++i]
    else if (args[i] === '--route-reason' && args[i + 1]) routeReason = args[++i]
  }

  return { userMessage, assistantMessage, routeEntity, routeReason }
}

interface HydraExtraction {
  memories: Array<{
    content: string
    category: HydraMemoryCategory
    importance: number
    domain: string | null
  }>
}

async function extract(
  userMessage: string,
  assistantMessage: string,
  routeEntity: string,
  routeReason: string,
): Promise<HydraExtraction> {
  const client = new Anthropic()

  const response = await client.messages.create({
    model: process.env.HYDRA_EXTRACTION_MODEL || 'claude-haiku-4-5-20251001',
    max_tokens: 300,
    messages: [{
      role: 'user',
      content: `Extract operational memories from this exchange between Eddie and HYDRA (the system coordinator).

Routing: Eddie's message was routed to ${routeEntity} (reason: ${routeReason}).

Eddie: ${userMessage}
HYDRA: ${assistantMessage}

Return ONLY valid JSON (no markdown):
{
  "memories": [
    {"content": "one sentence operational insight", "category": "routing_preference", "importance": 5, "domain": "milo"}
  ]
}

Categories (pick the most specific):
- routing_preference: how Eddie prefers to be routed ("Eddie prefers Milo for morning check-ins")
- routing_pattern: repeatable routing observation ("Design questions always go to Iris")
- entity_insight: observation about entity performance ("Axis handles pricing well")
- feedback: Eddie correcting HYDRA's behavior ("Stop routing X to Y")
- observation: your analytical insight about the system ("Eddie's patterns shifted this week")
- fact: operational fact ("The morning planner fires at 8 AM")
- system_event: significant system event ("409 conflict on Milo bot")
- entity_preference: Eddie stated he prefers an entity for something ("I want Axis for all CPN strategy")

Domain is optional -- the entity or system area this relates to (e.g., milo, axis, iris, hydra, telegram). Use null if general.

Rules:
- Only extract memories that are NEW operational insights
- Skip trivial exchanges or information already in the routing rules
- Importance 8-10 = changes routing behavior. 5-7 = useful pattern. 1-4 = minor observation.
- If nothing worth extracting, return empty memories array
- HYDRA only cares about routing and system operations, not personal facts`,
    }],
  })

  const text = response.content[0].type === 'text' ? response.content[0].text : ''
  try {
    const jsonMatch = text.match(/\{[\s\S]*\}/)
    if (jsonMatch) return JSON.parse(jsonMatch[0])
  } catch { /* fall through */ }

  return { memories: [] }
}

async function main() {
  const { userMessage, assistantMessage, routeEntity, routeReason } = parseArgs()

  // Skip trivial messages
  if (!userMessage || userMessage.length < 10 || TRIVIAL.test(userMessage.trim())) return

  const extraction = await extract(userMessage, assistantMessage, routeEntity, routeReason)

  for (const mem of extraction.memories) {
    saveMemory(mem.content, mem.category, mem.importance, mem.domain || undefined)
  }

  if (extraction.memories.length > 0) {
    process.stderr.write(`[HYDRA-MaF] Extracted ${extraction.memories.length} memories\n`)
  }
}

main().catch(err => {
  process.stderr.write(`HYDRA memory extraction error: ${err.message}\n`)
})
