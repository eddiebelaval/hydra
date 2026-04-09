#!/usr/bin/env tsx
/**
 * Milo Heartbeat -- Proactive Intelligence Layer
 *
 * Runs on a schedule (launchd, every 30 min). Scans all tracked items,
 * computes priority temperatures, and sends proactive messages when
 * things need attention.
 *
 * Temperature scale (matches Milo's emotional architecture):
 *   HOT  (90-100) -- Needs attention NOW. Overdue, due today, critical.
 *   WARM (60-89)  -- Needs attention soon. Due this week, stale, patterns.
 *   COOL (30-59)  -- Background awareness. Tracking, no action needed yet.
 *   COLD (0-29)   -- Dormant. Still monitored for resurrection signals.
 *
 * Rate limiting: max 5 proactive messages per day. Morning pulse always fires.
 * Scheduled beats: 9am (morning pulse), 2pm (afternoon check), 8pm (evening wind-down)
 * Event-driven: fires between beats when HOT items detected.
 *
 * Output: Composes a message through Milo's CaF voice and sends via Telegram.
 */

import Anthropic from '@anthropic-ai/sdk'
import Database from 'better-sqlite3'
import fs from 'fs'
import { execFileSync } from 'child_process'
import { composeMiloPrompt } from './caf-loader.js'
import { runSelfRepair, type RepairReport } from './self-repair.js'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const STATE_DIR = `${process.env.HOME}/.hydra/state`
const MAX_DAILY_PROACTIVE = 5
const HEARTBEAT_STATE = `${STATE_DIR}/milo-heartbeat-state.json`
const HEARTBEAT_LOG = `${process.env.HOME}/Library/Logs/claude-automation/milo-telegram/heartbeat.log`

// ============================================================================
// TEMPERATURE COMPUTATION
// ============================================================================

interface TrackedItem {
  id: string
  source: string       // 'event' | 'goal' | 'strategy' | 'task' | 'conversation'
  title: string
  temperature: number  // 0-100
  reason: string       // why this temperature
  details: string      // context for Milo's message
}

function hoursUntil(isoDate: string): number {
  return (new Date(isoDate).getTime() - Date.now()) / (1000 * 60 * 60)
}

function hoursSince(isoDate: string): number {
  return (Date.now() - new Date(isoDate).getTime()) / (1000 * 60 * 60)
}

function daysSince(isoDate: string): number {
  return hoursSince(isoDate) / 24
}

function scanEvents(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const events = db.prepare(`
    SELECT id, title, description, event_type, starts_at, status
    FROM milo_events WHERE status = 'active'
  `).all() as Array<{ id: string; title: string; description: string; event_type: string; starts_at: string; status: string }>

  for (const e of events) {
    if (!e.starts_at) {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 35, reason: 'undated reminder', details: e.description || e.title })
      continue
    }

    const hours = hoursUntil(e.starts_at)

    if (hours < 0) {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 95, reason: `overdue by ${Math.abs(Math.round(hours))}h`, details: `${e.event_type}: ${e.title} was due ${e.starts_at}` })
    } else if (hours < 2) {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 90, reason: `due in ${Math.round(hours * 60)}min`, details: `${e.event_type}: ${e.title} at ${e.starts_at}` })
    } else if (hours < 24) {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 75, reason: 'due today', details: `${e.event_type}: ${e.title} at ${e.starts_at}` })
    } else if (hours < 72) {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 50, reason: `due in ${Math.round(hours / 24)} days`, details: `${e.event_type}: ${e.title}` })
    } else {
      items.push({ id: e.id, source: 'event', title: e.title, temperature: 25, reason: 'upcoming', details: `${e.event_type}: ${e.title} on ${e.starts_at}` })
    }
  }

  return items
}

