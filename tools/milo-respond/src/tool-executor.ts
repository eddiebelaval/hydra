/**
 * Tool Executor
 *
 * Executes Claude tool calls against hydra.db.
 * Each handler receives the tool input and returns a ToolResult.
 */

import Database from 'better-sqlite3'
import type { ToolResult } from './types.js'
import { findSupersessionTarget } from './supersede.js'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`

function getDb(): Database.Database {
  return new Database(DB_PATH, { readonly: false })
}

// -- Goal Handlers --

function listGoals(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    let sql = 'SELECT id, horizon, period, description, status, progress, category, notes, target_date FROM goals WHERE 1=1'
    const params: unknown[] = []

    if (input.horizon) { sql += ' AND horizon = ?'; params.push(input.horizon) }
    if (input.status) { sql += ' AND status = ?'; params.push(input.status) }
    else { sql += " AND status = 'active'" }

    sql += ' ORDER BY horizon, period'
    const rows = db.prepare(sql).all(...params)
    return { success: true, data: rows, message: `Found ${rows.length} goals` }
  } finally { db.close() }
}

function createGoal(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const id = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')
    db.prepare(`
      INSERT INTO goals (id, description, horizon, period, category, target_date)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(id, input.description, input.horizon, input.period, input.category || 'product', input.target_date || null)
    return { success: true, data: { id }, message: `Goal created: ${input.description}` }
  } finally { db.close() }
}

function updateGoal(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const sets: string[] = []
    const params: unknown[] = []

    if (input.progress !== undefined) { sets.push('progress = ?'); params.push(input.progress) }
    if (input.status) { sets.push('status = ?'); params.push(input.status) }
    if (input.notes) { sets.push('notes = ?'); params.push(input.notes) }

    if (sets.length === 0) return { success: false, data: null, message: 'Nothing to update' }

    params.push(input.goal_id)
    db.prepare(`UPDATE goals SET ${sets.join(', ')} WHERE id = ?`).run(...params)
    return { success: true, data: { id: input.goal_id }, message: 'Goal updated' }
  } finally { db.close() }
}

// -- Strategy Handlers --

function listStrategies(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    let sql = 'SELECT id, title, description, goal_id, status, key_assumptions, evidence, created_at FROM milo_strategies WHERE 1=1'
    const params: unknown[] = []

    if (input.goal_id) { sql += ' AND goal_id = ?'; params.push(input.goal_id) }
    if (input.status) { sql += ' AND status = ?'; params.push(input.status) }
    else { sql += " AND status = 'active'" }

    sql += ' ORDER BY created_at DESC'
    const rows = db.prepare(sql).all(...params)
    return { success: true, data: rows, message: `Found ${rows.length} strategies` }
  } finally { db.close() }
}

function createStrategy(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const id = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')
    db.prepare(`
      INSERT INTO milo_strategies (id, title, description, goal_id, key_assumptions)
      VALUES (?, ?, ?, ?, ?)
    `).run(
      id, input.title, input.description, input.goal_id || null,
      input.key_assumptions ? JSON.stringify(input.key_assumptions) : null
    )
    return { success: true, data: { id }, message: `Strategy recorded: ${input.title}` }
  } finally { db.close() }
}

function updateStrategy(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const sets: string[] = []
    const params: unknown[] = []

    if (input.status) { sets.push('status = ?'); params.push(input.status) }
    if (input.description) { sets.push('description = ?'); params.push(input.description) }
    if (input.evidence) { sets.push('evidence = ?'); params.push(JSON.stringify(input.evidence)) }

    if (sets.length === 0) return { success: false, data: null, message: 'Nothing to update' }

    params.push(input.strategy_id)
    db.prepare(`UPDATE milo_strategies SET ${sets.join(', ')} WHERE id = ?`).run(...params)
    return { success: true, data: { id: input.strategy_id }, message: 'Strategy updated' }
  } finally { db.close() }
}

// -- Event Handlers --

function listEvents(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const daysAhead = (input.days_ahead as number) || 7
    let sql = `SELECT id, title, description, event_type, starts_at, ends_at, all_day, status, goal_id
      FROM milo_events WHERE status = 'active'`
    const params: unknown[] = []

    if (input.event_type) { sql += ' AND event_type = ?'; params.push(input.event_type) }
    sql += ` AND (starts_at IS NULL OR starts_at <= datetime('now', '+${daysAhead} days'))`
    sql += ' ORDER BY starts_at ASC NULLS LAST'

    const rows = db.prepare(sql).all(...params)
    return { success: true, data: rows, message: `Found ${rows.length} events` }
  } finally { db.close() }
}

