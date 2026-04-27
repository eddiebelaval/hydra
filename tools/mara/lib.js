/**
 * lib.js — Shared utilities for MARA posting tools.
 *
 * All tools use CDP connection to a running Chrome instance (started by chrome-launcher.js).
 * This avoids Keychain/cookie encryption issues with launchPersistentContext.
 */

import { chromium } from 'playwright';
import { execFileSync, spawn } from 'child_process';
import { homedir } from 'os';
import { join } from 'path';
import { existsSync, readFileSync, writeFileSync, unlinkSync } from 'fs';
import http from 'http';

export const CHROME_BIN = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const CHROME_PROFILE = join(homedir(), 'chrome-debug-profile-homer');
export const DEBUG_PORT = 9223;
export const PID_FILE = join(homedir(), '.hydra/state/mara-chrome.pid');
export const MARA_DIR = join(homedir(), '.hydra/tools/mara');

/**
 * Check if Chrome CDP is actually responding (not just port-bound).
 * Uses direct HTTP to /json/version instead of lsof, which is unreliable under launchd.
 */
export function isChromeResponding() {
  return new Promise((resolve) => {
    const req = http.get(`http://localhost:${DEBUG_PORT}/json/version`, { timeout: 3000 }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          JSON.parse(data);
          resolve(true);
        } catch {
          resolve(false);
        }
      });
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

/**
 * Kill any Chrome process using our debug port.
 */
function killStaleChrome() {
  try {
    const pids = execFileSync('/usr/sbin/lsof', ['-i', `:${DEBUG_PORT}`, '-t'], { encoding: 'utf-8' }).trim();
    if (pids) {
      for (const pid of pids.split('\n')) {
        try { process.kill(Number(pid), 'SIGTERM'); } catch { /* already dead */ }
      }
    }
  } catch { /* nothing on port */ }

  // Also kill by PID file
  if (existsSync(PID_FILE)) {
    try {
      const pid = Number(readFileSync(PID_FILE, 'utf-8').trim());
      process.kill(pid, 'SIGTERM');
    } catch { /* already dead */ }
    try { unlinkSync(PID_FILE); } catch { /* ok */ }
  }
}

function spawnChrome() {
  const child = spawn(CHROME_BIN, [
    `--user-data-dir=${CHROME_PROFILE}`,
    `--remote-debugging-port=${DEBUG_PORT}`,
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=TranslateUI',
    '--disable-blink-features=AutomationControlled',
    '--window-size=1280,900',
    'about:blank',
  ], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  writeFileSync(PID_FILE, String(child.pid));
  return child.pid;
}

/**
 * Ensure Chrome is running and responsive. Kills stale instances, restarts if needed.
 * Returns true if Chrome is ready for CDP connections.
 */
export async function ensureChromeRunning() {
  // Attempt 1: Check if existing Chrome is responsive
  if (await isChromeResponding()) return true;

  // Existing Chrome is dead or unresponsive -- kill and restart
  killStaleChrome();
  await sleep(1000);

  // Attempt 2: Start fresh Chrome
  const pid = spawnChrome();

  // Wait up to 15 seconds for CDP to come alive
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    if (await isChromeResponding()) return true;
  }

  // Attempt 3: One more try -- sometimes Chrome needs the profile lock to clear
  killStaleChrome();
  await sleep(2000);
  spawnChrome();

  for (let i = 0; i < 30; i++) {
    await sleep(500);
    if (await isChromeResponding()) return true;
  }

  return false;
}

/**
 * Connect to running Chrome via CDP. Caller must call browser.close() when done.
 * Note: browser.close() only disconnects, it doesn't kill the Chrome process.
 */
export async function connectChrome() {
  const ready = await ensureChromeRunning();
  if (!ready) throw new Error('Chrome failed to start on port ' + DEBUG_PORT);

  const browser = await chromium.connectOverCDP(`http://localhost:${DEBUG_PORT}`, {
    timeout: 15000,
  });

  const context = browser.contexts()[0];
  if (!context) throw new Error('No browser context found');

  return { browser, context };
}

/**
 * Get a usable page. Reuses existing blank page or creates new one.
 */
export async function getPage(context) {
  const pages = context.pages();
  const blankPage = pages.find(p => p.url() === 'about:blank' || p.url() === 'chrome://newtab/');
  return blankPage || await context.newPage();
}

// ============================================================================
// Anti-bot utilities
// ============================================================================

export function randomDelay(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export function typingDelay() {
  const base = 120;
  const variance = 60;
  const u1 = Math.random();
  const u2 = Math.random();
  const normal = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  return Math.max(50, Math.min(250, Math.floor(base + normal * variance)));
}

export async function humanType(page, text) {
  for (const char of text) {
    await page.keyboard.type(char, { delay: typingDelay() });
    if (Math.random() < 0.05) {
      await sleep(randomDelay(500, 1500));
    }
  }
}

// ============================================================================
// Content parsing
// ============================================================================

export function parseContentFile(content) {
  const platform = (() => {
    // Try explicit "Post to:" metadata line first (old format)
    const m = content.match(/Post to:\s*(.+)/i);
    if (m) {
      const r = m[1].trim().toLowerCase();
      if (r.includes('linkedin')) return 'linkedin';
      if (r.includes('@id8labs') || r.includes('@eddiebe') || r.includes('x.com')) return 'x';
      if (r.includes('substack')) return 'substack';
      return r;
    }
    // Fallback: scan H1 title line for platform markers (new format)
    const h1 = content.match(/^#\s+(.+)/m);
    if (h1) {
      const title = h1[1].toLowerCase();
      if (title.includes('linkedin')) return 'linkedin';
      if (title.includes('x (') || title.includes('@id8labs') || title.includes('@eddiebe')) return 'x';
      if (title.includes('substack')) return 'substack';
    }
    return 'unknown';
  })();

  const timeWindow = (() => {
    const m = content.match(/Time:\s*(.+)/i);
    return m ? m[1].trim() : null;
  })();

  const hasPlaceholders = /\[UPDATE[:\s]/i.test(content);
  const isManualOnly = /\bMANUAL\b/i.test(content) || /\boutreach\b/i.test(content.split('---')[0]);

  const threadParts = [];
  const tweetPattern = /## TWEET (\d+)\/(\d+)[^\n]*\n+([\s\S]*?)(?=\n## TWEET \d|$)/gi;
  let match;
  while ((match = tweetPattern.exec(content)) !== null) {
    threadParts.push({
      number: parseInt(match[1]),
      total: parseInt(match[2]),
      body: match[3].trim().replace(/^-+\s*$/gm, '').trim()
    });
  }

  const isThread = threadParts.length > 0;
  let body = null, reply = null, firstComment = null;

  if (!isThread) {
    const postMatch = content.match(/## POST[^\n]*\n+([\s\S]*?)(?=\n## |$)/i);
    if (postMatch) {
      body = postMatch[1].trim()
        .replace(/^\(copy everything[^)]*\):?\s*/i, '')
        .replace(/^copy everything[^:]*:\s*/i, '')
        .replace(/^-+\s*$/gm, '').trim();
    }
    const replyMatch = content.match(/## REPLY[^\n]*\n+([\s\S]*?)(?=\n## |$)/i);
    if (replyMatch) reply = replyMatch[1].trim().replace(/^-+\s*$/gm, '').trim();
    const commentMatch = content.match(/## FIRST COMMENT[^\n]*\n+([\s\S]*?)(?=\n## |$)/i);
    if (commentMatch) firstComment = commentMatch[1].trim().replace(/^-+\s*$/gm, '').trim();
  }

  return { platform, timeWindow, postType: isThread ? 'thread' : 'single',
    hasPlaceholders, isManualOnly, body, reply, firstComment, threadParts };
}

// ============================================================================
// CLI arg helpers
// ============================================================================

export function getArg(args, name, defaultVal = null) {
  const idx = args.indexOf(`--${name}`);
  if (idx === -1) return defaultVal;
  return args[idx + 1] || defaultVal;
}

export function hasFlag(args, name) {
  return args.includes(`--${name}`);
}