function scanGoals(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const goals = db.prepare(`
    SELECT g.id, g.description, g.progress, g.horizon, g.period, g.category, g.updated_at,
           (SELECT MAX(created_at) FROM goal_checkins WHERE goal_id = g.id) as last_checkin
    FROM goals g WHERE g.status = 'active'
  `).all() as Array<{ id: string; description: string; progress: number; horizon: string; period: string; category: string; updated_at: string; last_checkin: string | null }>

  for (const g of goals) {
    const daysSinceUpdate = g.updated_at ? daysSince(g.updated_at) : 999
    const daysSinceCheckin = g.last_checkin ? daysSince(g.last_checkin) : 999

    let temp = 30
    let reason = 'on track'

    if (g.horizon === 'weekly' && daysSinceCheckin > 3) {
      temp = 70; reason = `weekly goal, no check-in in ${Math.round(daysSinceCheckin)} days`
    } else if (g.horizon === 'monthly' && daysSinceCheckin > 7) {
      temp = 65; reason = `monthly goal, no check-in in ${Math.round(daysSinceCheckin)} days`
    } else if (g.horizon === 'quarterly' && daysSinceCheckin > 14) {
      temp = 55; reason = `quarterly goal stale for ${Math.round(daysSinceCheckin)} days`
    }

    if (g.horizon === 'weekly' && g.progress < 30 && daysSinceUpdate > 3) {
      temp = Math.max(temp, 75); reason = `weekly goal at ${g.progress}%, stale`
    }

    if (g.progress === 0 && daysSinceUpdate > 5) {
      temp = Math.max(temp, 70); reason = `no progress, ${Math.round(daysSinceUpdate)} days idle`
    }

    items.push({
      id: g.id, source: 'goal', title: g.description,
      temperature: temp, reason,
      details: `[${g.horizon}/${g.period}] ${g.description} -- ${g.progress}% (${g.category})`
    })
  }

  return items
}

function scanStrategies(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const strategies = db.prepare(`
    SELECT id, title, description, status, updated_at, evidence
    FROM milo_strategies WHERE status = 'active'
  `).all() as Array<{ id: string; title: string; description: string; status: string; updated_at: string; evidence: string | null }>

  for (const s of strategies) {
    const days = daysSince(s.updated_at)
    let temp = 25
    let reason = 'active'

    if (days > 14) {
      temp = 60; reason = `no updates in ${Math.round(days)} days`
    } else if (days > 7) {
      temp = 45; reason = `${Math.round(days)} days without evidence update`
    }

    if (!s.evidence || s.evidence === '[]') {
      temp = Math.max(temp, 50); reason += ', no evidence collected'
    }

    items.push({ id: s.id, source: 'strategy', title: s.title, temperature: temp, reason, details: s.description })
  }

  return items
}

function scanTasks(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const tasks = db.prepare(`
    SELECT id, title, status, priority, due_at, created_at
    FROM tasks WHERE assigned_to = 'eddie' AND status IN ('pending', 'in_progress', 'blocked')
    ORDER BY priority ASC
  `).all() as Array<{ id: string; title: string; status: string; priority: number; due_at: string | null; created_at: string }>

  for (const t of tasks) {
    let temp = 30
    let reason = t.status

    if (t.due_at && hoursUntil(t.due_at) < 0) {
      temp = 90; reason = `overdue since ${t.due_at}`
    } else if (t.due_at && hoursUntil(t.due_at) < 24) {
      temp = 80; reason = 'due today'
    }

    const daysOld = daysSince(t.created_at)
    if (t.status === 'pending' && daysOld > 7) {
      temp = Math.max(temp, 65); reason = `pending for ${Math.round(daysOld)} days`
    }

    if (t.status === 'blocked') {
      temp = Math.max(temp, 70); reason = `blocked for ${Math.round(daysOld)} days`
    }

    if (t.priority <= 2) {
      temp = Math.min(100, temp + 15)
    }

    items.push({ id: t.id, source: 'task', title: t.title, temperature: temp, reason, details: `[P${t.priority}] ${t.title} (${t.status})` })
  }

  return items
}

function scanTodos(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const todos = db.prepare(`
    SELECT id, title, priority, due_at, created_at, description
    FROM tasks WHERE assigned_to = 'eddie' AND task_type = 'todo' AND status = 'pending'
    ORDER BY priority ASC
  `).all() as Array<{ id: string; title: string; priority: number; due_at: string | null; created_at: string; description: string | null }>

  for (const t of todos) {
    let temp = 35
    let reason = 'tracking'

    if (t.due_at) {
      const hours = hoursUntil(t.due_at)
      if (hours < 0) {
        temp = 95; reason = `overdue: "${t.title}". You said you'd do this.`
      } else if (hours < 4) {
        temp = 85; reason = `due in ${Math.round(hours)}h`
      } else if (hours < 24) {
        temp = 70; reason = 'due today'
      } else if (hours < 72) {
        temp = 50; reason = `due in ${Math.round(hours / 24)} days`
      }
    } else {
      // Someday todos age slowly
      const days = daysSince(t.created_at)
      if (days > 14) {
        temp = 55; reason = `"someday" todo sitting for ${Math.round(days)} days. Still relevant?`
      } else if (days > 7) {
        temp = 40; reason = `${Math.round(days)} days old`
      }
    }

    items.push({
      id: t.id, source: 'todo', title: t.title,
      temperature: temp, reason,
      details: `${t.title}${t.description ? ' (' + t.description + ')' : ''}`
    })
  }

  return items
}

