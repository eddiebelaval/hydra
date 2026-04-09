/**
 * Claude Tool Definitions for Milo
 *
 * 16 tools across 5 domains. Claude decides when to use them.
 * No intent classification needed -- tool_use handles routing.
 */

import type { ClaudeTool } from './types.js'

const goalTools: ClaudeTool[] = [
  {
    name: 'list_goals',
    description: "List Eddie's goals. Optionally filter by horizon or status.",
    input_schema: {
      type: 'object' as const,
      properties: {
        horizon: { type: 'string', enum: ['quarterly', 'monthly', 'weekly'] },
        status: { type: 'string', enum: ['active', 'achieved', 'dropped', 'revised', 'carried'] },
      },
      required: [],
    },
  },
  {
    name: 'create_goal',
    description: 'Create a new goal. Requires description and horizon.',
    input_schema: {
      type: 'object' as const,
      properties: {
        description: { type: 'string' },
        horizon: { type: 'string', enum: ['quarterly', 'monthly', 'weekly'] },
        period: { type: 'string', description: 'e.g. Q2-2026, 2026-04, 2026-W14' },
        category: { type: 'string', enum: ['product', 'revenue', 'ops', 'growth', 'personal'] },
        target_date: { type: 'string', description: 'ISO date' },
      },
      required: ['description', 'horizon', 'period'],
    },
  },
  {
    name: 'update_goal',
    description: "Update a goal's progress, status, or notes.",
    input_schema: {
      type: 'object' as const,
      properties: {
        goal_id: { type: 'string' },
        progress: { type: 'number' },
        status: { type: 'string', enum: ['active', 'achieved', 'dropped', 'revised', 'carried'] },
        notes: { type: 'string' },
      },
      required: ['goal_id'],
    },
  },
]

const strategyTools: ClaudeTool[] = [
  {
    name: 'list_strategies',
    description: "List active strategies. Optionally filter by goal.",
    input_schema: {
      type: 'object' as const,
      properties: {
        goal_id: { type: 'string' },
        status: { type: 'string', enum: ['active', 'revised', 'archived', 'abandoned'] },
      },
      required: [],
    },
  },
  {
    name: 'create_strategy',
    description: 'Record a strategic approach or decision.',
    input_schema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string' },
        description: { type: 'string' },
        goal_id: { type: 'string' },
        key_assumptions: { type: 'array', items: { type: 'string' } },
      },
      required: ['title', 'description'],
    },
  },
  {
    name: 'update_strategy',
    description: 'Update or revise a strategy.',
    input_schema: {
      type: 'object' as const,
      properties: {
        strategy_id: { type: 'string' },
        status: { type: 'string', enum: ['active', 'revised', 'archived', 'abandoned'] },
        description: { type: 'string' },
        evidence: { type: 'array', items: { type: 'string' } },
      },
      required: ['strategy_id'],
    },
  },
]

const eventTools: ClaudeTool[] = [
  {
    name: 'list_events',
    description: 'List upcoming events, reminders, and deadlines.',
    input_schema: {
      type: 'object' as const,
      properties: {
        days_ahead: { type: 'number', description: 'How many days ahead to look (default 7)' },
        event_type: { type: 'string', enum: ['event', 'reminder', 'deadline', 'recurring'] },
      },
      required: [],
    },
  },
  {
    name: 'create_event',
    description: 'Create an event, reminder, or deadline.',
    input_schema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string' },
        description: { type: 'string' },
        event_type: { type: 'string', enum: ['event', 'reminder', 'deadline', 'recurring'] },
        starts_at: { type: 'string', description: 'ISO datetime' },
        ends_at: { type: 'string' },
        all_day: { type: 'boolean' },
        goal_id: { type: 'string' },
      },
      required: ['title', 'event_type'],
    },
  },
  {
    name: 'complete_event',
    description: 'Mark an event or reminder as completed.',
    input_schema: {
      type: 'object' as const,
      properties: {
        event_id: { type: 'string' },
      },
      required: ['event_id'],
    },
  },
  {
    name: 'complete_event_by_title',
    description: 'Mark an event as completed by title (fuzzy match). Use this when Eddie says a meeting happened, an event passed, or a reminder was handled. You do NOT need the event ID -- just the title or a close match. Also cleans up any duplicates of the same event.',
    input_schema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string', description: 'The event title or a close match (case-insensitive)' },
      },
      required: ['title'],
    },
  },
]

