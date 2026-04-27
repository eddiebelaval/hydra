#!/usr/bin/env node
/**
 * mara-warmup-x.js
 *
 * Pre-post engagement warm-up. Scrolls feed, likes 2-3 posts.
 * Anti-bot: real accounts browse before posting, not cold.
 *
 * Usage: node mara-warmup-x.js --screenshot <path> [--dry-run]
 * Output: JSON { success, liked, error }
 */

import { mkdirSync } from 'fs';
import { dirname } from 'path';
import {
  connectChrome, getPage, sleep, randomDelay,
  getArg as _getArg, hasFlag as _hasFlag,
} from './lib.js';

const args = process.argv.slice(2);
const screenshotPath = _getArg(args, 'screenshot', '/tmp/mara-warmup.png');
const dryRun = _hasFlag(args, 'dry-run');

const result = { success: false, liked: 0, error: null, dryRun };
let browser;

try {
  mkdirSync(dirname(screenshotPath), { recursive: true });
  const conn = await connectChrome();
  browser = conn.browser;
  const page = await getPage(conn.context);

  await page.goto('https://x.com/home', { waitUntil: 'domcontentloaded', timeout: 20000 });
  await sleep(randomDelay(2000, 4000));

  const isLoggedIn = await page.locator('[data-testid="SideNav_AccountSwitcher_Button"]')
    .first().isVisible({ timeout: 8000 }).catch(() => false);

  if (!isLoggedIn) {
    result.error = 'Not logged in to X';
    console.log(JSON.stringify(result));
    process.exit(1);
  }

  // Scroll like a human browsing
  const scrollCount = randomDelay(3, 6);
  for (let i = 0; i < scrollCount; i++) {
    await page.mouse.wheel(0, randomDelay(300, 600));
    await sleep(randomDelay(1500, 4000));
  }

  // Like 2-3 posts
  const targetLikes = randomDelay(2, 3);
  const likeButtons = await page.locator('[data-testid="like"]').all();
  const shuffled = likeButtons.sort(() => Math.random() - 0.5);

  for (const btn of shuffled) {
    if (result.liked >= targetLikes) break;
    const isVisible = await btn.isVisible().catch(() => false);
    if (!isVisible) continue;

    if (!dryRun) {
      await btn.scrollIntoViewIfNeeded().catch(() => {});
      await sleep(randomDelay(500, 1500));
      await btn.click().catch(() => {});
    }
    result.liked++;
    await sleep(randomDelay(2000, 5000));
  }

  // Final scroll
  await page.mouse.wheel(0, randomDelay(200, 400));
  await sleep(randomDelay(1000, 2000));

  await page.screenshot({ path: screenshotPath, fullPage: false });
  result.success = true;
  console.log(JSON.stringify(result));
} catch (err) {
  result.error = err.message;
  console.log(JSON.stringify(result));
  process.exit(1);
} finally {
  if (browser) await browser.close().catch(() => {});
}
