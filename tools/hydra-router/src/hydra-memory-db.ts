/**
 * HYDRA Memory Database Layer
 *
 * Manages hydra_memories and hydra_conversations tables in hydra.db.
 * Separate from Milo's tables (milo_memories, milo_conversations).
 * Auto-creates tables on first connection.
 *
 * Categories (8 coordinator-specific):
 *   routing_preference, routing_pattern, entity_insight, feedback,
 *   observation, fact, system_event, entity_preference
 */

import Database from 'better-sqlite3'
import type { EntityId } from './types.js'

const HYDRA_DB = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`

let _db: Database.Database | null = null

function getDb(readonly = false): Database.Database {
  if (!_db || _db.readonly !== readonly) {
    if (_db) _db.close()
    _db = new Database(HYDRA_DB, { readonly })
    _db.pragma('journal_mode = WAL')
    if (!readonly) ensureTables(_db)
  }
  return _db
}

function ensureTables(db: Database.Database): void {
  db.prepare(`
    CREATE TABLE IF NOT EXISTS hydra_memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'observation',
      importance INTEGER NOT NULL DEFAULT 5,
      domain TEXT,
      source_summary TEXT,
      times_accessed INTEGER DEFAULT 0,
      last_accessed TEXT,
      superseded_by INTEGER,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    )
  `).run()

  try {
    db.prepare('CREATE INDEX IF NOT EXISTS idx_hydra_mem_category ON hydra_memories(category)').run()
    db.prepare('CREATE INDEX IF NOT EXISTS idx_hydra_mem_importance ON hydra_memories(importance DESC)').run()
    db.prepare('CREATE INDEX IF NOT EXISTS idx_hydra_mem_domain ON hydra_memories(domain)').run()
  } catch { /* indexes may exist */ }

  db.prepare(`
    CREATE TABLE IF NOT EXISTS hydra_conversations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      tool_name TEXT,
      tool_input TEXT,
      token_count INTEGER,
      session_id TEXT,
      telegram_message_id INTEGER,
      created_at TEXT DEFAULT (datetime('now'))
    )
  `).run()

  try {
    db.prepare('CREATE INDEX IF NOT EXISTS idx_hydra_conv_session ON hydra_conversations(session_id)').run()
    db.prepare('CREATE INDEX IF NOT EXISTS idx_hydra_conv_created ON hydra_conversations(created_at)').run()
  } catch { /* indexes may exist */ }
}

// -- Memory CRUD --

export type HydraMemoryCategory =
  | 'routing_preference'
  | 'routing_pattern'
  | 'entity_insight'
  | 'feedback'
  | 'observation'
  | 'fact'
  | 'system_event'
  | 'entity_preference'

export interface HydraMemory {
  id: number
  content: string
  category: HydraMemoryCategory
  importance: number
  domain: string | null
  source_summary: string | null
  times_accessed: number
  superseded_by: number | null
  created_at: string
}

export function saveMemory(
  content: string,
  category: HydraMemoryCategory,
  importance: number = 5,
  domain?: string,
): number {
  const db = getDb()

  // Basic dedup: check first 40 chars
  const existing = db.prepare(
    'SELECT id FROM hydra_memories WHERE content LIKE ? AND superseded_by IS NULL'
  ).get(`%${content.substring(0, 40)}%`) as { id: number } | undefined

  if (existing) return existing.id

  const result = db.prepare(
    'INSERT INTO hydra_memories (content, category, importance, domain) VALUES (?, ?, ?, ?)'
  ).run(content, category, importance, domain || null)

  return Number(result.lastInsertRowid)
}

export function searchMemories(query: string, category?: string, domain?: string, limit = 10): HydraMemory[] {
  const db = getDb(true)
  let sql = 'SELECT * FROM hydra_memories WHERE superseded_by IS NULL'
  const params: unknown[] = []

  if (query) {
    sql += ' AND content LIKE ?'
    params.push(`%${query}%`)
  }
  if (category) {
    sql += ' AND category = ?'
    params.push(category)
  }
  if (domain) {
    sql += ' AND domain = ?'
    params.push(domain)
  }

  sql += ' ORDER BY importance DESC, created_at DESC LIMIT ?'
  params.push(limit)

  return db.prepare(sql).all(...params) as HydraMemory[]
}

export function listMemories(category?: string, domain?: string, limit = 10): HydraMemory[] {
  return searchMemories('', category, domain, limit)
}

export function supersedeMemory(oldId: number, newContent: string, category: HydraMemoryCategory, importance: number = 5): number {
  const db = getDb()
  const newId = saveMemory(newContent, category, importance)
  db.prepare('UPDATE hydra_memories SET superseded_by = ? WHERE id = ?').run(newId, oldId)
  return newId
}

// -- Conversation Persistence --

export function saveTurn(
  role: string,
  content: string,
  sessionId: string,
  telegramMessageId?: number,
  toolName?: string,
  toolInput?: string,
): void {
  const db = getDb()
  db.prepare(`
    INSERT INTO hydra_conversations (role, content, session_id, telegram_message_id, tool_name, tool_input, token_count)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(role, content, sessionId, telegramMessageId || null, toolName || null, toolInput || null, Math.ceil(content.length / 4))
}

