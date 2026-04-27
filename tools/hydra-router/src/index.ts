#!/usr/bin/env tsx
/**
 * HYDRA Router -- Main Pipeline
 *
 * CLI entry point invoked per-message by milo-telegram-listener.sh.
 * Pipeline: args -> classify intent -> dispatch to entity -> stdout
 *
 * Dispatch methods:
 *   - HYDRA: Direct handling (CaF + system tools + Claude API)
 *   - Milo: Subprocess to milo-respond/src/index.ts (unchanged)
 *   - Axis/Iris: Stubs that fall back to Milo with a notice
 *
 * Usage:
 *   npx tsx src/index.ts --message "what are my goals?" --session-id abc123
 */

import { execFileSync, execFile } from 'child_process'
import path from 'path'
import Anthropic from '@anthropic-ai/sdk'
import { classifyIntent } from './classifier.js'
import { composeHydraPrompt } from './hydra-caf-loader.js'
import { HYDRA_TOOLS } from './hydra-tools.js'
import { executeHydraTool, setCurrentSession } from './hydra-tool-executor.js'
import { loadHydraContext, formatHydraContextForPrompt, getRecentUserMessages } from './hydra-context.js'
import { saveTurn } from './hydra-memory-db.js'
import type { EntityId } from './types.js'

const HYDRA_ROOT = process.env.HYDRA_ROOT || `${process.env.HOME}/.hydra`
const MILO_RESPOND_PATH = path.join(HYDRA_ROOT, 'tools/milo-respond')
const HYDRA_CHAT_MODEL = process.env.HYDRA_CHAT_MODEL || 'claude-sonnet-4-20250514'

// -- Parse CLI args --

function parseArgs(): { message: string; messageId: string; sessionId: string; lockinFresh: boolean } {
  const args = process.argv.slice(2)
  let message = ''
  let messageId = ''
  let sessionId = ''
  let lockinFresh = false

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--message' && args[i + 1]) message = args[++i]
    else if (args[i] === '--message-id' && args[i + 1]) messageId = args[++i]
    else if (args[i] === '--session-id' && args[i + 1]) sessionId = args[++i]
    else if (args[i] === '--lockin-fresh') lockinFresh = true
  }

  if (!message) {
    process.stderr.write('Error: --message is required\n')
    process.exit(1)
  }

  return { message, messageId, sessionId: sessionId || 'default', lockinFresh }
}

// -- Handoff Announcement --

function announceHandoff(entity: EntityId, reason: string): string {
  switch (entity) {
    case 'milo':
      return 'Routing to Milo.\n\n'
    case 'axis':
      return 'Routing to Axis.\n\n'
    case 'iris':
      return 'Routing to Iris.\n\n'
    case 'hydra':
      return '' // HYDRA doesn't announce itself, it just handles
  }
}

// -- Dispatch: HYDRA Direct --

async function handleDirectly(
  message: string,
  messageId: string,
  sessionId: string,
  lockinFresh = false,
): Promise<string> {
  const cafPrompt = composeHydraPrompt('respond', { currentMessage: message, lockinFresh })
  setCurrentSession(sessionId)

  // Load operational context (MaF)
  const ctx = loadHydraContext(sessionId)
  const contextStr = formatHydraContextForPrompt(ctx)

  const systemPrompt = `${cafPrompt}

## Current Context
You are HYDRA, handling a system operations request from Eddie on Telegram.
Today is ${new Date().toISOString().split('T')[0]}.
Session: ${sessionId}

${contextStr}

## Response Rules
- Be concise. System status should be structured and scannable.
- Use tools to get real data. Don't guess.
- No emoji. No filler. Lead with the answer.
- If you learn a routing preference or operational insight, use save_routing_insight to remember it.`

  // Persist user message
  saveTurn('user', message, sessionId, parseInt(messageId) || undefined)

  const client = new Anthropic()
  const maxLoops = 3
  let loopCount = 0
  let finalText = ''
  let currentMessages: Anthropic.Messages.MessageParam[] = [
    { role: 'user', content: message },
  ]

  while (loopCount < maxLoops) {
    loopCount++

    const response = await client.messages.create({
      model: HYDRA_CHAT_MODEL,
      max_tokens: 1024,
      system: systemPrompt,
      messages: currentMessages,
      tools: HYDRA_TOOLS,
    })

    let hasToolUse = false
    const assistantContent: Anthropic.Messages.ContentBlock[] = response.content

    for (const block of assistantContent) {
      if (block.type === 'text') {
        finalText += block.text
      } else if (block.type === 'tool_use') {
        hasToolUse = true
        const result = executeHydraTool(block.name, block.input as Record<string, unknown>)

        // Persist tool use
        saveTurn('tool_use', JSON.stringify(block.input), sessionId, undefined, block.name, JSON.stringify(block.input))
        saveTurn('tool_result', JSON.stringify(result), sessionId, undefined, block.name)

        currentMessages = [
          ...currentMessages,
          { role: 'assistant', content: assistantContent },
          {
            role: 'user',
            content: [{
              type: 'tool_result' as const,
              tool_use_id: block.id,
              content: JSON.stringify(result),
            }],
          },
        ]
      }
    }

    if (!hasToolUse) break
    finalText = ''
  }

  // Persist assistant response
  if (finalText) {
    saveTurn('assistant', finalText, sessionId)
  }

  return finalText
}