function scanConversationGaps(db: Database.Database): TrackedItem[] {
  const items: TrackedItem[] = []

  const lastConvo = db.prepare(`
    SELECT created_at FROM milo_conversations WHERE session_id != 'heartbeat' ORDER BY id DESC LIMIT 1
  `).get() as { created_at: string } | undefined

  if (lastConvo) {
    const hours = hoursSince(lastConvo.created_at)
    if (hours > 48) {
      items.push({
        id: 'silence', source: 'conversation', title: 'Extended silence',
        temperature: 40, reason: `${Math.round(hours / 24)} days since last conversation`,
        details: 'No messages in a while.'
      })
    }
  }

  const moods = db.prepare(`
    SELECT mood, energy_level, created_at FROM milo_mood_journal
    ORDER BY created_at DESC LIMIT 5
  `).all() as Array<{ mood: string; energy_level: string; created_at: string }>

  const lowEnergy = moods.filter(m => m.energy_level === 'low').length
  if (lowEnergy >= 3) {
    items.push({
      id: 'energy-pattern', source: 'conversation', title: 'Low energy pattern',
      temperature: 55, reason: `${lowEnergy} of last 5 entries show low energy`,
      details: 'Sustained low energy detected.'
    })
  }

  return items
}

// ============================================================================
// BEAT TIMING
// ============================================================================

type BeatType =
  | 'morning_pulse'      // Daily 9am: set the day, surface todos, accountability
  | 'afternoon_check'    // Daily 2pm: mid-day pulse, HOT/WARM only
  | 'evening_wind'       // Daily 8pm: reflect, what carries forward
  | 'weekly_review'      // Sunday 7pm: week in review, goal check-ins, plan next week
  | 'monthly_retro'      // 1st of month 9am: monthly retrospective, strategy review
  | 'quarterly_planning' // Start of quarter: big picture, goal setting
  | 'event_driven'       // Anytime: fires on HOT items

function getCurrentBeat(): BeatType {
  const now = new Date()
  const hour = now.getHours()
  const day = now.getDay() // 0 = Sunday
  const date = now.getDate()
  const month = now.getMonth()

  // Quarterly: Jan 1, Apr 1, Jul 1, Oct 1
  if (date <= 2 && [0, 3, 6, 9].includes(month) && hour >= 8 && hour < 11) return 'quarterly_planning'

  // Monthly: 1st of month
  if (date === 1 && hour >= 8 && hour < 11) return 'monthly_retro'

  // Weekly: Sunday evening
  if (day === 0 && hour >= 18 && hour < 21) return 'weekly_review'

  // Daily beats
  if (hour >= 8 && hour < 10) return 'morning_pulse'
  if (hour >= 13 && hour < 15) return 'afternoon_check'
  if (hour >= 19 && hour < 21) return 'evening_wind'

  return 'event_driven'
}

// ============================================================================
// STATE PERSISTENCE
// ============================================================================

interface HeartbeatState {
  lastDate: string
  messagesSentToday: number
  beatsFired: string[]
  lastFireTime: string
}

function loadState(): HeartbeatState {
  try {
    const data = fs.readFileSync(HEARTBEAT_STATE, 'utf-8')
    return JSON.parse(data)
  } catch {
    return { lastDate: '', messagesSentToday: 0, beatsFired: [], lastFireTime: '' }
  }
}

function saveState(state: HeartbeatState): void {
  fs.writeFileSync(HEARTBEAT_STATE, JSON.stringify(state, null, 2))
}