const taskTools: ClaudeTool[] = [
  {
    name: 'add_todo',
    description: 'Add a todo item Eddie mentioned. Lightweight -- for things like "call the lawyer", "buy groceries", "look into X". Use this instead of create_task for informal items Eddie mentions in conversation. Assign a horizon: today, this_week, this_month, or someday.',
    input_schema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string' },
        horizon: { type: 'string', enum: ['today', 'this_week', 'this_month', 'someday'], description: 'When this should get done' },
        context: { type: 'string', description: 'Brief context for why or what prompted this' },
      },
      required: ['title', 'horizon'],
    },
  },
  {
    name: 'complete_todo',
    description: 'Mark a todo item as done. Eddie might say "done", "handled", "did it", etc.',
    input_schema: {
      type: 'object' as const,
      properties: {
        task_id: { type: 'string' },
      },
      required: ['task_id'],
    },
  },
  {
    name: 'whats_on_my_plate',
    description: 'Show everything Eddie is tracking: hot todos, active goals, upcoming events, pending tasks. Use when Eddie asks "what do I have going on", "what am I forgetting", "what should I focus on", etc.',
    input_schema: {
      type: 'object' as const,
      properties: {
        horizon: { type: 'string', enum: ['today', 'this_week', 'this_month', 'all'], description: 'Time horizon to focus on (default: all)' },
      },
      required: [],
    },
  },
  {
    name: 'create_task',
    description: 'Create a formal task for Eddie. Use for structured work items, not casual todos.',
    input_schema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string' },
        description: { type: 'string' },
        priority: { type: 'number', description: '1 (critical) to 4 (low)' },
        due_at: { type: 'string', description: 'ISO datetime' },
      },
      required: ['title'],
    },
  },
  {
    name: 'list_tasks',
    description: "List Eddie's tasks, optionally filtered by status.",
    input_schema: {
      type: 'object' as const,
      properties: {
        status: { type: 'string', enum: ['pending', 'in_progress', 'completed', 'blocked'] },
        limit: { type: 'number' },
      },
      required: [],
    },
  },
  {
    name: 'update_task',
    description: "Update a task's status, priority, or details.",
    input_schema: {
      type: 'object' as const,
      properties: {
        task_id: { type: 'string' },
        status: { type: 'string', enum: ['pending', 'in_progress', 'completed', 'blocked', 'cancelled'] },
        priority: { type: 'number' },
        title: { type: 'string' },
      },
      required: ['task_id'],
    },
  },
]

const memoryTools: ClaudeTool[] = [
  {
    name: 'save_memory',
    description: 'Save an important fact, preference, or context for long-term recall.',
    input_schema: {
      type: 'object' as const,
      properties: {
        content: { type: 'string' },
        category: { type: 'string', enum: ['fact', 'preference', 'project_context', 'relationship', 'milestone', 'decision'] },
        importance: { type: 'number', description: '1-10 scale' },
      },
      required: ['content', 'category'],
    },
  },
  {
    name: 'search_memory',
    description: 'Search memories by keyword or category.',
    input_schema: {
      type: 'object' as const,
      properties: {
        query: { type: 'string' },
        category: { type: 'string' },
      },
      required: [],
    },
  },
  {
    name: 'list_memories',
    description: 'List recent or important memories.',
    input_schema: {
      type: 'object' as const,
      properties: {
        category: { type: 'string' },
        limit: { type: 'number' },
      },
      required: [],
    },
  },
  {
    name: 'forget_memory',
    description: 'Remove a memory that is no longer relevant.',
    input_schema: {
      type: 'object' as const,
      properties: {
        memory_id: { type: 'number' },
      },
      required: ['memory_id'],
    },
  },
]

export const ALL_TOOLS: ClaudeTool[] = [
  ...goalTools,
  ...strategyTools,
  ...eventTools,
  ...taskTools,
  ...memoryTools,
]
