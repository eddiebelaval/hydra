/**
 * Context Builder
 *
 * Loads everything Milo needs to know from hydra.db:
 * recent conversation, summaries, goals, strategies, events, memories, mood.
 * Returns a structured ContextWindow that gets composed into the system prompt.
 */

import Database from 'better-sqlite3'
import type { ContextWindow, ConversationTurn, ConversationSummary, Goal, Strategy, MiloEvent, Memory, MoodEntry } from './types.js'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`

function getDb(): Database.Database {
  return new Database(DB_PATH, { readonly: true })
}

export function loadContext(sessionId: string, rollingWindow: number = 40, summaryCount: number = 5, memoryLimit: number = 20): ContextWindow {
  const db = getDb()
  try {
    const recentTurns = db.prepare(`
      SELECT id, role, content, tool_name, tool_input, token_count, session_id, telegram_message_id, created_at
      FROM milo_conversations
      ORDER BY id DESC LIMIT ?
    `).all(rollingWindow) as ConversationTurn[]
    recentTurns.reverse()

    const summaries = db.prepare(`
      SELECT id, summary, turn_range_start, turn_range_end, turn_count, key_topics, key_decisions, emotional_tone, created_at
      FROM milo_conversation_summaries
      ORDER BY created_at DESC LIMIT ?
    `).all(summaryCount) as ConversationSummary[]
    summaries.reverse()

    const goals = db.prepare(`
      SELECT id, horizon, period, description, status, progress, category, notes, target_date
      FROM goals WHERE status = 'active'
      ORDER BY horizon, period
    `).all() as Goal[]

    const strategies = db.prepare(`
      SELECT id, title, description, goal_id, status, key_assumptions, evidence, created_at
      FROM milo_strategies WHERE status = 'active'
      ORDER BY created_at DESC
    `).all() as Strategy[]

    const events = db.prepare(`
      SELECT id, title, description, event_type, starts_at, ends_at, all_day, status, goal_id
      FROM milo_events
      WHERE status = 'active'
        AND (starts_at IS NULL OR starts_at <= datetime('now', '+7 days'))
      ORDER BY starts_at ASC
    `).all() as MiloEvent[]

    // Smart memory loading: prioritize behavioral calibration, then recency, then importance
    const priorityMemories = db.prepare(`
      SELECT id, content, category, importance, created_at
      FROM milo_memories
      WHERE superseded_by IS NULL AND category IN ('feedback', 'preference', 'relationship')
      ORDER BY importance DESC, created_at DESC
      LIMIT 8
    `).all() as Memory[]

    const priorityIds = new Set(priorityMemories.map(m => m.id))
    const remainingLimit = Math.max(0, memoryLimit - priorityMemories.length)

    const recentMemories = db.prepare(`
      SELECT id, content, category, importance, created_at
      FROM milo_memories
      WHERE superseded_by IS NULL AND id NOT IN (${[...priorityIds].map(() => '?').join(',') || '-1'})
      ORDER BY created_at DESC
      LIMIT 4
    `).all(...priorityIds) as Memory[]

    const recentIds = new Set(recentMemories.map(m => m.id))
    const allLoadedIds = new Set([...priorityIds, ...recentIds])
    const importanceLimit = Math.max(0, remainingLimit - recentMemories.length)

    const importanceMemories = db.prepare(`
      SELECT id, content, category, importance, created_at
      FROM milo_memories
      WHERE superseded_by IS NULL AND id NOT IN (${[...allLoadedIds].map(() => '?').join(',') || '-1'})
      ORDER BY importance DESC, created_at DESC
      LIMIT ?
    `).all(...allLoadedIds, importanceLimit) as Memory[]

    const memories = [...priorityMemories, ...recentMemories, ...importanceMemories]

    const moods = db.prepare(`
      SELECT mood, energy_level, context, created_at
      FROM milo_mood_journal
      ORDER BY created_at DESC LIMIT 7
    `).all() as MoodEntry[]
    moods.reverse()

    const priorities = db.prepare(`
      SELECT priority_number, description, status
      FROM daily_priorities
      WHERE date = date('now')
      ORDER BY priority_number
    `).all() as Array<{ priority_number: number; description: string; status: string }>

    return { recentTurns, summaries, goals, strategies, events, memories, moods, priorities }
  } finally {
    db.close()
  }
}

export function formatContextForPrompt(ctx: ContextWindow): string {
  const sections: string[] = []

  if (ctx.goals.length > 0) {
    sections.push(`## Active Goals\n${ctx.goals.map(g =>
      `- [${g.progress}%] ${g.description} (${g.horizon}/${g.period} - ${g.category})`
    ).join('\n')}`)
  }

  if (ctx.strategies.length > 0) {
    sections.push(`## Active Strategies\n${ctx.strategies.map(s =>
      `- ${s.title}: ${s.description}`
    ).join('\n')}`)
  }

  if (ctx.events.length > 0) {
    sections.push(`## Upcoming Events & Reminders\n${ctx.events.map(e =>
      `- [${e.event_type}] ${e.starts_at || 'no date'}: ${e.title}${e.description ? ' - ' + e.description : ''}`
    ).join('\n')}`)
  }

  if (ctx.priorities.length > 0) {
    sections.push(`## Today's Priorities\n${ctx.priorities.map(p =>
      `${p.priority_number}. ${p.description} [${p.status}]`
    ).join('\n')}`)
  }

  if (ctx.memories.length > 0) {
    sections.push(`## What You Know About Eddie\n${ctx.memories.map(m => {
      const tag = (m as unknown as { domain?: string }).domain
        ? `${m.category}:${(m as unknown as { domain: string }).domain}`
        : m.category
      return `- [${tag}] ${m.content}`
    }).join('\n')}`)
  }

  if (ctx.moods.length > 0) {
    const recent = ctx.moods[ctx.moods.length - 1]
    const trend = ctx.moods.map(m => m.mood).join(' -> ')
    sections.push(`## Eddie's Recent Mood\nTrend: ${trend}\nLatest: ${recent.mood} (energy: ${recent.energy_level || 'unknown'})${recent.context ? ' - ' + recent.context : ''}`)
  }

  if (ctx.summaries.length > 0) {
    sections.push(`## Earlier Conversation Context\n${ctx.summaries.map(s => s.summary).join('\n\n')}`)
  }

  return sections.join('\n\n')
}

export function saveTurn(role: string, content: string, sessionId: string, telegramMessageId?: number, toolName?: string, toolInput?: string): void {
  const db = new Database(DB_PATH, { readonly: false })
  try {
    db.prepare(`
      INSERT INTO milo_conversations (role, content, session_id, telegram_message_id, tool_name, tool_input, token_count)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(role, content, sessionId, telegramMessageId || null, toolName || null, toolInput || null, Math.ceil(content.length / 4))
  } finally {
    db.close()
  }
}

export function getUnsummarizedCount(): number {
  const db = getDb()
  try {
    const result = db.prepare(`
      SELECT COUNT(*) as count FROM milo_conversations
      WHERE id NOT IN (
        SELECT mc.id FROM milo_conversations mc
        JOIN milo_conversation_summaries mcs
        ON mc.id BETWEEN mcs.turn_range_start AND mcs.turn_range_end
      )
      AND id < (SELECT COALESCE(MAX(id) - 40, 0) FROM milo_conversations)
    `).get() as { count: number }
    return result.count
  } finally {
    db.close()
  }
}
