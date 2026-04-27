#!/usr/bin/env tsx
/**
 * Milo Respond -- Main Pipeline
 *
 * CLI entry point invoked per-message by milo-telegram-listener.sh.
 * Pipeline: args -> CaF -> context -> Claude API -> tool loop -> persist -> stdout
 *
 * Usage:
 *   npx tsx src/index.ts --message "what are my goals?" --session-id abc123
 */

import Anthropic from '@anthropic-ai/sdk'
import { composeMiloPrompt } from './caf-loader.js'
import { loadContext, formatContextForPrompt, saveTurn } from './context.js'
import { ALL_TOOLS } from './tools.js'
import { executeTool } from './tool-executor.js'

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

// -- Compose System Prompt --

function composeSystemPrompt(cafPrompt: string, contextStr: string): string {
  return `${cafPrompt}

## Current Conversation Context
You are speaking with Eddie Belaval on Telegram. This is a private, personal conversation.
Today is ${new Date().toISOString().split('T')[0]}.

${contextStr}

## Telegram Rules
- Be conversational. Match Eddie's energy and depth.
- Use tools when Eddie asks to track, create, update, or check on things.
- Do not announce tool usage. Just do it and report the result naturally.
- Never say "according to my data" or "I remember that you..." -- just know things.
- Keep responses Telegram-appropriate: 2-6 sentences for light chat, more for substantial topics.
- No emoji. No bullet points in conversational responses (ok in status reports).
- Reference goals, strategies, and events naturally when relevant.
- If Eddie seems off track from his stated goals/priorities, gently note it.
- If you learn something important about Eddie, use save_memory to remember it.
- When Eddie reports that a meeting happened, an event occurred, or a reminder was handled, ALWAYS use complete_event_by_title to mark it done immediately. Do not wait for explicit instructions. Examples: "met with Jose", "the Gus thing went well", "handled the lawyer call" all mean the corresponding event is complete.
- When creating events, check context for existing events with similar titles. Do not create duplicates.
- When saving memories, use the most specific category: fact (biographical), preference (tastes), relationship (people), decision (committed choice), project (project status), pattern (what works), antipattern (what fails), milestone (significant achievement), observation (your own analysis of Eddie), feedback (Eddie correcting your behavior), location (places), trip (journeys), event_memory (notable past events), routine (recurring habits), financial (money), health (body/mind). Include a domain when relevant (e.g., homer, trading, cpn).`
}

// -- Build Messages Array --

function buildMessages(
  recentTurns: Array<{ role: string; content: string; tool_name: string | null; tool_input: string | null }>,
  newMessage: string
): Anthropic.Messages.MessageParam[] {
  const messages: Anthropic.Messages.MessageParam[] = []

  for (const turn of recentTurns) {
    if (turn.role === 'user') {
      messages.push({ role: 'user', content: turn.content })
    } else if (turn.role === 'assistant') {
      messages.push({ role: 'assistant', content: turn.content })
    }
    // tool_use and tool_result turns are simplified in history
    // (full tool replay is not needed -- summaries capture decisions)
  }

  messages.push({ role: 'user', content: newMessage })
  return messages
}

// -- Main Pipeline --

async function main() {
  const { message, messageId, sessionId, lockinFresh } = parseArgs()

  // 1. Load CaF consciousness + coordination layer (threaded with current message for name-mentioned person preloading, and lock-in surfacing if Eddie's been away >= 2hr)
  const cafPrompt = composeMiloPrompt('chat', { currentMessage: message, lockinFresh })

  // 2. Load context from DB
  const rollingWindow = parseInt(process.env.MILO_ROLLING_WINDOW || '40')
  const summaryCount = parseInt(process.env.MILO_SUMMARY_COUNT || '5')
  const memoryLimit = parseInt(process.env.MILO_MEMORY_LIMIT || '20')
  const ctx = loadContext(sessionId, rollingWindow, summaryCount, memoryLimit)

  // 3. Compose system prompt
  const contextStr = formatContextForPrompt(ctx)
  const systemPrompt = composeSystemPrompt(cafPrompt, contextStr)

  // 4. Build messages array
  const messages = buildMessages(ctx.recentTurns, message)

  // 5. Call Claude with tools
  const client = new Anthropic()
  const maxLoops = parseInt(process.env.MILO_MAX_TOOL_LOOPS || '5')
  let loopCount = 0
  let finalText = ''

  // Save user message
  saveTurn('user', message, sessionId, parseInt(messageId) || undefined)

  let currentMessages = messages

  while (loopCount < maxLoops) {
    loopCount++

    const response = await client.messages.create({
      model: process.env.MILO_CHAT_MODEL || 'claude-sonnet-4-20250514',
      max_tokens: 2048,
      system: systemPrompt,
      messages: currentMessages,
      tools: ALL_TOOLS,
    })

    const assistantContent: Anthropic.Messages.ContentBlock[] = response.content
    const toolResults: Anthropic.Messages.ToolResultBlockParam[] = []

    for (const block of assistantContent) {
      if (block.type === 'text') {
        finalText += block.text
      } else if (block.type === 'tool_use') {
        const result = executeTool(block.name, block.input as Record<string, unknown>)

        saveTurn('tool_use', JSON.stringify(block.input), sessionId, undefined, block.name, JSON.stringify(block.input))
        saveTurn('tool_result', JSON.stringify(result), sessionId, undefined, block.name)

        toolResults.push({
          type: 'tool_result',
          tool_use_id: block.id,
          content: JSON.stringify(result),
        })
      }
    }

    if (toolResults.length === 0) break

    // Append the full assistant turn and a single user turn carrying ALL tool_results.
    // The API requires every tool_use block to be paired with a tool_result block in the immediately following user turn.
    currentMessages = [
      ...currentMessages,
      { role: 'assistant', content: assistantContent },
      { role: 'user', content: toolResults },
    ]

    finalText = ''
  }

  // Save assistant response
  if (finalText) {
    saveTurn('assistant', finalText, sessionId)
  }

  // Output to stdout for bash listener to send
  process.stdout.write(finalText)
}

main().catch(err => {
  process.stderr.write(`Pipeline error: ${err.message}\n`)
  process.exit(1)
})
