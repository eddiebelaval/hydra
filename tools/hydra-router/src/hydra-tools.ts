/**
 * HYDRA System Tool Definitions
 *
 * 6 tools for system operations that HYDRA handles directly.
 * These are NOT Milo's tools -- they're infrastructure-level.
 */

import type { ClaudeTool } from './types.js'

// -- Memory Tools --

const memoryTools: ClaudeTool[] = [
  {
    name: 'save_routing_insight',
    description: 'Save an operational memory. Use when you learn something about how Eddie uses the system, his routing preferences, entity performance, or system patterns. Categories: routing_preference (how Eddie likes to be routed), routing_pattern (repeatable routing observation), entity_insight (observation about entity performance), feedback (Eddie correcting routing behavior), observation (analytical insight), fact (operational fact), system_event (significant event), entity_preference (Eddie stating he prefers an entity).',
    input_schema: {
      type: 'object' as const,
      properties: {
        content: { type: 'string', description: 'The insight to remember (one sentence)' },
        category: {
          type: 'string',
          enum: ['routing_preference', 'routing_pattern', 'entity_insight', 'feedback', 'observation', 'fact', 'system_event', 'entity_preference'],
        },
        importance: { type: 'number', description: '1-10 scale. 8-10 = changes routing behavior. 5-7 = useful pattern. 1-4 = minor.' },
        domain: { type: 'string', description: 'Entity or system area this relates to (milo, axis, iris, hydra, telegram). Optional.' },
      },
      required: ['content', 'category'],
    },
  },
  {
    name: 'search_operational_memory',
    description: 'Search HYDRA\'s operational memories by keyword, category, or domain.',
    input_schema: {
      type: 'object' as const,
      properties: {
        query: { type: 'string', description: 'Search term' },
        category: { type: 'string', description: 'Filter by category' },
        domain: { type: 'string', description: 'Filter by domain (entity or system area)' },
      },
      required: [],
    },
  },
  {
    name: 'list_operational_memories',
    description: 'List recent or important operational memories. Filter by category or domain.',
    input_schema: {
      type: 'object' as const,
      properties: {
        category: { type: 'string' },
        domain: { type: 'string' },
        limit: { type: 'number' },
      },
      required: [],
    },
  },
]

// -- System Tools --

export const HYDRA_TOOLS: ClaudeTool[] = [
  ...memoryTools,
  {
    name: 'daemon_status',
    description: 'Check the health of HYDRA daemons. Returns which daemons are running, when they last ran, and any recent errors.',
    input_schema: {
      type: 'object' as const,
      properties: {
        daemon_name: {
          type: 'string',
          description: 'Specific daemon to check (optional, returns all if omitted)',
        },
      },
      required: [],
    },
  },
  {
    name: 'entity_status',
    description: 'Show which entity is currently handling the conversation, how long it has been active, and recent routing history.',
    input_schema: {
      type: 'object' as const,
      properties: {
        session_id: {
          type: 'string',
          description: 'Session ID to check (uses current session if omitted)',
        },
      },
      required: [],
    },
  },
  {
    name: 'route_to_entity',
    description: 'Explicitly switch the active entity for the current conversation. Use when Eddie asks to talk to a specific entity.',
    input_schema: {
      type: 'object' as const,
      properties: {
        entity: {
          type: 'string',
          enum: ['milo', 'axis', 'iris'],
          description: 'The entity to switch to',
        },
        reason: {
          type: 'string',
          description: 'Why the switch is happening',
        },
      },
      required: ['entity'],
    },
  },
  {
    name: 'list_entities',
    description: 'List all available entities with their domains and availability status.',
    input_schema: {
      type: 'object' as const,
      properties: {},
      required: [],
    },
  },
  {
    name: 'hydra_health',
    description: 'System health report: daemon count, DB size, active sessions, uptime, memory usage.',
    input_schema: {
      type: 'object' as const,
      properties: {},
      required: [],
    },
  },
  {
    name: 'who_am_i',
    description: 'Tell Eddie who is currently handling his messages and why.',
    input_schema: {
      type: 'object' as const,
      properties: {},
      required: [],
    },
  },
]
