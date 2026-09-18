/**
 * Real-world scanners for Milo's heartbeat.
 *
 * The original heartbeat only scanned its own SQLite tables, which produced
 * fabricated reports whenever Eddie was actually working (because he doesn't
 * route work through Milo's events/tasks/strategies tables). These scanners
 * read the actual artifacts on disk , git activity, FIELD_NOTES, JOURNEY
 * files, portfolio TODO , so the heartbeat reports what really happened.
 */

import { execFileSync } from 'child_process'
import { existsSync, readFileSync, statSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { loadPortfolioSnapshot } from './portfolio-reader.js'

export interface ScanItem {
  id: string
  source: string
  title: string
  temperature: number
  reason: string
  details: string
}

const HOME = homedir()

// Curated list of repos Milo should know about. Anything not on this list
// will be invisible to the heartbeat. Keep it tight; expand when a repo
// becomes active enough that Eddie wants Milo aware of it.
const TRACKED_REPOS: Array<{ name: string; path: string }> = [
  { name: 'id8', path: join(HOME, 'Development/id8') },
  { name: 'Homer', path: join(HOME, 'Development/Homer') },
  { name: 'mission-control', path: join(HOME, 'Development/mission-control') },
  { name: 'federation-bridge', path: join(HOME, 'Development/federation-bridge') },
  { name: 'mempalace', path: join(HOME, 'Development/mempalace') },
  { name: 'dae-v2', path: join(HOME, 'clawd/projects/dae-v2') },
]

const FIELD_NOTES_PATH = join(HOME, 'Development/id8/FIELD_NOTES.md')

// Files Milo can tail for project narratives. Same shape as repos but the
// path points at the JOURNEY.md itself (or any other narrative log file).
const TRACKED_JOURNEYS: Array<{ name: string; path: string }> = [
  { name: 'id8', path: join(HOME, 'Development/id8/JOURNEY.md') },
  { name: 'dae-v2', path: join(HOME, 'clawd/projects/dae-v2/JOURNEY.md') },
]

const AUTO_JOURNAL_PENDING = join(HOME, '.claude/auto-journal/pending.jsonl')

// -- Git activity --

interface GitCommit {
  hash: string
  subject: string
  iso: string
}

// Display window for commit SUBJECTS. This is a rendering cap, not a count:
// readGitCommits returns at most this many lines so the details block stays
// short. The reported commit COUNT comes from readCommitCount (rev-list),
// never from this window's length , see the 2026-09-18 "always 15" trust bug.
const COMMIT_WINDOW = 15

function hasGitDir(repoPath: string): boolean {
  // Covers both a real .git directory and a worktree's .git file.
  return existsSync(join(repoPath, '.git')) || existsSync(join(repoPath, '.git/HEAD'))
}

/**
 * TRUE commit count in the window, independent of the display cap.
 * Returns -1 on failure so the caller can distinguish "no commits" (0) from
 * "could not count" and fall back deliberately rather than silently.
 */
function readCommitCount(repoPath: string, sinceHours: number): number {
  if (!hasGitDir(repoPath)) return -1
  try {
    const out = execFileSync(
      'git',
      [
        '-C', repoPath,
        'rev-list',
        '--count',
        '--all',
        `--since=${sinceHours} hours ago`,
      ],
      { encoding: 'utf-8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] },
    )
    const n = parseInt(out.trim(), 10)
    return Number.isFinite(n) ? n : -1
  } catch {
    return -1
  }
}

function readGitCommits(repoPath: string, sinceHours: number): GitCommit[] {
  if (!hasGitDir(repoPath)) {
    return []
  }
  try {
    const out = execFileSync(
      'git',
      [
        '-C', repoPath,
        'log',
        '--all',
        `--since=${sinceHours} hours ago`,
        '--pretty=format:%h%x09%cI%x09%s',
        `--max-count=${COMMIT_WINDOW}`,
      ],
      { encoding: 'utf-8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] },
    )
    if (!out.trim()) return []
    return out
      .trim()
      .split('\n')
      .map(line => {
        const [hash, iso, ...rest] = line.split('\t')
        return { hash, iso, subject: rest.join('\t') }
      })
      .filter(c => c.hash && c.subject)
  } catch {
    return []
  }
}

/**
 * Scan all tracked repos for recent commit activity.
 * Each repo with commits in the window emits a single ScanItem listing
 * commit subjects. Temperature reflects density of activity , busy repos
 * surface higher so the model gives them weight.
 */
export function scanGitActivity(sinceHours: number = 24): ScanItem[] {
  const items: ScanItem[] = []

  for (const repo of TRACKED_REPOS) {
    if (!existsSync(repo.path)) continue
    const commits = readGitCommits(repo.path, sinceHours)
    if (commits.length === 0) continue

    // Reported count is the REAL count (rev-list), not the display window's
    // length. Fall back to the window length only if rev-list failed (-1).
    const trueCount = readCommitCount(repo.path, sinceHours)
    const count = trueCount >= 0 ? trueCount : commits.length

    // Recurrence guard for the 2026-09-18 "always 15" bug: the only way the
    // count can now equal the window cap is a legit exactly-N repo OR a
    // rev-list failure that dropped us back onto the capped length. Warn only
    // in the failure case, where the number is genuinely untrustworthy.
    if (trueCount < 0 && commits.length === COMMIT_WINDOW) {
      console.error(
        `[real-scans] WARN: rev-list failed for ${repo.name}; commit count fell ` +
        `back to the capped display window (${COMMIT_WINDOW}) and is likely truncated`,
      )
    }

    const lines = commits.slice(0, 8).map(c => `  - ${c.subject}`).join('\n')
    let temp = 30
    if (count >= 5) temp = 55
    if (count >= 10) temp = 65

    items.push({
      id: `git:${repo.name}`,
      source: 'git',
      title: `${repo.name} commits (${count} in ${sinceHours}h)`,
      temperature: temp,
      reason: `${count} commits in last ${sinceHours}h`,
      details: `${repo.name} (${count} commits, last ${sinceHours}h):\n${lines}`,
    })
  }

  return items
}

// -- FIELD_NOTES tail --

function tailLines(path: string, maxLines: number): string[] {
  if (!existsSync(path)) return []
  try {
    const content = readFileSync(path, 'utf-8')
    const lines = content.split('\n').filter(l => l.trim().length > 0)
    return lines.slice(-maxLines)
  } catch {
    return []
  }
}

export function scanFieldNotes(maxLines: number = 8): ScanItem[] {
  const lines = tailLines(FIELD_NOTES_PATH, maxLines)
  if (lines.length === 0) return []

  return [{
    id: 'fieldnotes:tail',
    source: 'fieldnotes',
    title: 'FIELD_NOTES (recent)',
    temperature: 40,
    reason: `last ${lines.length} entries`,
    details: `Recent FIELD_NOTES entries (id8/FIELD_NOTES.md):\n${lines.map(l => `  ${l}`).join('\n')}`,
  }]
}

// -- JOURNEY tails --

export function scanJourneys(maxLinesPer: number = 5): ScanItem[] {
  const items: ScanItem[] = []

  for (const j of TRACKED_JOURNEYS) {
    const lines = tailLines(j.path, maxLinesPer)
    if (lines.length === 0) continue

    items.push({
      id: `journey:${j.name}`,
      source: 'journey',
      title: `${j.name} JOURNEY (recent)`,
      temperature: 35,
      reason: `last ${lines.length} entries`,
      details: `${j.name} JOURNEY recent:\n${lines.map(l => `  ${l}`).join('\n')}`,
    })
  }

  return items
}

// -- Auto-journal pending (events the capture hook flagged but reconciler hasn't drained) --

export function scanAutoJournalPending(): ScanItem[] {
  if (!existsSync(AUTO_JOURNAL_PENDING)) return []
  try {
    const stat = statSync(AUTO_JOURNAL_PENDING)
    if (stat.size === 0) return []

    const content = readFileSync(AUTO_JOURNAL_PENDING, 'utf-8').trim()
    if (!content) return []

    const lines = content.split('\n').slice(-10)
    const subjects: string[] = []
    for (const line of lines) {
      try {
        const parsed = JSON.parse(line)
        const subject = parsed.summary || parsed.text || parsed.title || parsed.message
        if (subject) subjects.push(String(subject).slice(0, 200))
      } catch {
        // tolerate malformed lines
      }
    }
    if (subjects.length === 0) return []

    return [{
      id: 'autojournal:pending',
      source: 'autojournal',
      title: 'auto-journal pending',
      temperature: 45,
      reason: `${subjects.length} unreconciled events`,
      details: `Auto-journal capture hook flagged these events (not yet distilled):\n${subjects.map(s => `  - ${s}`).join('\n')}`,
    }]
  } catch {
    return []
  }
}

// -- Portfolio (TODO.md) --

/**
 * Emit portfolio active goals as ScanItems. Replaces the short-circuited
 * scanGoals() in heartbeat.ts so the model has the actual portfolio in
 * front of it instead of guessing.
 */
export function scanPortfolioGoals(): ScanItem[] {
  const snap = loadPortfolioSnapshot()
  if (!snap.exists || snap.active.length === 0) return []

  const items: ScanItem[] = []
  for (const g of snap.active) {
    const m = g.metadata
    const parts: string[] = [`[${g.section}] ${g.title}`]
    if (m.priority) parts.push(`priority=${m.priority}`)
    if (m.timeframe) parts.push(`timeframe=${m.timeframe}`)
    if (m.last_touched) parts.push(`last_touched=${m.last_touched}`)
    if (m.blocked_by) parts.push(`blocked_by=${m.blocked_by}`)
    if (m.next) parts.push(`next=${m.next}`)

    let temp = 40
    if (m.priority === 'tier-1') temp = 60
    if (m.blocked_by) temp = Math.max(30, temp - 15)

    items.push({
      id: `portfolio:${g.section}:${g.title}`.slice(0, 100),
      source: 'portfolio',
      title: g.title,
      temperature: temp,
      reason: m.priority || 'active',
      details: parts.join(' | '),
    })
  }
  return items
}
