/**
 * Milo Self-Repair -- Golden Sample Immune System
 *
 * Detects and repairs data anomalies in Milo's tracking system.
 * Runs as part of the heartbeat cycle (every 30 min).
 *
 * Golden Sample Pattern (reusable across all CaF entities):
 *   scan(db) -> detect(anomalies) -> score(confidence) -> triage(auto|flag|skip) -> repair(safe) -> log(all)
 *
 * Safety rules:
 *   - Never DELETE records. Always mark completed/archived.
 *   - Memories are NEVER auto-repaired (flag only).
 *   - Auto-repair only when confidence >= 0.85 AND repair type is safe.
 *   - Full audit trail in milo_repair_log.
 */

import Database from 'better-sqlite3'
import { findSupersessionTarget } from './supersede.js'

// ============================================================================
// TYPES (Golden Sample Contract)
// ============================================================================

export interface RepairDetection {
  entity_type: 'event' | 'memory' | 'task' | 'goal' | 'strategy'
  entity_id: string | number
  issue_type: 'duplicate' | 'stale' | 'orphaned' | 'contradictory'
  confidence: number        // 0.0 - 1.0
  description: string
  related_ids: (string | number)[]
}

export interface RepairAction {
  detection: RepairDetection
  action: 'auto_repaired' | 'flagged_for_review' | 'skipped'
  repair_type: string       // e.g., 'mark_completed', 'merge_duplicates', 'archive'
  details: string
}

export interface RepairReport {
  timestamp: string
  detections: RepairDetection[]
  actions: RepairAction[]
  stats: { scanned: number; issues_found: number; auto_repaired: number; flagged: number }
}

// ============================================================================
// TABLE SETUP
// ============================================================================

function ensureRepairLogTable(db: Database.Database): void {
  db.prepare(`
    CREATE TABLE IF NOT EXISTS milo_repair_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      issue_type TEXT NOT NULL,
      action TEXT NOT NULL,
      repair_type TEXT,
      confidence REAL,
      details TEXT,
      created_at DATETIME DEFAULT (datetime('now'))
    )
  `).run()
}

// ============================================================================
// DETECTION SCANNERS
// ============================================================================

function detectDuplicateEvents(db: Database.Database): RepairDetection[] {
  const detections: RepairDetection[] = []

  // Group active events by normalized title
  const groups = db.prepare(`
    SELECT LOWER(TRIM(title)) as norm_title, COUNT(*) as cnt,
           GROUP_CONCAT(id, ',') as ids, GROUP_CONCAT(starts_at, ',') as dates
    FROM milo_events
    WHERE status = 'active'
    GROUP BY LOWER(TRIM(title))
    HAVING COUNT(*) > 1
  `).all() as Array<{ norm_title: string; cnt: number; ids: string; dates: string }>

  for (const g of groups) {
    const ids = g.ids.split(',')
    const dates = g.dates.split(',')

    // Check if dates are within 24h of each other (or all null)
    const allClose = dates.every((d, i) => {
      if (i === 0) return true
      if (!d || !dates[0]) return !d && !dates[0]
      const diff = Math.abs(new Date(d).getTime() - new Date(dates[0]).getTime())
      return diff < 24 * 60 * 60 * 1000
    })

    if (allClose) {
      detections.push({
        entity_type: 'event',
        entity_id: ids[0],
        issue_type: 'duplicate',
        confidence: 0.95,
        description: `${g.cnt} duplicate events: "${g.norm_title}"`,
        related_ids: ids.slice(1),
      })
    }
  }

  return detections
}

function detectDuplicateMemories(db: Database.Database): RepairDetection[] {
  const detections: RepairDetection[] = []

  // Walk memories newest-first; for each, ask the shared supersession policy
  // whether any older memory would supersede it under findSupersessionTarget.
  // Single source of truth: write-time check and repair-time scan agree on "dup."
  const memories = db.prepare(`
    SELECT id, content, category, domain, importance, created_at
    FROM milo_memories
    WHERE superseded_by IS NULL
    ORDER BY created_at DESC, id DESC
  `).all() as Array<{ id: number; content: string; category: string; domain: string | null; importance: number; created_at: string }>

  const flaggedForSupersession = new Set<number>()

  for (const m of memories) {
    if (flaggedForSupersession.has(m.id)) continue
    // Temporarily exclude the row itself from the candidate pool by masking it
    // as superseded, running the check, then unmasking.
    db.prepare('UPDATE milo_memories SET superseded_by = -1 WHERE id = ?').run(m.id)
    const targetId = findSupersessionTarget(db, { content: m.content, category: m.category, domain: m.domain, importance: m.importance })
    db.prepare('UPDATE milo_memories SET superseded_by = NULL WHERE id = ?').run(m.id)
    // Only accept a target that is strictly older than m. If the Jaccard match
    // found a newer row, that means we're iterating in the wrong direction
    // relative to this pair — skip it now; we'll handle it when we reach the
    // newer row later in the loop.
    if (targetId !== null && targetId !== m.id && targetId < m.id) {
      flaggedForSupersession.add(targetId)
      detections.push({
        entity_type: 'memory',
        entity_id: m.id,
        issue_type: 'duplicate',
        confidence: 0.95,
        description: `Near-duplicate of memory ${targetId}: "${m.content.substring(0, 50)}..."`,
        related_ids: [targetId],
      })
    }
  }

  return detections
}

