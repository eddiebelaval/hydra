#!/usr/bin/env tsx
/**
 * HYDRA Self-Enrichment Script
 *
 * Analyzes Milo's conversation history, memories, and system state
 * to bootstrap HYDRA's operational memory. HYDRA enriches herself
 * from data she already has access to.
 *
 * Run once to seed, then periodically to discover new patterns.
 * Usage: npx tsx src/seed-memories.ts
 */

import Database from 'better-sqlite3'
import { saveMemory, listMemories } from './hydra-memory-db.js'
import type { HydraMemoryCategory } from './hydra-memory-db.js'

const HYDRA_DB = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const db = new Database(HYDRA_DB, { readonly: true })

interface SeedMemory {
  content: string
  category: HydraMemoryCategory
  importance: number
  domain?: string
}

const seeds: SeedMemory[] = []

function seed(content: string, category: HydraMemoryCategory, importance: number, domain?: string) {
  seeds.push({ content, category, importance, domain })
}

// ═══════════════════════════════════════════════════
// 1. TIME-OF-DAY ROUTING PATTERNS
// ═══════════════════════════════════════════════════

function analyzeTimePatterns() {
  const rows = db.prepare(`
    SELECT
      CAST(strftime('%H', created_at) AS INTEGER) as hour,
      content
    FROM milo_conversations
    WHERE role = 'user' AND length(content) > 20
    ORDER BY created_at
  `).all() as Array<{ hour: number; content: string }>

  const morning = rows.filter(r => r.hour >= 5 && r.hour < 12)
  const afternoon = rows.filter(r => r.hour >= 12 && r.hour < 17)
  const evening = rows.filter(r => r.hour >= 17 || r.hour < 5)

  if (morning.length > 0) {
    seed(
      `Eddie sends ${morning.length} morning messages (5am-12pm). Morning messages tend toward status checks, updates, and planning. Default to Milo for morning routing.`,
      'routing_pattern', 7, 'milo'
    )
  }

  if (evening.length > 0) {
    seed(
      `Eddie sends ${evening.length} evening/late-night messages. Late sessions often involve deep technical work, system setup, or reflection. May shift between Milo (reflection) and HYDRA (system ops).`,
      'routing_pattern', 6
    )
  }

  // Check for early morning pattern
  const earlyBird = rows.filter(r => r.hour >= 4 && r.hour < 7)
  if (earlyBird.length >= 3) {
    seed(
      `Eddie sometimes works between 4-7 AM (${earlyBird.length} early morning messages). These tend to be deep technical sessions. Route to current entity or Milo.`,
      'routing_pattern', 5
    )
  }
}

// ═══════════════════════════════════════════════════
// 2. ENTITY DOMAIN INSIGHTS FROM MILO'S MEMORIES
// ═══════════════════════════════════════════════════

function analyzeEntityDomains() {
  // What domains does Eddie talk about most?
  const domains = db.prepare(`
    SELECT domain, COUNT(*) as c FROM milo_memories
    WHERE domain IS NOT NULL AND superseded_by IS NULL
    GROUP BY domain ORDER BY c DESC LIMIT 10
  `).all() as Array<{ domain: string; c: number }>

  for (const d of domains) {
    if (d.domain === 'homer') {
      seed(
        `Homer is Eddie's most-discussed project (${d.c} memories). Homer discussions involve both strategy (Axis territory) and personal tracking (Milo territory). Route based on intent: pricing/GTM/legal -> Axis, progress/events/goals -> Milo.`,
        'entity_insight', 8, 'homer'
      )
    } else if (d.domain === 'cpn') {
      seed(
        `CPN (Claude Partner Network) is a high-activity topic (${d.c} memories). Cohort grew from 4 to 47 rapidly. CPN discussions mix community management (Milo) with strategy (Axis).`,
        'entity_insight', 7, 'cpn'
      )
    } else if (d.domain === 'parallax') {
      seed(
        `Parallax is in maintenance mode but still referenced (${d.c} memories). Parallax has Ava as its entity. Design questions about Parallax -> Iris. Status -> Milo.`,
        'entity_insight', 6, 'parallax'
      )
    } else if (d.domain === 'milo') {
      seed(
        `Milo is both the personal companion entity and a project Eddie is building (${d.c} memories). When Eddie says "Milo" he might mean the entity or the product. Context determines which.`,
        'entity_insight', 7, 'milo'
      )
    }
  }
}

