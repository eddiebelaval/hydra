/**
 * HYDRA Context Builder
 *
 * Loads operational context for HYDRA's direct message handling:
 * recent routing history, memories, conversation turns, system state.
 *
 * Pattern adapted from milo-respond/src/context.ts but scoped to
 * coordinator concerns: routing quality, entity performance, system health.
 */

import Database from 'better-sqlite3'
import { loadMemoriesForContext, getRecentTurns, getRoutingStats } from './hydra-memory-db.js'
import { getRoutingHistory } from './routing-session.js'
import type { HydraMemory } from './hydra-memory-db.js'
import type { RoutingSession } from './types.js'

export interface HydraContextWindow {
  memories: HydraMemory[]
  recentTurns: Array<{ role: string; content: string; created_at: string }>
  routingHistory: RoutingSession[]
  routingStats: { total: number; byEntity: Record<string, number>; byStage: Record<string, number> }
}

/**
 * Load HYDRA's operational context.
 */
export function loadHydraContext(sessionId: string): HydraContextWindow {
  const memories = loadMemoriesForContext(10)
  const recentTurns = getRecentTurns(sessionId, 10)
  const routingHistory = getRoutingHistory(sessionId, 5)
  const routingStats = getRoutingStats()

  return { memories, recentTurns, routingHistory, routingStats }
}

/**
 * Format context into system prompt sections.
 */
export function formatHydraContextForPrompt(ctx: HydraContextWindow): string {
  const sections: string[] = []

  // Routing stats
  if (ctx.routingStats.total > 0) {
    const entityBreakdown = Object.entries(ctx.routingStats.byEntity)
      .map(([e, c]) => `${e}: ${c}`)
      .join(', ')
    sections.push(`## Routing Stats\nTotal routes: ${ctx.routingStats.total}. By entity: ${entityBreakdown}`)
  }

  // Recent routing history for this session
  if (ctx.routingHistory.length > 0) {
    sections.push(`## Recent Routing (this session)\n${ctx.routingHistory.map(r =>
      `- ${r.active_entity} (${r.message_count} msgs, reason: ${r.reason})`
    ).join('\n')}`)
  }

  // Memories
  if (ctx.memories.length > 0) {
    sections.push(`## Operational Memory\n${ctx.memories.map(m => {
      const tag = m.domain ? `${m.category}:${m.domain}` : m.category
      return `- [${tag}] ${m.content}`
    }).join('\n')}`)
  }

  // Earlier conversation turns (HYDRA-handled only)
  if (ctx.recentTurns.length > 0) {
    sections.push(`## Earlier in This Session\n${ctx.recentTurns.map(t =>
      `${t.role}: ${t.content.substring(0, 200)}`
    ).join('\n')}`)
  }

  return sections.join('\n\n')
}

/**
 * Get the last N user messages from Milo's conversation table.
 * Used by the classifier to provide conversational context to Haiku.
 */
export function getRecentUserMessages(limit = 3): string[] {
  try {
    const db = new Database(
      process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`,
      { readonly: true }
    )
    const rows = db.prepare(`
      SELECT content FROM milo_conversations
      WHERE role = 'user'
      ORDER BY id DESC LIMIT ?
    `).all(limit) as Array<{ content: string }>
    db.close()
    rows.reverse()
    return rows.map(r => r.content)
  } catch {
    return []
  }
}
