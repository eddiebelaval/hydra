/**
 * Intent Classifier for HYDRA Router
 *
 * Three-stage classification:
 *   Stage 0: Sticky session (zero cost, check if current entity should continue)
 *   Stage 1: Keyword/pattern match (zero cost, unambiguous signals)
 *   Stage 2: Haiku LLM classification (low cost, structured JSON output)
 *
 * Falls back to Milo when confidence is low or classification fails.
 */

import Anthropic from '@anthropic-ai/sdk'
import { composeHydraPrompt } from './hydra-caf-loader.js'
import {
  loadRoutingSession,
  isDeeplySticky,
  updateRoutingSession,
} from './routing-session.js'
import type { EntityId, RouteDecision, ClassificationResponse, RoutingSession } from './types.js'

const CLASSIFICATION_MODEL = process.env.HYDRA_CLASSIFICATION_MODEL || 'claude-haiku-4-5-20251001'
const CONFIDENCE_THRESHOLD = 0.7

// -- Stage 1: Keyword/Pattern Matching --

const HYDRA_KEYWORDS = [
  'hydra', 'daemon', 'daemons', 'system status', 'health check',
  'uptime', 'who am i talking to', 'which entity', 'entity status',
]

const EXPLICIT_REROUTE_PATTERNS: Array<{ pattern: RegExp; entity: EntityId }> = [
  { pattern: /(?:^|\s)@axis\b/i, entity: 'axis' },
  { pattern: /(?:^|\s)@iris\b/i, entity: 'iris' },
  { pattern: /(?:^|\s)@milo\b/i, entity: 'milo' },
  { pattern: /(?:^|\s)@hydra\b/i, entity: 'hydra' },
  { pattern: /\bask axis\b/i, entity: 'axis' },
  { pattern: /\bask iris\b/i, entity: 'iris' },
  { pattern: /\bask milo\b/i, entity: 'milo' },
  { pattern: /^\/axis\b/i, entity: 'axis' },
  { pattern: /^\/iris\b/i, entity: 'iris' },
  { pattern: /^\/milo\b/i, entity: 'milo' },
]

// Dynamic patterns that need entity extraction
const SWITCH_PATTERN = /\bswitch to (axis|iris|milo|hydra)\b/i
const WOULD_THINK_PATTERN = /\bwhat would (axis|iris|milo) think\b/i

function matchKeywords(message: string): RouteDecision | null {
  const lower = message.toLowerCase().trim()

  // Check "switch to X" pattern
  const switchMatch = message.match(SWITCH_PATTERN)
  if (switchMatch) {
    const entity = switchMatch[1].toLowerCase() as EntityId
    return {
      entity,
      confidence: 1.0,
      reason: `Explicit switch: "switch to ${entity}"`,
      stage: 'keyword',
    }
  }

  // Check "what would X think" pattern
  const wouldMatch = message.match(WOULD_THINK_PATTERN)
  if (wouldMatch) {
    const entity = wouldMatch[1].toLowerCase() as EntityId
    return {
      entity,
      confidence: 1.0,
      reason: `Explicit consult: "what would ${entity} think"`,
      stage: 'keyword',
    }
  }

  // Check explicit reroute patterns
  for (const { pattern, entity } of EXPLICIT_REROUTE_PATTERNS) {
    if (pattern.test(message)) {
      return {
        entity,
        confidence: 1.0,
        reason: `Explicit reroute pattern`,
        stage: 'keyword',
      }
    }
  }

  // Check HYDRA system keywords
  for (const keyword of HYDRA_KEYWORDS) {
    if (lower.includes(keyword)) {
      return {
        entity: 'hydra',
        confidence: 0.95,
        reason: `System keyword: "${keyword}"`,
        stage: 'keyword',
      }
    }
  }

  return null
}

// -- Stage 2: LLM Classification --

