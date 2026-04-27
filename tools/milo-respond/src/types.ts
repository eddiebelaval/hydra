import type Anthropic from '@anthropic-ai/sdk'

export type MiloContext = 'chat' | 'morning_briefing' | 'evening_review' | 'nudge'

export interface ConversationTurn {
  id: number
  role: 'user' | 'assistant' | 'tool_use' | 'tool_result'
  content: string
  tool_name: string | null
  tool_input: string | null
  token_count: number | null
  session_id: string | null
  telegram_message_id: number | null
  created_at: string
}

export interface ConversationSummary {
  id: number
  summary: string
  turn_range_start: number
  turn_range_end: number
  turn_count: number
  key_topics: string | null
  key_decisions: string | null
  emotional_tone: string | null
  created_at: string
}

export interface Memory {
  id: number
  content: string
  category: string
  importance: number
  created_at: string
}

export interface Goal {
  id: string
  horizon: string
  period: string
  description: string
  status: string
  progress: number
  category: string
  notes: string | null
  target_date: string | null
}

export interface Strategy {
  id: string
  title: string
  description: string
  goal_id: string | null
  status: string
  key_assumptions: string | null
  evidence: string | null
  created_at: string
}

export interface MiloEvent {
  id: string
  title: string
  description: string | null
  event_type: string
  starts_at: string | null
  ends_at: string | null
  all_day: number
  status: string
  goal_id: string | null
}

export interface MoodEntry {
  mood: string
  energy_level: string | null
  context: string | null
  created_at: string
}

export interface ContextWindow {
  recentTurns: ConversationTurn[]
  summaries: ConversationSummary[]
  goals: Goal[]
  strategies: Strategy[]
  events: MiloEvent[]
  memories: Memory[]
  moods: MoodEntry[]
  priorities: Array<{ priority_number: number; description: string; status: string }>
  portfolio?: import('./portfolio-reader.js').PortfolioSnapshot
}

export interface ToolResult {
  success: boolean
  data: unknown
  message: string
}

export type ToolHandler = (input: Record<string, unknown>) => ToolResult

export type ClaudeTool = Anthropic.Messages.Tool