function shouldFire(beat: BeatType, hotItems: TrackedItem[], state: HeartbeatState): boolean {
  const today = new Date().toISOString().split('T')[0]

  if (state.lastDate !== today) {
    state.messagesSentToday = 0
    state.lastDate = today
    state.beatsFired = []
  }

  if (state.messagesSentToday >= MAX_DAILY_PROACTIVE) return false

  if (beat !== 'event_driven') {
    if (state.beatsFired.includes(beat)) return false
    return true
  }

  return hotItems.some(i => i.temperature >= 90)
}

// ============================================================================
// MESSAGE COMPOSITION
// ============================================================================

async function composeBeatMessage(beat: BeatType, items: TrackedItem[]): Promise<string> {
  const hot = items.filter(i => i.temperature >= 90)
  const warm = items.filter(i => i.temperature >= 60 && i.temperature < 90)
  const cool = items.filter(i => i.temperature >= 30 && i.temperature < 60)

  let context = `You are proactively reaching out to Eddie on Telegram.\nBeat type: ${beat}\n\n`

  if (hot.length > 0) {
    context += `HOT (needs attention now):\n${hot.map(i => `- [${i.source}] ${i.details} -- ${i.reason}`).join('\n')}\n\n`
  }
  if (warm.length > 0) {
    context += `WARM (needs attention soon):\n${warm.map(i => `- [${i.source}] ${i.details} -- ${i.reason}`).join('\n')}\n\n`
  }
  if (cool.length > 0 && beat !== 'event_driven') {
    context += `COOL (background awareness):\n${cool.slice(0, 5).map(i => `- [${i.source}] ${i.details}`).join('\n')}\n\n`
  }

  const beatInstructions: Record<BeatType, string> = {
    morning_pulse: `Morning pulse. Start Eddie's day right.
- Lead with today's todos and what's HOT
- Mention upcoming events in the next 24h
- If any todos from yesterday are still open, hold Eddie accountable: "You said you'd X yesterday. Still on the list."
- If goals have been stale, note ONE gently
- 4-8 sentences. Energizing, not overwhelming.`,

    afternoon_check: `Afternoon check. Quick mid-day pulse.
- Only surface HOT and WARM items
- If Eddie has today-horizon todos still pending, nudge once
- 2-4 sentences max. Do not lecture, just flag.`,

    evening_wind: `Evening wind-down. Reflective, not pressuring.
- Acknowledge any todos completed today
- Note what carries forward to tomorrow
- If mood/energy data shows a pattern, mention it warmly
- 3-5 sentences. End the day with clarity, not anxiety.`,

    weekly_review: `Weekly review. Sunday evening retrospective.
- Summarize the week: what got done, what didn't, what emerged
- Report on all active goals: progress changes, stale ones, achieved ones
- Surface any "someday" todos that have been sitting too long
- Review strategies: are they still the right play?
- Call out wins explicitly. Eddie needs to see forward motion.
- Set up next week: what should be the focus?
- 10-15 sentences. This is the most substantial beat.`,

    monthly_retro: `Monthly retrospective. First of the month.
- Review all monthly goals: what hit, what missed, what carries
- Strategy effectiveness: which approaches worked?
- Pattern recognition: energy, mood, productivity trends
- Surface any rogue wildcards that became real projects
- Suggest goal adjustments for the new month
- 8-12 sentences. Honest but constructive.`,

    quarterly_planning: `Quarterly planning. Big picture time.
- Review all quarterly goals: progress, relevance, completion
- Which strategies proved out? Which should be abandoned?
- What new themes emerged this quarter?
- Suggest quarterly goals for the new quarter
- Revenue/cashflow status check
- 10-15 sentences. Strategic, forward-looking.`,

    event_driven: 'Urgent surface. Something HOT needs attention. Be direct, no preamble. 1-3 sentences. Just the signal, not the noise.',
  }

  context += beatInstructions[beat]

  // Use deeper consciousness for substantial reviews
  const isSubstantial = ['weekly_review', 'monthly_retro', 'quarterly_planning'].includes(beat)
  const cafPrompt = composeMiloPrompt(isSubstantial ? 'chat' : 'nudge')
  const maxTokens = isSubstantial ? 1024 : 512
  const client = new Anthropic()

  const response = await client.messages.create({
    model: process.env.MILO_CHAT_MODEL || 'claude-sonnet-4-20250514',
    max_tokens: maxTokens,
    system: `${cafPrompt}\n\nYou are sending a proactive message on Telegram. No emoji. Be Milo. Today is ${new Date().toISOString().split('T')[0]}.`,
    messages: [{ role: 'user', content: context }],
  })

  return response.content[0].type === 'text' ? response.content[0].text : ''
}