export function getRecentTurns(sessionId: string, limit = 10): Array<{ role: string; content: string; created_at: string }> {
  const db = getDb(true)
  const rows = db.prepare(`
    SELECT role, content, created_at FROM hydra_conversations
    WHERE session_id = ?
    ORDER BY id DESC LIMIT ?
  `).all(sessionId, limit) as Array<{ role: string; content: string; created_at: string }>
  rows.reverse()
  return rows
}

// -- Smart Memory Loading (3-tier strategy) --

export function loadMemoriesForContext(limit = 10): HydraMemory[] {
  const db = getDb(true)

  // Tier 1: Priority (feedback + routing_preference) -- behavioral calibration
  const priority = db.prepare(`
    SELECT * FROM hydra_memories
    WHERE superseded_by IS NULL AND category IN ('feedback', 'routing_preference')
    ORDER BY importance DESC, created_at DESC
    LIMIT 4
  `).all() as HydraMemory[]

  const loadedIds = new Set(priority.map(m => m.id))
  const remainingSlots = Math.max(0, limit - priority.length)

  // Tier 2: Recent (newest 3 regardless of category) -- continuity
  const recentLimit = Math.min(3, remainingSlots)
  const recent = db.prepare(`
    SELECT * FROM hydra_memories
    WHERE superseded_by IS NULL AND id NOT IN (${[...loadedIds].map(() => '?').join(',') || '-1'})
    ORDER BY created_at DESC
    LIMIT ?
  `).all(...loadedIds, recentLimit) as HydraMemory[]

  for (const m of recent) loadedIds.add(m.id)
  const importanceSlots = Math.max(0, remainingSlots - recent.length)

  // Tier 3: Importance (remaining by score) -- depth
  const importance = db.prepare(`
    SELECT * FROM hydra_memories
    WHERE superseded_by IS NULL AND id NOT IN (${[...loadedIds].map(() => '?').join(',') || '-1'})
    ORDER BY importance DESC, created_at DESC
    LIMIT ?
  `).all(...loadedIds, importanceSlots) as HydraMemory[]

  // Touch accessed timestamps
  const allMemories = [...priority, ...recent, ...importance]
  const touchStmt = db.prepare('UPDATE hydra_memories SET times_accessed = times_accessed + 1, last_accessed = datetime(\'now\') WHERE id = ?')
  for (const m of allMemories) {
    try { touchStmt.run(m.id) } catch { /* readonly fallback */ }
  }

  return allMemories
}

// -- Routing Analytics --

export function getRoutingStats(): { total: number; byEntity: Record<string, number>; byStage: Record<string, number> } {
  const db = getDb(true)

  const total = (db.prepare('SELECT COUNT(*) as c FROM routing_sessions').get() as { c: number }).c

  const entityRows = db.prepare(`
    SELECT active_entity, COUNT(*) as c FROM routing_sessions GROUP BY active_entity
  `).all() as Array<{ active_entity: string; c: number }>

  const stageRows = db.prepare(`
    SELECT reason, COUNT(*) as c FROM routing_sessions
    WHERE reason IS NOT NULL
    GROUP BY CASE
      WHEN reason LIKE 'Sticky%' OR reason LIKE 'Deep%' THEN 'sticky'
      WHEN reason LIKE 'System%' OR reason LIKE 'Explicit%' THEN 'keyword'
      WHEN reason LIKE 'Fallback%' THEN 'fallback'
      ELSE 'llm'
    END
  `).all() as Array<{ reason: string; c: number }>

  const byEntity: Record<string, number> = {}
  for (const row of entityRows) byEntity[row.active_entity] = row.c

  const byStage: Record<string, number> = {}
  for (const row of stageRows) byStage[row.reason] = row.c

  return { total, byEntity, byStage }
}
