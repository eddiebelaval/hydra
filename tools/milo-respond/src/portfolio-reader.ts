/**
 * Portfolio Reader (HYDRA side) — reads ~/Development/id8/TODO.md as
 * ground-truth portfolio state so Milo stops fabricating idle-day counts,
 * progress percentages, and check-in claims.
 *
 * This is a parallel, minimal copy of the parser in
 * products/milo/src/lib/todo-portfolio/. Intentionally NOT imported —
 * HYDRA ships standalone and can't cross-project-import from a submodule.
 * If schema changes, update both places.
 */

import { readFileSync, existsSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const PORTFOLIO_PATH = join(homedir(), 'Development/id8/TODO.md');

export type PortfolioState = 'proposed' | 'active' | 'review' | 'done' | 'archived';

export interface PortfolioGoal {
  state: PortfolioState;
  title: string;
  section: string;
  metadata: Record<string, string>;
}

export interface PortfolioSnapshot {
  exists: boolean;
  path: string;
  active: PortfolioGoal[];
  review: PortfolioGoal[];
  proposed: PortfolioGoal[];
  archived: PortfolioGoal[];
}

const STATE_LINE_RE = /^-\s+\[(proposed|active|review|done|archived)\]\s+(.+)$/;
const SECTION_RE = /^##\s+(.+?)\s*$/;
const METADATA_LINE_RE = /^\s{2,}(.+)$/;

function parseMetadata(line: string): Record<string, string> {
  const meta: Record<string, string> = {};
  for (const pair of line.trim().split('|').map(s => s.trim()).filter(Boolean)) {
    const i = pair.indexOf(':');
    if (i === -1) continue;
    const k = pair.slice(0, i).trim();
    const v = pair.slice(i + 1).trim();
    if (k) meta[k] = v;
  }
  return meta;
}

export function hasPortfolioFile(path: string = PORTFOLIO_PATH): boolean {
  return existsSync(path);
}

export function loadPortfolioSnapshot(path: string = PORTFOLIO_PATH): PortfolioSnapshot {
  const empty: PortfolioSnapshot = { exists: false, path, active: [], review: [], proposed: [], archived: [] };
  if (!existsSync(path)) return empty;

  const lines = readFileSync(path, 'utf-8').split('\n');
  const goals: PortfolioGoal[] = [];
  let section = '';
  let seenSection = false;

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const sm = line.match(SECTION_RE);
    if (sm) { section = sm[1]; seenSection = true; i++; continue; }
    if (!seenSection) { i++; continue; }

    const gm = line.match(STATE_LINE_RE);
    if (gm) {
      const state = gm[1] as PortfolioState;
      const title = gm[2].trim();
      const metadata: Record<string, string> = {};
      let j = i + 1;
      while (j < lines.length && METADATA_LINE_RE.test(lines[j]) && !STATE_LINE_RE.test(lines[j]) && !SECTION_RE.test(lines[j])) {
        Object.assign(metadata, parseMetadata(lines[j]));
        j++;
      }
      goals.push({ state, title, section, metadata });
      i = j;
      continue;
    }
    i++;
  }

  return {
    exists: true,
    path,
    active: goals.filter(g => g.state === 'active'),
    review: goals.filter(g => g.state === 'review'),
    proposed: goals.filter(g => g.state === 'proposed'),
    archived: goals.filter(g => g.state === 'archived'),
  };
}

/**
 * Formats the portfolio for injection into Milo's system prompt.
 *
 * CRITICAL: Includes explicit anti-fabrication instructions so the AI
 * doesn't invent idle-day counts, progress percentages, or status claims
 * about goals that aren't in this list.
 */
export function formatPortfolioForPrompt(snap: PortfolioSnapshot | null = null): string {
  const s = snap ?? loadPortfolioSnapshot();
  if (!s.exists) return '';

  const lines: string[] = [];
  lines.push('## Portfolio Goals — Ground Truth from ~/Development/id8/TODO.md');
  lines.push('');
  lines.push('CRITICAL INSTRUCTIONS:');
  lines.push('- These are the ONLY portfolio goals. Do not mention any others.');
  lines.push('- DO NOT fabricate idle-day counts, progress percentages, or "N days since check-in" claims.');
  lines.push('- DO NOT pester about goals in review/proposed/archived state.');
  lines.push('- If `last_touched` is not shown, do not guess when the goal was last worked on.');
  lines.push('- If `blocked_by` is set, acknowledge the blocker — do not nag about progress.');
  lines.push('');

  if (s.active.length === 0) {
    lines.push('No active portfolio goals. Do not invent any.');
  } else {
    lines.push(`### Active goals (${s.active.length})`);
    for (const g of s.active) {
      const parts: string[] = [`**${g.title}**`, `[${g.section}]`];
      const m = g.metadata;
      if (m.priority) parts.push(`priority: ${m.priority}`);
      if (m.timeframe) parts.push(`timeframe: ${m.timeframe}`);
      if (m.last_touched) parts.push(`last_touched: ${m.last_touched}`);
      if (m.stakeholder) parts.push(`stakeholder: ${m.stakeholder}`);
      if (m.blocked_by) parts.push(`blocked_by: ${m.blocked_by}`);
      if (m.next) parts.push(`next: ${m.next}`);
      lines.push('- ' + parts.join(' | '));
    }
  }
  lines.push('');

  if (s.review.length > 0) {
    lines.push(`### Goals pending Eddie's review (${s.review.length}) — DO NOT NAG`);
    for (const g of s.review) {
      lines.push(`- ${g.title} (flag: ${g.metadata.flag ?? 'stale'})`);
    }
    lines.push('');
  }

  if (s.proposed.length > 0) {
    lines.push(`### Proposed goals awaiting approval (${s.proposed.length})`);
    for (const g of s.proposed) {
      lines.push(`- ${g.title} (proposed by ${g.metadata.source ?? 'unknown'})`);
    }
    lines.push('');
  }

  return lines.join('\n');
}