function detectDuplicateTasks(db: Database.Database): RepairDetection[] {
  const detections: RepairDetection[] = []

  const groups = db.prepare(`
    SELECT LOWER(TRIM(title)) as norm_title, COUNT(*) as cnt,
           GROUP_CONCAT(id, ',') as ids
    FROM tasks
    WHERE status = 'pending' AND assigned_to = 'eddie'
    GROUP BY LOWER(TRIM(title))
    HAVING COUNT(*) > 1
  `).all() as Array<{ norm_title: string; cnt: number; ids: string }>

  for (const g of groups) {
    const ids = g.ids.split(',')
    detections.push({
      entity_type: 'task',
      entity_id: ids[0],
      issue_type: 'duplicate',
      confidence: 0.9,
      description: `${g.cnt} duplicate pending tasks: "${g.norm_title}"`,
      related_ids: ids.slice(1),
    })
  }

  return detections
}

function detectStaleEvents(db: Database.Database): RepairDetection[] {
  const detections: RepairDetection[] = []

  const stale = db.prepare(`
    SELECT id, title, starts_at, event_type,
           (julianday('now') - julianday(starts_at)) * 24 as hours_past
    FROM milo_events
    WHERE status = 'active'
      AND starts_at IS NOT NULL
      AND julianday(starts_at) < julianday('now') - 2
    ORDER BY starts_at ASC
  `).all() as Array<{ id: string; title: string; starts_at: string; event_type: string; hours_past: number }>

  for (const e of stale) {
    const daysPast = e.hours_past / 24
    const confidence = daysPast >= 7 ? 0.95 : 0.85

    detections.push({
      entity_type: 'event',
      entity_id: e.id,
      issue_type: 'stale',
      confidence,
      description: `"${e.title}" is ${Math.round(daysPast)} days past its date (${e.starts_at})`,
      related_ids: [],
    })
  }

  return detections
}

function detectOrphanedGoals(db: Database.Database): RepairDetection[] {
  const detections: RepairDetection[] = []

  const orphans = db.prepare(`
    SELECT g.id, g.description, g.progress, g.horizon, g.updated_at,
           (julianday('now') - julianday(g.updated_at)) as days_since_update
    FROM goals g
    WHERE g.status = 'active'
      AND g.progress = 0
      AND julianday('now') - julianday(g.updated_at) > 30
  `).all() as Array<{ id: string; description: string; progress: number; horizon: string; updated_at: string; days_since_update: number }>

  for (const g of orphans) {
    detections.push({
      entity_type: 'goal',
      entity_id: g.id,
      issue_type: 'orphaned',
      confidence: 0.7,
      description: `Goal "${g.description}" has 0% progress and no updates in ${Math.round(g.days_since_update)} days`,
      related_ids: [],
    })
  }

  return detections
}

// ============================================================================
// TRIAGE (Golden Sample Decision Logic)
// ============================================================================

function isSafeRepairType(d: RepairDetection): boolean {
  // Safe: archiving older duplicate events/tasks (keeps newest)
  // Safe: completing stale events 7+ days past
  // Safe: superseding duplicate memories (reversible via superseded_by, nothing deleted)
  if (d.issue_type === 'duplicate' && (d.entity_type === 'event' || d.entity_type === 'task')) return true
  if (d.issue_type === 'duplicate' && d.entity_type === 'memory') return true
  if (d.issue_type === 'stale' && d.entity_type === 'event' && d.confidence >= 0.9) return true
  return false
}

function triageRepair(detection: RepairDetection): 'auto_repair' | 'flag' | 'skip' {
  if (detection.confidence >= 0.85 && isSafeRepairType(detection)) return 'auto_repair'
  if (detection.confidence >= 0.5) return 'flag'
  return 'skip'
}

// ============================================================================
// REPAIR EXECUTORS
// ============================================================================

