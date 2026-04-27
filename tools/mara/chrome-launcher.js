#!/usr/bin/env node
/**
 * chrome-launcher.js
 *
 * Launches system Chrome with the debug profile and remote debugging enabled.
 * Playwright tools connect to this via CDP.
 *
 * Usage:
 *   node chrome-launcher.js --start    Start Chrome with debugging on port 9223
 *   node chrome-launcher.js --stop     Kill the Chrome debug instance
 *   node chrome-launcher.js --status   Check if Chrome debug is running
 *
 * Uses port 9223 (not 9222) to avoid conflicts with any existing debug sessions.
 */

import { spawn, execFileSync } from 'child_process';
import { homedir } from 'os';
import { join } from 'path';
import { existsSync, writeFileSync, readFileSync, unlinkSync } from 'fs';
import http from 'http';

const CHROME_BIN = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const CHROME_PROFILE = join(homedir(), 'chrome-debug-profile-homer');
const DEBUG_PORT = 9223;
const PID_FILE = join(homedir(), '.hydra/state/mara-chrome.pid');

const args = process.argv.slice(2);
const command = args[0];

function checkCDP() {
  return new Promise((resolve) => {
    const req = http.get(`http://localhost:${DEBUG_PORT}/json/version`, { timeout: 3000 }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try { JSON.parse(data); resolve(true); } catch { resolve(false); }
      });
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

function isRunning() {
  try {
    const pid = existsSync(PID_FILE) ? readFileSync(PID_FILE, 'utf-8').trim() : null;
    if (!pid) return false;
    process.kill(parseInt(pid), 0);
    return true;
  } catch {
    if (existsSync(PID_FILE)) unlinkSync(PID_FILE);
    return false;
  }
}

function checkPort() {
  try {
    execFileSync('/usr/sbin/lsof', ['-i', `:${DEBUG_PORT}`, '-t'], { encoding: 'utf-8' });
    return true;
  } catch {
    return false;
  }
}

if (command === '--start') {
  if (isRunning()) {
    console.log(JSON.stringify({ status: 'already_running', port: DEBUG_PORT }));
    process.exit(0);
  }

  if (checkPort()) {
    console.error(JSON.stringify({ status: 'port_in_use', port: DEBUG_PORT }));
    process.exit(1);
  }

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

  // Wait for Chrome to be ready
  let ready = false;
  for (let i = 0; i < 20; i++) {
    await new Promise(r => setTimeout(r, 500));
    if (checkPort()) {
      ready = true;
      break;
    }
  }

  if (ready) {
    console.log(JSON.stringify({ status: 'started', pid: child.pid, port: DEBUG_PORT }));
  } else {
    console.error(JSON.stringify({ status: 'failed_to_start', pid: child.pid }));
    process.exit(1);
  }

} else if (command === '--stop') {
  if (!isRunning()) {
    console.log(JSON.stringify({ status: 'not_running' }));
    process.exit(0);
  }

  const pid = readFileSync(PID_FILE, 'utf-8').trim();
  try {
    process.kill(parseInt(pid), 'SIGTERM');
    unlinkSync(PID_FILE);
    console.log(JSON.stringify({ status: 'stopped', pid: parseInt(pid) }));
  } catch (err) {
    console.error(JSON.stringify({ status: 'error', error: err.message }));
    process.exit(1);
  }

} else if (command === '--status') {
  const running = isRunning();
  const portActive = checkPort();
  const cdpAlive = await checkCDP();
  console.log(JSON.stringify({
    status: cdpAlive ? 'running' : (running ? 'stale' : 'stopped'),
    port: DEBUG_PORT,
    portActive,
    cdpAlive,
    pid: existsSync(PID_FILE) ? readFileSync(PID_FILE, 'utf-8').trim() : null,
  }));

} else {
  console.error('Usage: node chrome-launcher.js --start|--stop|--status');
  process.exit(1);
}