// -- Dispatch: Milo (subprocess) --

function dispatchToMilo(
  message: string,
  messageId: string,
  sessionId: string,
  lockinFresh = false,
): string {
  try {
    const miloArgs = [
      '--import', 'tsx/esm',
      'src/index.ts',
      '--message', message,
      '--message-id', messageId,
      '--session-id', sessionId,
    ]
    if (lockinFresh) miloArgs.push('--lockin-fresh')

    const result = execFileSync('node', miloArgs, {
      cwd: MILO_RESPOND_PATH,
      encoding: 'utf-8',
      timeout: 60000, // 60s timeout for tool loops
      env: {
        ...process.env,
        HYDRA_DB: process.env.HYDRA_DB || `${HYDRA_ROOT}/hydra.db`,
      },
    })

    return result
  } catch (err) {
    const error = err as { stderr?: string; message?: string }
    process.stderr.write(`Milo dispatch failed: ${error.stderr || error.message}\n`)
    return 'Something went wrong reaching Milo. Check the logs.'
  }
}

// -- Dispatch: Axis/Iris (stubs) --

function dispatchToStub(entity: EntityId, message: string, messageId: string, sessionId: string, lockinFresh = false): string {
  const entityName = entity.charAt(0).toUpperCase() + entity.slice(1)
  // Fall back to Milo with the original message
  const miloResponse = dispatchToMilo(message, messageId, sessionId, lockinFresh)
  return `${entityName} is not yet available on Telegram. Routing to Milo instead.\n\n${miloResponse}`
}

// -- Main Pipeline --

async function main() {
  const { message, messageId, sessionId, lockinFresh } = parseArgs()

  // Get recent messages for classifier context
  const recentMessages = getRecentUserMessages(3)

  // Classify intent
  const route = await classifyIntent(message, sessionId, recentMessages)

  // Log routing decision to stderr (captured in listener logs)
  process.stderr.write(
    `[HYDRA] ${route.stage}:${route.entity} (${route.confidence.toFixed(2)}) | ${route.reason}${lockinFresh ? ' | lockin-fresh' : ''}\n`
  )

  // Dispatch to entity
  let response: string

  switch (route.entity) {
    case 'hydra': {
      response = await handleDirectly(message, messageId, sessionId, lockinFresh)
      break
    }
    case 'milo': {
      const prefix = route.stage !== 'sticky' ? announceHandoff('milo', route.reason) : ''
      response = prefix + dispatchToMilo(message, messageId, sessionId, lockinFresh)
      break
    }
    case 'axis': {
      const prefix = announceHandoff('axis', route.reason)
      response = prefix + dispatchToStub('axis', message, messageId, sessionId, lockinFresh)
      break
    }
    case 'iris': {
      const prefix = announceHandoff('iris', route.reason)
      response = prefix + dispatchToStub('iris', message, messageId, sessionId, lockinFresh)
      break
    }
    default: {
      // Safety fallback
      response = dispatchToMilo(message, messageId, sessionId, lockinFresh)
    }
  }

  // Output response to stdout for the listener to send
  process.stdout.write(response)

  // Async: extract operational memories for HYDRA-handled messages
  if (route.entity === 'hydra' && response.length > 10) {
    const routerDir = path.join(HYDRA_ROOT, 'tools/hydra-router')
    execFile('node', [
      '--import', 'tsx/esm',
      'src/hydra-extract-memories.ts',
      '--user-message', message,
      '--assistant-message', response,
      '--route-entity', route.entity,
      '--route-reason', route.reason,
    ], { cwd: routerDir }, (err) => {
      if (err) process.stderr.write(`[HYDRA-MaF] Extraction failed: ${err.message}\n`)
    })
  }
}

main().catch(err => {
  process.stderr.write(`HYDRA Router error: ${err.message}\n`)
  // Graceful degradation: fall back to direct Milo dispatch
  try {
    const { message, messageId, sessionId, lockinFresh } = parseArgs()
    const fallback = dispatchToMilo(message, messageId, sessionId, lockinFresh)
    process.stdout.write(fallback)
  } catch {
    process.stderr.write('HYDRA Router: catastrophic failure, no response possible\n')
    process.exit(1)
  }
})