// ═══════════════════════════════════════════════════
// 3. CONVERSATION PATTERN ANALYSIS
// ═══════════════════════════════════════════════════

function analyzeConversationPatterns() {
  // Average message length (indicates depth of engagement)
  const stats = db.prepare(`
    SELECT
      AVG(length(content)) as avg_len,
      MAX(length(content)) as max_len,
      COUNT(*) as total
    FROM milo_conversations WHERE role = 'user'
  `).get() as { avg_len: number; max_len: number; total: number }

  seed(
    `Eddie's average message length is ${Math.round(stats.avg_len)} characters across ${stats.total} messages. Longest was ${stats.max_len} chars. Short messages (<50 chars) are usually quick checks; long messages (>200 chars) are deep updates or context dumps.`,
    'routing_pattern', 5
  )

  // Check for correction patterns (Eddie fixing Milo)
  const corrections = db.prepare(`
    SELECT content FROM milo_conversations
    WHERE role = 'user' AND (
      content LIKE '%wrong%' OR content LIKE '%no,%' OR content LIKE '%not what%'
      OR content LIKE '%i told you%' OR content LIKE '%something is wrong%'
      OR content LIKE '%wtf%' OR content LIKE '%confusion%'
    )
    ORDER BY created_at DESC LIMIT 5
  `).all() as Array<{ content: string }>

  if (corrections.length > 0) {
    seed(
      `Eddie has corrected Milo ${corrections.length} times in recent history. When Eddie says "something is wrong" or "I told you," it means context was lost or a memory failed. These frustration signals mean the system needs attention, not rerouting.`,
      'observation', 7, 'milo'
    )
  }
}

// ═══════════════════════════════════════════════════
// 4. SYSTEM STATE FACTS
// ═══════════════════════════════════════════════════

function analyzeSystemState() {
  const memCount = (db.prepare('SELECT COUNT(*) as c FROM milo_memories WHERE superseded_by IS NULL').get() as { c: number }).c
  const convCount = (db.prepare('SELECT COUNT(*) as c FROM milo_conversations').get() as { c: number }).c
  const goalCount = (db.prepare('SELECT COUNT(*) as c FROM goals WHERE status = \'active\'').get() as { c: number }).c
  const eventCount = (db.prepare('SELECT COUNT(*) as c FROM milo_events WHERE status = \'active\'').get() as { c: number }).c

  seed(
    `System state at enrichment: ${memCount} active Milo memories, ${convCount} conversation turns, ${goalCount} active goals, ${eventCount} active events. This is a mature system with substantial history.`,
    'fact', 5, 'hydra'
  )

  seed(
    `Milo handles goals, events, todos, strategies, and memories via 16 tools. HYDRA handles system ops via 9 tools (6 system + 3 memory). No overlap. Milo never sees HYDRA's tools and vice versa.`,
    'fact', 6
  )

  // Category distribution for routing intelligence
  const categories = db.prepare(`
    SELECT category, COUNT(*) as c FROM milo_memories
    WHERE superseded_by IS NULL
    GROUP BY category ORDER BY c DESC LIMIT 5
  `).all() as Array<{ category: string; c: number }>

  const topCats = categories.map(c => `${c.category}(${c.c})`).join(', ')
  seed(
    `Milo's memory distribution: ${topCats}. Heavy on project and milestone memories, which means Eddie reports achievements and project updates frequently. These are Milo territory.`,
    'entity_insight', 6, 'milo'
  )
}

// ═══════════════════════════════════════════════════
// 5. RELATIONSHIP + PEOPLE ROUTING
// ═══════════════════════════════════════════════════