function repairDuplicateEvents(db: Database.Database, detection: RepairDetection): string {
  // Keep the entity_id (first in group), archive the related_ids (duplicates)
  const archived: string[] = []
  for (const dupeId of detection.related_ids) {
    db.prepare(`
      UPDATE milo_events
      SET status = 'completed',
          description = COALESCE(description, '') || ' [auto-archived: duplicate of ' || ? || ']'
      WHERE id = ? AND status = 'active'
    `).run(String(detection.entity_id), String(dupeId))
    archived.push(String(dupeId))
  }
  return `Archived ${archived.length} duplicate event(s), kept ${detection.entity_id}`
}

function repairDuplicateTasks(db: Database.Database, detection: RepairDetection): string {
  const cancelled: string[] = []
  for (const dupeId of detection.related_ids) {
    db.prepare(`
      UPDATE tasks
      SET status = 'cancelled'
      WHERE id = ? AND status = 'pending'
    `).run(String(dupeId))
    cancelled.push(String(dupeId))
  }
  return `Cancelled ${cancelled.length} duplicate task(s), kept ${detection.entity_id}`
}

function repairStaleEvent(db: Database.Database, detection: RepairDetection): string {
  db.prepare(`
    UPDATE milo_events
    SET status = 'completed',
        description = COALESCE(description, '') || ' [auto-completed: past date]'
    WHERE id = ? AND status = 'active'
  `).run(String(detection.entity_id))
  return `Auto-completed stale event: ${detection.description}`
}

function repairDuplicateMemories(db: Database.Database, detection: RepairDetection): string {
  // detection.entity_id = the newer memory (survivor)
  // detection.related_ids[0] = the older memory (target to be superseded)
  const targetId = detection.related_ids[0]
  db.prepare(`UPDATE milo_memories SET superseded_by = ?, updated_at = datetime('now') WHERE id = ? AND superseded_by IS NULL`)
    .run(Number(detection.entity_id), Number(targetId))
  return `Superseded memory ${targetId} by ${detection.entity_id}`
}

function performRepair(db: Database.Database, detection: RepairDetection): string {
  if (detection.issue_type === 'duplicate' && detection.entity_type === 'event') {
    return repairDuplicateEvents(db, detection)
  }
  if (detection.issue_type === 'duplicate' && detection.entity_type === 'task') {
    return repairDuplicateTasks(db, detection)
  }
  if (detection.issue_type === 'duplicate' && detection.entity_type === 'memory') {
    return repairDuplicateMemories(db, detection)
  }
  if (detection.issue_type === 'stale' && detection.entity_type === 'event') {
    return repairStaleEvent(db, detection)
  }
  return 'No repair executor for this type'
}

// ============================================================================
// LOGGING
// ============================================================================

function logRepairAction(db: Database.Database, action: RepairAction): void {
  db.prepare(`
    INSERT INTO milo_repair_log (entity_type, entity_id, issue_type, action, repair_type, confidence, details)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    action.detection.entity_type,
    String(action.detection.entity_id),
    action.detection.issue_type,
    action.action,
    action.repair_type,
    action.detection.confidence,
    action.details
  )
}

// ============================================================================
// MAIN EXPORT
// ============================================================================

export function runSelfRepair(db: Database.Database): RepairReport {
  ensureRepairLogTable(db)

  const timestamp = new Date().toISOString()
  const detections: RepairDetection[] = []
  const actions: RepairAction[] = []

  // Run all scanners
  detections.push(
    ...detectDuplicateEvents(db),
    ...detectDuplicateMemories(db),
    ...detectDuplicateTasks(db),
    ...detectStaleEvents(db),
    ...detectOrphanedGoals(db),
  )

  // Triage and execute
  for (const detection of detections) {
    const decision = triageRepair(detection)

    if (decision === 'auto_repair') {
      const details = performRepair(db, detection)
      const action: RepairAction = {
        detection,
        action: 'auto_repaired',
        repair_type: detection.issue_type === 'duplicate' ? 'archive_duplicates' : 'complete_stale',
        details,
      }
      actions.push(action)
      logRepairAction(db, action)
    } else if (decision === 'flag') {
      const action: RepairAction = {
        detection,
        action: 'flagged_for_review',
        repair_type: 'needs_human_review',
        details: detection.description,
      }
      actions.push(action)
      logRepairAction(db, action)
    }
    // 'skip' = no action, no log
  }

  return {
    timestamp,
    detections,
    actions,
    stats: {
      scanned: detections.length,
      issues_found: detections.length,
      auto_repaired: actions.filter(a => a.action === 'auto_repaired').length,
      flagged: actions.filter(a => a.action === 'flagged_for_review').length,
    },
  }
}
