import type Anthropic from '@anthropic-ai/sdk'

// Entity identifiers
export type EntityId = 'hydra' | 'milo' | 'axis' | 'iris'

// CaF loading contexts
export type HydraContext = 'route' | 'respond'

// Classification result
export interface RouteDecision {
  entity: EntityId
  confidence: number
  reason: string
  stage: 'sticky' | 'keyword' | 'llm' | 'fallback'
}

// Routing session state from DB
export interface RoutingSession {
  id: number
  session_id: string
  active_entity: EntityId
  routed_at: string
  reason: string | null
  confidence: number | null
  message_count: number
  created_at: string
}

// Classification prompt response (structured JSON from Haiku)
export interface ClassificationResponse {
  entity: EntityId
  confidence: number
  reason: string
  domain_signals: string[]
}

// Tool types (reuse pattern from milo-respond)
export interface ToolResult {
  success: boolean
  data: unknown
  message: string
}

export type ToolHandler = (input: Record<string, unknown>) => ToolResult

export type ClaudeTool = Anthropic.Messages.Tool