function analyzeRelationships() {
  const people = db.prepare(`
    SELECT content, domain FROM milo_memories
    WHERE category = 'relationship' AND superseded_by IS NULL
    ORDER BY importance DESC
  `).all() as Array<{ content: string; domain: string }>

  if (people.length > 0) {
    seed(
      `Eddie mentions ${people.length} key people in Milo's memories. People-related messages (about Jose, Gus, Alicia, Orion) should stay with Milo unless the topic is explicitly about business strategy.`,
      'routing_preference', 7, 'milo'
    )
  }

  // Check for Jose/Profesa mentions (high-activity relationship)
  const joseMentions = db.prepare(`
    SELECT COUNT(*) as c FROM milo_conversations
    WHERE role = 'user' AND (content LIKE '%jose%' OR content LIKE '%profesa%')
  `).get() as { c: number }

  if (joseMentions.c > 0) {
    seed(
      `Jose (Profesa) is a frequent topic (${joseMentions.c} message mentions). Jose discussions span personal relationship (Milo), workshop strategy (Axis), and technical collaboration. Default to Milo unless explicitly strategic.`,
      'routing_preference', 7, 'milo'
    )
  }
}

// ═══════════════════════════════════════════════════
// 6. ENTITY AVAILABILITY + STUBS
// ═══════════════════════════════════════════════════

function seedEntityFacts() {
  seed(
    'Milo is the only fully operational entity on Telegram. Axis and Iris are stubs that fall back to Milo with a notice. When Eddie routes to Axis or Iris, acknowledge the stub and explain.',
    'fact', 9
  )

  seed(
    'Eddie prefers transparency about routing. Always announce handoffs. He chose "announce handoffs" over silent routing on Apr 9 2026.',
    'entity_preference', 9
  )

  seed(
    'Milo is the default entity. When routing confidence is low or the topic is ambiguous, route to Milo. He has the broadest scope and deepest relationship.',
    'routing_preference', 9, 'milo'
  )

  seed(
    'Eddie corrected Milo about context loss on Apr 9 ("wtf! i told you about my meeting"). Memory failures are the most frustrating issue. If HYDRA detects pattern repetition or missing context in Milo, flag it.',
    'feedback', 8, 'milo'
  )

  seed(
    'The MaF (Memory as Filesystem) architecture was built Apr 9 2026. HYDRA has 8 memory categories scoped to coordinator operations. Milo has 16 categories scoped to personal life. Separate tables, shared database.',
    'fact', 7, 'hydra'
  )
}

// ═══════════════════════════════════════════════════
// 7. NORTH STAR + PRIORITY ROUTING
// ═══════════════════════════════════════════════════

function seedPriorityContext() {
  seed(
    'Eddie\'s north star is cashflow positive. Revenue-related messages carry higher urgency. If Eddie mentions "first paying customer" or "revenue," the conversation matters more than routine check-ins.',
    'observation', 8
  )

  seed(
    'Homer brokerage meeting with Gus is the highest-leverage action (week of Apr 7). Homer-related messages during this period should be treated as high-priority regardless of entity routing.',
    'observation', 8, 'homer'
  )

  seed(
    'CPN cohort grew from 4 to 47 in under a week. Eddie manages it via WhatsApp and Telegram. CPN community management is Milo territory. CPN strategy (pricing, curriculum, growth) is Axis territory.',
    'routing_preference', 7, 'cpn'
  )
}

// ═══════════════════════════════════════════════════
// MAIN: Run all analyzers and save
// ═══════════════════════════════════════════════════

function main() {
  console.log('HYDRA Self-Enrichment: analyzing system data...\n')

  analyzeTimePatterns()
  analyzeEntityDomains()
  analyzeConversationPatterns()
  analyzeSystemState()
  analyzeRelationships()
  seedEntityFacts()
  seedPriorityContext()

  // Check existing memories to avoid duplicates
  const existing = listMemories(undefined, undefined, 100)
  const existingContent = new Set(existing.map(m => m.content.substring(0, 40)))

  let saved = 0
  let skipped = 0

  for (const s of seeds) {
    // Skip if similar content already exists
    if (existingContent.has(s.content.substring(0, 40))) {
      skipped++
      continue
    }

    saveMemory(s.content, s.category, s.importance, s.domain)
    saved++
    console.log(`  [${s.category}:${s.domain || '*'}] (${s.importance}) ${s.content.substring(0, 80)}...`)
  }

  console.log(`\nEnrichment complete: ${saved} memories saved, ${skipped} duplicates skipped.`)
  console.log(`Total HYDRA memories: ${existing.length + saved}`)
}

main()