// ============================================================================
// TELEGRAM SEND
// ============================================================================

function sendTelegram(text: string): void {
  const token = process.env.MILO_TELEGRAM_BOT_TOKEN || ''
  const chatId = process.env.MILO_TELEGRAM_CHAT_ID || ''
  if (!token || !chatId) return

  try {
    execFileSync('curl', [
      '-s', '-X', 'POST',
      `https://api.telegram.org/bot${token}/sendMessage`,
      '--data-urlencode', `text=${text}`,
      '-d', `chat_id=${chatId}`,
    ], { timeout: 10000 })
  } catch { /* best effort */ }
}

// ============================================================================
// MAIN
// ============================================================================

async function main() {
  const state = loadState()
  const beat = getCurrentBeat()

  // Run self-repair first (writable DB) to clean data before scanning
  let repairReport: RepairReport | null = null
  try {
    const writeDb = new Database(DB_PATH, { readonly: false })
    try {
      repairReport = runSelfRepair(writeDb)
      if (repairReport.stats.auto_repaired > 0 || repairReport.stats.flagged > 0) {
        const logLine = `[${new Date().toISOString()}] Self-repair: ${repairReport.stats.auto_repaired} auto-repaired, ${repairReport.stats.flagged} flagged\n`
        fs.appendFileSync(HEARTBEAT_LOG, logLine)
      }
    } finally {
      writeDb.close()
    }
  } catch (repairErr) {
    // Self-repair failure must not block heartbeat
    const logLine = `[${new Date().toISOString()}] Self-repair error (non-blocking): ${(repairErr as Error).message}\n`
    fs.appendFileSync(HEARTBEAT_LOG, logLine)
  }

  // Now scan with clean data
  const db = new Database(DB_PATH, { readonly: true })

  try {
    // Scan all tracked items
    const items: TrackedItem[] = [
      ...scanEvents(db),
      ...scanGoals(db),
      ...scanStrategies(db),
      ...scanTasks(db),
      ...scanTodos(db),
      ...scanConversationGaps(db),
    ]

    // Surface flagged repair items as WARM so Milo can mention them
    if (repairReport) {
      const flaggedItems = repairReport.actions
        .filter(a => a.action === 'flagged_for_review')
        .map(a => ({
          id: String(a.detection.entity_id),
          source: 'repair' as const,
          title: `Data issue: ${a.detection.description}`,
          temperature: 60,
          reason: a.details,
          details: `[${a.detection.entity_type}] ${a.detection.description}`,
        }))
      items.push(...flaggedItems)
    }

    items.sort((a, b) => b.temperature - a.temperature)

    const hot = items.filter(i => i.temperature >= 90)

    if (!shouldFire(beat, hot, state)) {
      const logLine = `[${new Date().toISOString()}] Beat: ${beat}, Items: ${items.length}, Hot: ${hot.length}, Skipped\n`
      fs.appendFileSync(HEARTBEAT_LOG, logLine)
      return
    }

    const message = await composeBeatMessage(beat, items)

    if (message) {
      sendTelegram(message)

      // Save heartbeat message to conversation history
      const writeDb = new Database(DB_PATH, { readonly: false })
      try {
        writeDb.prepare(`
          INSERT INTO milo_conversations (role, content, session_id, token_count)
          VALUES ('assistant', ?, 'heartbeat', ?)
        `).run(message, Math.ceil(message.length / 4))
      } finally {
        writeDb.close()
      }

      state.messagesSentToday++
      if (beat !== 'event_driven') state.beatsFired.push(beat)
      state.lastFireTime = new Date().toISOString()
      saveState(state)

      const logLine = `[${new Date().toISOString()}] FIRED ${beat}: ${hot.length} hot, ${items.length} total. Sent ${message.length} chars.\n`
      fs.appendFileSync(HEARTBEAT_LOG, logLine)
    }
  } finally {
    db.close()
  }
}

main().catch(err => {
  process.stderr.write(`Heartbeat error: ${err.message}\n`)
})
