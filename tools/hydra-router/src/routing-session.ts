/**
 * Routing Session Management
 *
 * Manages sticky sessions in hydra.db. Tracks which entity is handling
 * the current conversation and when it was last routed.
 *
 * Sticky logic:
 *   - If session exists and < STICKY_TIMEOUT idle, reuse entity
 *   - If 10+ messages without reroute, skip classification entirely
 *   - Explicit reroute commands always override stickiness
 */

import Database from 'better-sqlite3'
import type { EntityId, RoutingSession } from './types.js'

const HYDRA_DB = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const STICKY_TIMEOUT = parseInt(process.env.HYDRA_STICKY_TIMEOUT || '900') // 15 minutes

let _db: Database.Database | null = null

function getDb(): Database.Database {
  if (!_db) {
    _db = new Database(HYDRA_DB)
    _db.pragma('journal_mode = WAL')
    ensureTable(_db)
  }
  return _db
}

function ensureTable(db: Database.Database): void {
  const migration = `
    CREATE TABLE IF NOT EXISTS routing_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      active_entity TEXT NOT NULL DEFAULT 'milo',
      routed_at TEXT DEFAULT (datetime('now')),
      reason TEXT,
      confidence REAL,
      message_count INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now'))
    );
  `
  db.prepare(migration).run()

  // Create index if not exists (separate statement)
  try {
    db.prepare(
      'CREATE INDEX IF NOT EXISTS idx_routing_session ON routing_sessions(session_id)'
    ).run()
  } catch {
    // Index may already exist
  }
}

/**
 * Load the current routing session for a conversation.
 * Returns null if no session exists or if it's expired.
 */
export function loadRoutingSession(sessionId: string): RoutingSession | null {
  const db = getDb()
  const row = db.prepare(`
    SELECT * FROM routing_sessions
    WHERE session_id = ?
    ORDER BY id DESC LIMIT 1
  `).get(sessionId) as RoutingSession | undefined

  if (!row) return null

  // Check timeout
  const routedAt = new Date(row.routed_at + 'Z').getTime()
  const now = Date.now()
  const idleSeconds = (now - routedAt) / 1000

  if (idleSeconds > STICKY_TIMEOUT) {
    return null // Session expired
  }

  return row
}

/**
 * Check if the session is deeply sticky (10+ messages, skip classification).
 */
export function isDeeplySticky(session: RoutingSession | null): boolean {
  return session !== null && session.message_count >= 10
}

/**
 * Update or create a routing session after classification.
 */
export function updateRoutingSession(
  sessionId: string,
  entity: EntityId,
  reason: string,
  confidence: number
): void {
  const db = getDb()
  const existing = db.prepare(`
    SELECT id, active_entity, message_count FROM routing_sessions
    WHERE session_id = ?
    ORDER BY id DESC LIMIT 1
  `).get(sessionId) as { id: number; active_entity: string; message_count: number } | undefined

  if (existing && existing.active_entity === entity) {
    // Same entity, increment message count and refresh timestamp
    db.prepare(`
      UPDATE routing_sessions
      SET message_count = message_count + 1,
          routed_at = datetime('now'),
          reason = ?,
          confidence = ?
      WHERE id = ?
    `).run(reason, confidence, existing.id)
  } else {
    // New entity or new session, create fresh row
    db.prepare(`
      INSERT INTO routing_sessions (session_id, active_entity, reason, confidence, message_count)
      VALUES (?, ?, ?, ?, 1)
    `).run(sessionId, entity, reason, confidence)
  }
}

/**
 * Force-set the active entity (explicit reroute command).
 */
export function forceRoute(sessionId: string, entity: EntityId): void {
  updateRoutingSession(sessionId, entity, 'explicit_reroute', 1.0)
}

/**
 * Get routing history for diagnostics.
 */
export function getRoutingHistory(sessionId: string, limit = 10): RoutingSession[] {
  const db = getDb()
  return db.prepare(`
    SELECT * FROM routing_sessions
    WHERE session_id = ?
    ORDER BY id DESC LIMIT ?
  `).all(sessionId, limit) as RoutingSession[]
}
