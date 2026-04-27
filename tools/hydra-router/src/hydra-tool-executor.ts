/**
 * HYDRA System Tool Executor
 *
 * Executes HYDRA's 6 system tools against launchd, hydra.db, and OS.
 * Pattern adapted from milo-respond/src/tool-executor.ts.
 */

import { execFileSync } from 'child_process'
import fs from 'fs'
import path from 'path'
import Database from 'better-sqlite3'
import { loadRoutingSession, getRoutingHistory, forceRoute } from './routing-session.js'
import { saveMemory, searchMemories, listMemories } from './hydra-memory-db.js'
import type { HydraMemoryCategory } from './hydra-memory-db.js'
import type { EntityId, ToolResult, ToolHandler } from './types.js'

const HYDRA_ROOT = process.env.HYDRA_ROOT || `${process.env.HOME}/.hydra`
const HYDRA_DB = process.env.HYDRA_DB || `${HYDRA_ROOT}/hydra.db`

// Current session ID, set by the pipeline before tool execution
let currentSessionId = 'default'

export function setCurrentSession(sessionId: string): void {
  currentSessionId = sessionId
}

// -- Tool Implementations --

function daemonStatus(input: Record<string, unknown>): ToolResult {
  const daemonName = input.daemon_name as string | undefined

  try {
    // List HYDRA launchd jobs
    const output = execFileSync('launchctl', ['list'], {
      encoding: 'utf-8',
      timeout: 5000,
    })

    const lines = output.split('\n').filter(l => l.includes('hydra') || l.includes('milo'))

    if (daemonName) {
      const filtered = lines.filter(l => l.toLowerCase().includes(daemonName.toLowerCase()))
      return {
        success: true,
        data: { daemons: filtered, count: filtered.length },
        message: filtered.length > 0
          ? `Found ${filtered.length} daemon(s) matching "${daemonName}"`
          : `No daemons found matching "${daemonName}"`,
      }
    }

    // Also check lock files for running daemons
    const stateDir = path.join(HYDRA_ROOT, 'state')
    const lockDirs: string[] = []
    try {
      const entries = fs.readdirSync(stateDir)
      for (const entry of entries) {
        if (entry.endsWith('.lockdir')) {
          const pidFile = path.join(stateDir, entry, 'pid')
          try {
            const pid = fs.readFileSync(pidFile, 'utf-8').trim()
            lockDirs.push(`${entry} (PID ${pid})`)
          } catch {
            lockDirs.push(`${entry} (stale lock)`)
          }
        }
      }
    } catch { /* state dir may not exist */ }

    return {
      success: true,
      data: {
        launchd_daemons: lines,
        running_locks: lockDirs,
        daemon_count: lines.length,
      },
      message: `${lines.length} HYDRA daemon(s) registered in launchd. ${lockDirs.length} active lock(s).`,
    }
  } catch (err) {
    return {
      success: false,
      data: null,
      message: `Failed to check daemon status: ${err instanceof Error ? err.message : String(err)}`,
    }
  }
}

function entityStatus(input: Record<string, unknown>): ToolResult {
  const sessionId = (input.session_id as string) || currentSessionId
  const session = loadRoutingSession(sessionId)
  const history = getRoutingHistory(sessionId, 5)

  if (!session) {
    return {
      success: true,
      data: { active_entity: null, history: [] },
      message: 'No active routing session. Next message will be classified fresh.',
    }
  }

  return {
    success: true,
    data: {
      active_entity: session.active_entity,
      message_count: session.message_count,
      routed_at: session.routed_at,
      reason: session.reason,
      confidence: session.confidence,
      history: history.map(h => ({
        entity: h.active_entity,
        reason: h.reason,
        messages: h.message_count,
        at: h.routed_at,
      })),
    },
    message: `Currently routed to ${session.active_entity} (${session.message_count} messages, reason: ${session.reason})`,
  }
}

function routeToEntity(input: Record<string, unknown>): ToolResult {
  const entity = input.entity as EntityId
  const reason = (input.reason as string) || 'Explicit route request'

  if (!['milo', 'axis', 'iris'].includes(entity)) {
    return {
      success: false,
      data: null,
      message: `Invalid entity: ${entity}. Must be milo, axis, or iris.`,
    }
  }

  forceRoute(currentSessionId, entity)

  return {
    success: true,
    data: { entity, session_id: currentSessionId },
    message: `Switched to ${entity}. Reason: ${reason}`,
  }
}

function listEntities(): ToolResult {
  const entities = [
    {
      name: 'Milo',
      id: 'milo',
      domain: 'Personal life, goals, events, memories, accountability',
      status: 'available',
      surface: 'telegram',
    },
    {
      name: 'Axis',
      id: 'axis',
      domain: 'Business strategy, pricing, GTM, decisions',
      status: 'stub (routes to Milo)',
      surface: 'telegram (pending)',
    },
    {
      name: 'Iris',
      id: 'iris',
      domain: 'Visual design, UI review, brand aesthetics',
      status: 'stub (routes to Milo)',
      surface: 'telegram (pending)',
    },
    {
      name: 'HYDRA',
      id: 'hydra',
      domain: 'System ops, daemon health, routing, coordination',
      status: 'available',
      surface: 'telegram',
    },
  ]

  return {
    success: true,
    data: { entities },
    message: `4 entities registered. 2 available (Milo, HYDRA), 2 pending (Axis, Iris).`,
  }
}