function createEvent(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    // Dedup: check for existing active event with same title + similar date
    const existing = db.prepare(`
      SELECT id, title, starts_at FROM milo_events
      WHERE status = 'active'
        AND LOWER(TRIM(title)) = LOWER(TRIM(?))
        AND (
          (starts_at IS NULL AND ? IS NULL)
          OR ABS(julianday(starts_at) - julianday(?)) < 1
        )
    `).get(input.title, input.starts_at || null, input.starts_at || null) as { id: string; title: string; starts_at: string } | undefined

    if (existing) {
      return { success: true, data: existing, message: `Event already exists: ${existing.title}` }
    }

    const id = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')
    db.prepare(`
      INSERT INTO milo_events (id, title, description, event_type, starts_at, ends_at, all_day, goal_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id, input.title, input.description || null, input.event_type,
      input.starts_at || null, input.ends_at || null,
      input.all_day ? 1 : 0, input.goal_id || null
    )
    return { success: true, data: { id }, message: `Event created: ${input.title}` }
  } finally { db.close() }
}

function completeEvent(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    db.prepare("UPDATE milo_events SET status = 'completed' WHERE id = ?").run(input.event_id)
    return { success: true, data: { id: input.event_id }, message: 'Event completed' }
  } finally { db.close() }
}

// -- Todo Handlers (lightweight, conversational) --

function addTodo(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    // Dedup: check for existing pending todo with same title
    const existing = db.prepare(`
      SELECT id, title FROM tasks
      WHERE LOWER(TRIM(title)) = LOWER(TRIM(?))
        AND status = 'pending' AND task_type = 'todo'
    `).get(input.title) as { id: string; title: string } | undefined

    if (existing) {
      return { success: true, data: existing, message: `Already tracking: ${existing.title}` }
    }

    const id = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')
    const horizon = input.horizon as string

    // Compute due_at based on horizon
    let dueAt: string | null = null
    const now = new Date()
    if (horizon === 'today') {
      dueAt = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59).toISOString()
    } else if (horizon === 'this_week') {
      const endOfWeek = new Date(now)
      endOfWeek.setDate(now.getDate() + (7 - now.getDay()))
      dueAt = endOfWeek.toISOString()
    } else if (horizon === 'this_month') {
      const endOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59)
      dueAt = endOfMonth.toISOString()
    }
    // 'someday' = no due_at

    // Priority based on horizon
    const priority = horizon === 'today' ? 2 : horizon === 'this_week' ? 3 : 4

    // TTL: today tasks expire in 24h, this_week in 168h, someday = no expiry
    const ttlHours = horizon === 'today' ? 24 : horizon === 'this_week' ? 168 : null
    db.prepare(`
      INSERT INTO tasks (id, title, description, priority, due_at, assigned_to, source, task_type, status, ttl_hours)
      VALUES (?, ?, ?, ?, ?, 'eddie', 'milo', 'todo', 'pending', ?)
    `).run(id, input.title, input.context || null, priority, dueAt, ttlHours)

    return { success: true, data: { id, horizon, due_at: dueAt }, message: `Got it. Tracking: ${input.title} (${horizon})` }
  } finally { db.close() }
}

function completeTodo(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    db.prepare("UPDATE tasks SET status = 'completed', completed_at = datetime('now') WHERE id = ?").run(input.task_id)
    return { success: true, data: { id: input.task_id }, message: 'Done. Checked off.' }
  } finally { db.close() }
}

function whatsOnMyPlate(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const horizon = (input.horizon as string) || 'all'
    const result: Record<string, unknown> = {}

    // Todos
    let todoSql = "SELECT id, title, priority, due_at, created_at, description FROM tasks WHERE assigned_to = 'eddie' AND status IN ('pending', 'in_progress') AND task_type = 'todo'"
    if (horizon === 'today') todoSql += " AND due_at <= datetime('now', '+1 day')"
    else if (horizon === 'this_week') todoSql += " AND (due_at IS NULL OR due_at <= datetime('now', '+7 days'))"
    else if (horizon === 'this_month') todoSql += " AND (due_at IS NULL OR due_at <= datetime('now', '+31 days'))"
    todoSql += ' ORDER BY priority ASC, due_at ASC'
    result.todos = db.prepare(todoSql).all()

    // Formal tasks
    let taskSql = "SELECT id, title, priority, due_at, status, created_at FROM tasks WHERE assigned_to = 'eddie' AND status IN ('pending', 'in_progress', 'blocked') AND (task_type != 'todo' OR task_type IS NULL)"
    taskSql += ' ORDER BY priority ASC, due_at ASC LIMIT 10'
    result.tasks = db.prepare(taskSql).all()

    // Active goals
    result.goals = db.prepare("SELECT id, description, progress, horizon, period, category FROM goals WHERE status = 'active' ORDER BY horizon, period").all()

    // Upcoming events (next 7 days)
    result.events = db.prepare("SELECT id, title, event_type, starts_at FROM milo_events WHERE status = 'active' AND (starts_at IS NULL OR starts_at <= datetime('now', '+7 days')) ORDER BY starts_at ASC").all()

    // Active strategies
    result.strategies = db.prepare("SELECT id, title, status FROM milo_strategies WHERE status = 'active'").all()

    const todoCount = (result.todos as unknown[]).length
    const taskCount = (result.tasks as unknown[]).length
    const goalCount = (result.goals as unknown[]).length
    const eventCount = (result.events as unknown[]).length

    return { success: true, data: result, message: `${todoCount} todos, ${taskCount} tasks, ${goalCount} goals, ${eventCount} events` }
  } finally { db.close() }
}

// -- Task Handlers --

function createTask(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const id = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')
    // TTL: tasks with due_at today get 24h TTL, others get no expiry by default
    const dueAt = input.due_at as string | null
    const isToday = dueAt && dueAt === new Date().toISOString().split('T')[0]
    const ttlHours = isToday ? 24 : null
    db.prepare(`
      INSERT INTO tasks (id, title, description, priority, due_at, assigned_to, source, status, ttl_hours)
      VALUES (?, ?, ?, ?, ?, 'eddie', 'milo', 'pending', ?)
    `).run(id, input.title, input.description || null, input.priority || 3, dueAt, ttlHours)
    return { success: true, data: { id }, message: `Task created: ${input.title}` }
  } finally { db.close() }
}

function listTasks(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    let sql = "SELECT id, title, status, priority, due_at, created_at FROM tasks WHERE assigned_to = 'eddie'"
    const params: unknown[] = []

    if (input.status) { sql += ' AND status = ?'; params.push(input.status) }
    else { sql += " AND status IN ('pending', 'in_progress')" }

    sql += ' ORDER BY priority ASC, created_at DESC'
    if (input.limit) { sql += ' LIMIT ?'; params.push(input.limit) }
    else { sql += ' LIMIT 20' }

    const rows = db.prepare(sql).all(...params)
    return { success: true, data: rows, message: `Found ${rows.length} tasks` }
  } finally { db.close() }
}

function updateTask(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const sets: string[] = []
    const params: unknown[] = []

    if (input.status) { sets.push('status = ?'); params.push(input.status) }
    if (input.priority !== undefined) { sets.push('priority = ?'); params.push(input.priority) }
    if (input.title) { sets.push('title = ?'); params.push(input.title) }

    if (sets.length === 0) return { success: false, data: null, message: 'Nothing to update' }

    params.push(input.task_id)
    db.prepare(`UPDATE tasks SET ${sets.join(', ')} WHERE id = ?`).run(...params)
    return { success: true, data: { id: input.task_id }, message: 'Task updated' }
  } finally { db.close() }
}

// -- Memory Handlers --

function saveMemory(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const content = input.content as string
    const category = input.category as string
    const domain = (input.domain as string) || null
    const importance = (input.importance as number) || 5

    // Find supersession target BEFORE inserting (so we don't match ourselves).
    const targetId = findSupersessionTarget(db, { content, category, domain, importance })
    const targetImportance = targetId !== null
      ? (db.prepare('SELECT importance FROM milo_memories WHERE id = ?').get(targetId) as { importance: number } | undefined)?.importance ?? importance
      : importance
    const finalImportance = Math.max(importance, targetImportance)

    const info = db.prepare(`
      INSERT INTO milo_memories (content, category, importance, domain)
      VALUES (?, ?, ?, ?)
    `).run(content, category, finalImportance, domain)
    const newId = info.lastInsertRowid as number

    if (targetId !== null) {
      db.prepare('UPDATE milo_memories SET superseded_by = ?, updated_at = datetime(\'now\') WHERE id = ?').run(newId, targetId)
      return { success: true, data: { id: newId, superseded: targetId }, message: `Memory saved; superseded ${targetId}` }
    }
    return { success: true, data: { id: newId }, message: `Memory saved: ${content}` }
  } finally { db.close() }
}

function searchMemory(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    let sql = 'SELECT id, content, category, domain, importance, created_at FROM milo_memories WHERE superseded_by IS NULL'
    const params: unknown[] = []

    if (input.query) { sql += ' AND content LIKE ?'; params.push(`%${input.query}%`) }
    if (input.category) { sql += ' AND category = ?'; params.push(input.category) }
    if (input.domain) { sql += ' AND domain = ?'; params.push(input.domain) }

    sql += ' ORDER BY importance DESC, created_at DESC LIMIT 20'
    const rows = db.prepare(sql).all(...params)

    // Bump access counts
    for (const row of rows as Array<{ id: number }>) {
      db.prepare('UPDATE milo_memories SET times_accessed = times_accessed + 1, last_accessed = datetime(\'now\') WHERE id = ?').run(row.id)
    }

    return { success: true, data: rows, message: `Found ${rows.length} memories` }
  } finally { db.close() }
}

function listMemories(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    let sql = 'SELECT id, content, category, domain, importance, created_at FROM milo_memories WHERE superseded_by IS NULL'
    const params: unknown[] = []

    if (input.category) { sql += ' AND category = ?'; params.push(input.category) }
    if (input.domain) { sql += ' AND domain = ?'; params.push(input.domain) }
    sql += ' ORDER BY importance DESC, created_at DESC'
    sql += ` LIMIT ${(input.limit as number) || 20}`

    const rows = db.prepare(sql).all(...params)
    return { success: true, data: rows, message: `Found ${rows.length} memories` }
  } finally { db.close() }
}

function forgetMemory(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    db.prepare('DELETE FROM milo_memories WHERE id = ?').run(input.memory_id)
    return { success: true, data: { id: input.memory_id }, message: 'Memory removed' }
  } finally { db.close() }
}

// -- Event Completion by Title (fuzzy match bridge) --

function completeEventByTitle(input: Record<string, unknown>): ToolResult {
  const db = getDb()
  try {
    const title = input.title as string

    // Try exact match first
    let event = db.prepare(
      "SELECT id, title FROM milo_events WHERE status = 'active' AND LOWER(TRIM(title)) = LOWER(TRIM(?))"
    ).get(title) as { id: string; title: string } | undefined

    // Fall back to LIKE match
    if (!event) {
      event = db.prepare(
        "SELECT id, title FROM milo_events WHERE status = 'active' AND LOWER(title) LIKE LOWER(?)"
      ).get(`%${title}%`) as { id: string; title: string } | undefined
    }

    if (!event) {
      return { success: false, data: null, message: `No active event found matching "${title}"` }
    }

    // Complete this event and any duplicates with the same title
    const dupes = db.prepare(
      "SELECT id FROM milo_events WHERE status = 'active' AND LOWER(TRIM(title)) = LOWER(TRIM(?))"
    ).all(event.title) as Array<{ id: string }>

    for (const d of dupes) {
      db.prepare("UPDATE milo_events SET status = 'completed' WHERE id = ?").run(d.id)
    }

    return { success: true, data: { id: event.id, title: event.title, completed_count: dupes.length }, message: `Completed: ${event.title}${dupes.length > 1 ? ` (and ${dupes.length - 1} duplicate${dupes.length > 2 ? 's' : ''})` : ''}` }
  } finally { db.close() }
}

// -- Dispatcher --

const handlers: Record<string, (input: Record<string, unknown>) => ToolResult> = {
  list_goals: listGoals,
  create_goal: createGoal,
  update_goal: updateGoal,
  list_strategies: listStrategies,
  create_strategy: createStrategy,
  update_strategy: updateStrategy,
  list_events: listEvents,
  create_event: createEvent,
  complete_event: completeEvent,
  complete_event_by_title: completeEventByTitle,
  add_todo: addTodo,
  complete_todo: completeTodo,
  whats_on_my_plate: whatsOnMyPlate,
  create_task: createTask,
  list_tasks: listTasks,
  update_task: updateTask,
  save_memory: saveMemory,
  search_memory: searchMemory,
  list_memories: listMemories,
  forget_memory: forgetMemory,
}

export function executeTool(name: string, input: Record<string, unknown>): ToolResult {
  const handler = handlers[name]
  if (!handler) {
    return { success: false, data: null, message: `Unknown tool: ${name}` }
  }
  try {
    return handler(input)
  } catch (err) {
    return { success: false, data: null, message: `Tool error: ${(err as Error).message}` }
  }
}