async function classifyWithLLM(
  message: string,
  recentMessages: string[],
): Promise<RouteDecision> {
  const client = new Anthropic()

  // Load routing models (lean context)
  const routingContext = composeHydraPrompt('route')

  const systemPrompt = `You are HYDRA, a message router. Classify which entity handles a message.

${routingContext}

Output raw JSON only. No markdown. No backticks. No explanation.
Format: {"entity":"milo","confidence":0.85,"reason":"brief reason","domain_signals":["personal"]}
entity: milo|axis|iris|hydra`

  const recentContext = recentMessages.length > 0
    ? `Recent: ${recentMessages.map(m => m.substring(0, 80)).join(' | ')}\n\nClassify:`
    : 'Classify:'

  try {
    const response = await client.messages.create({
      model: CLASSIFICATION_MODEL,
      max_tokens: 150,
      temperature: 0,
      system: systemPrompt,
      messages: [
        { role: 'user', content: `${recentContext} "${message}"` },
        { role: 'assistant', content: '{' },
      ],
    })

    let text = response.content
      .filter((b): b is Anthropic.Messages.TextBlock => b.type === 'text')
      .map(b => b.text)
      .join('')

    // Prepend the '{' we used as assistant prefill
    text = '{' + text

    // Strip markdown code fences if Haiku wraps the JSON
    const jsonMatch = text.match(/\{[\s\S]*\}/)
    if (jsonMatch) text = jsonMatch[0]

    const parsed: ClassificationResponse = JSON.parse(text)

    // Validate entity
    if (!['milo', 'axis', 'iris', 'hydra'].includes(parsed.entity)) {
      return fallback('Invalid entity in classification response')
    }

    return {
      entity: parsed.entity as EntityId,
      confidence: Math.max(0, Math.min(1, parsed.confidence)),
      reason: parsed.reason,
      stage: 'llm',
    }
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err)
    return fallback(`LLM classification failed: ${errorMsg}`)
  }
}

function fallback(reason: string): RouteDecision {
  return {
    entity: 'milo',
    confidence: 0.5,
    reason: `Fallback to Milo: ${reason}`,
    stage: 'fallback',
  }
}

// -- Main Classification Pipeline --

/**
 * Classify which entity should handle a message.
 *
 * @param message - The incoming user message
 * @param sessionId - Current conversation session ID
 * @param recentMessages - Last 3 user messages for context (optional)
 * @returns RouteDecision with entity, confidence, reason, and stage
 */
export async function classifyIntent(
  message: string,
  sessionId: string,
  recentMessages: string[] = [],
): Promise<RouteDecision> {
  // Stage 1: Check for explicit reroute or system keywords (always runs, even over sticky)
  const keywordMatch = matchKeywords(message)
  if (keywordMatch) {
    updateRoutingSession(sessionId, keywordMatch.entity, keywordMatch.reason, keywordMatch.confidence)
    return keywordMatch
  }

  // Stage 0: Check sticky session (after keywords, since explicit reroutes override stickiness)
  const session: RoutingSession | null = loadRoutingSession(sessionId)

  if (session) {
    // Deeply sticky: 10+ messages, skip classification entirely
    if (isDeeplySticky(session)) {
      const decision: RouteDecision = {
        entity: session.active_entity,
        confidence: 1.0,
        reason: `Deep conversation (${session.message_count}+ messages)`,
        stage: 'sticky',
      }
      updateRoutingSession(sessionId, decision.entity, decision.reason, decision.confidence)
      return decision
    }

    // Normal sticky: keep current entity
    const decision: RouteDecision = {
      entity: session.active_entity,
      confidence: 0.8,
      reason: `Sticky session (${session.message_count} messages, entity: ${session.active_entity})`,
      stage: 'sticky',
    }
    updateRoutingSession(sessionId, decision.entity, decision.reason, decision.confidence)
    return decision
  }

  // Stage 2: LLM classification (no active session or session expired)
  const llmResult = await classifyWithLLM(message, recentMessages)

  // Apply confidence threshold
  if (llmResult.confidence < CONFIDENCE_THRESHOLD) {
    const decision = fallback(`Low confidence (${llmResult.confidence.toFixed(2)}) on: ${llmResult.reason}`)
    updateRoutingSession(sessionId, decision.entity, decision.reason, decision.confidence)
    return decision
  }

  updateRoutingSession(sessionId, llmResult.entity, llmResult.reason, llmResult.confidence)
  return llmResult
}

/**
 * Check if a message is an explicit reroute command.
 */
export function isExplicitReroute(message: string): EntityId | null {
  const match = matchKeywords(message)
  if (match && match.stage === 'keyword' && match.confidence >= 1.0) {
    return match.entity
  }
  return null
}