function hydraHealth(): ToolResult {
  try {
    // DB size
    const dbStats = fs.statSync(HYDRA_DB)
    const dbSizeMB = (dbStats.size / 1024 / 1024).toFixed(1)

    // Daemon count from launchd
    const launchctlOutput = execFileSync('launchctl', ['list'], {
      encoding: 'utf-8',
      timeout: 5000,
    })
    const daemonCount = launchctlOutput.split('\n').filter(l => l.includes('hydra') || l.includes('milo')).length

    // Table counts from DB
    const db = new Database(HYDRA_DB)
    const conversationCount = (db.prepare('SELECT COUNT(*) as c FROM milo_conversations').get() as { c: number }).c
    const memoryCount = (db.prepare('SELECT COUNT(*) as c FROM milo_memories').get() as { c: number }).c

    let routingCount = 0
    try {
      routingCount = (db.prepare('SELECT COUNT(*) as c FROM routing_sessions').get() as { c: number }).c
    } catch { /* table may not exist yet */ }

    db.close()

    return {
      success: true,
      data: {
        db_size_mb: dbSizeMB,
        daemon_count: daemonCount,
        conversation_turns: conversationCount,
        memories: memoryCount,
        routing_sessions: routingCount,
      },
      message: `HYDRA healthy. DB: ${dbSizeMB}MB. ${daemonCount} daemons. ${conversationCount} conversation turns. ${memoryCount} memories. ${routingCount} routing sessions.`,
    }
  } catch (err) {
    return {
      success: false,
      data: null,
      message: `Health check failed: ${err instanceof Error ? err.message : String(err)}`,
    }
  }
}

function whoAmI(): ToolResult {
  const session = loadRoutingSession(currentSessionId)

  if (!session) {
    return {
      success: true,
      data: { entity: 'hydra', reason: 'no active session' },
      message: 'You are talking to HYDRA directly. No entity session is active.',
    }
  }

  return {
    success: true,
    data: {
      entity: session.active_entity,
      message_count: session.message_count,
      since: session.routed_at,
      reason: session.reason,
    },
    message: `You are talking to ${session.active_entity}. ${session.message_count} messages in this session. Routed because: ${session.reason}`,
  }
}

// -- Memory Tool Implementations --

function saveRoutingInsight(input: Record<string, unknown>): ToolResult {
  const content = input.content as string
  const category = input.category as HydraMemoryCategory
  const importance = (input.importance as number) || 5
  const domain = input.domain as string | undefined

  const validCategories: HydraMemoryCategory[] = [
    'routing_preference', 'routing_pattern', 'entity_insight', 'feedback',
    'observation', 'fact', 'system_event', 'entity_preference',
  ]

  if (!validCategories.includes(category)) {
    return { success: false, data: null, message: `Invalid category: ${category}` }
  }

  const id = saveMemory(content, category, importance, domain)
  return {
    success: true,
    data: { id, category, importance },
    message: `Saved ${category} memory (id: ${id}, importance: ${importance})`,
  }
}

function searchOperationalMemory(input: Record<string, unknown>): ToolResult {
  const query = (input.query as string) || ''
  const category = input.category as string | undefined
  const domain = input.domain as string | undefined

  const results = searchMemories(query, category, domain, 10)
  return {
    success: true,
    data: { memories: results, count: results.length },
    message: results.length > 0
      ? `Found ${results.length} memories${query ? ` matching "${query}"` : ''}`
      : 'No memories found',
  }
}

function listOperationalMemories(input: Record<string, unknown>): ToolResult {
  const category = input.category as string | undefined
  const domain = input.domain as string | undefined
  const limit = (input.limit as number) || 10

  const results = listMemories(category, domain, limit)
  return {
    success: true,
    data: { memories: results, count: results.length },
    message: `${results.length} operational memories${category ? ` in ${category}` : ''}`,
  }
}

// -- Tool Dispatch --

const toolHandlers: Record<string, ToolHandler> = {
  // Memory tools
  save_routing_insight: saveRoutingInsight,
  search_operational_memory: searchOperationalMemory,
  list_operational_memories: listOperationalMemories,
  // System tools
  daemon_status: daemonStatus,
  entity_status: entityStatus,
  route_to_entity: routeToEntity,
  list_entities: listEntities,
  hydra_health: hydraHealth,
  who_am_i: whoAmI,
}

export function executeHydraTool(name: string, input: Record<string, unknown>): ToolResult {
  const handler = toolHandlers[name]
  if (!handler) {
    return {
      success: false,
      data: null,
      message: `Unknown tool: ${name}`,
    }
  }
  return handler(input)
}
