#!/usr/bin/env node
/**
 * mara-post-x.js
 *
 * Posts a single tweet or thread to X via CDP connection to Chrome debug instance.
 * Anti-bot: human-like typing, random pauses, mouse movements.
 *
 * Usage:
 *   node mara-post-x.js --content <file> --screenshot <path> [--mode single|thread] [--dry-run]
 *
 * Output: JSON to stdout { success, error, screenshots[], dryRun }
 */

import { readFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';
import {
  connectChrome, getPage, parseContentFile,
  humanType, sleep, randomDelay,
  getArg as _getArg, hasFlag as _hasFlag,
} from './lib.js';

const args = process.argv.slice(2);
const getArg = (n, d) => _getArg(args, n, d);
const hasFlag = (n) => _hasFlag(args, n);

const contentFile = getArg('content');
const screenshotPath = getArg('screenshot', '/tmp/mara-post-x.png');
const mode = getArg('mode', 'auto');
const dryRun = hasFlag('dry-run');

if (!contentFile) {
  console.error('Usage: node mara-post-x.js --content <file> --screenshot <path> [--mode single|thread] [--dry-run]');
  process.exit(1);
}

const parsed = parseContentFile(readFileSync(contentFile, 'utf-8'));

if (parsed.platform !== 'x') {
  console.error(JSON.stringify({ success: false, error: `Not an X post. Platform: ${parsed.platform}` }));
  process.exit(1);
}
if (parsed.hasPlaceholders) {
  console.error(JSON.stringify({ success: false, error: 'Content has [UPDATE:] placeholders that need filling' }));
  process.exit(1);
}

const effectiveMode = mode === 'auto' ? parsed.postType : mode;
const result = { success: false, error: null, screenshots: [], dryRun };

let browser;
try {
  mkdirSync(dirname(screenshotPath), { recursive: true });
  const conn = await connectChrome();
  browser = conn.browser;
  const page = await getPage(conn.context);

  // Navigate to X home
  await page.goto('https://x.com/home', { waitUntil: 'domcontentloaded', timeout: 20000 });
  await sleep(randomDelay(2000, 4000));

  // Verify logged in
  const isLoggedIn = await page.locator('[data-testid="SideNav_AccountSwitcher_Button"], [data-testid="AppTabBar_Home_Link"]')
    .first().isVisible({ timeout: 8000 }).catch(() => false);

  if (!isLoggedIn) {
    result.error = 'Not logged in to X. Run chrome-launcher.js --stop, then log in manually with headed Chrome.';
    console.log(JSON.stringify(result));
    process.exit(1);
  }

  if (effectiveMode === 'single') {
    // Click compose area
    const textbox = page.locator('[data-testid="tweetTextarea_0"]').first();
    const textboxVisible = await textbox.isVisible({ timeout: 3000 }).catch(() => false);
    if (!textboxVisible) {
      await page.locator('[data-testid="SideNav_NewTweet_Button"], a[href="/compose/post"]').first().click();
      await sleep(randomDelay(1000, 2000));
    }

    await page.locator('[data-testid="tweetTextarea_0"]').first().click();
    await sleep(randomDelay(500, 1000));
    await humanType(page, parsed.body);
    await sleep(randomDelay(1000, 2000));

    // Pre-submit screenshot
    const preShot = screenshotPath.replace('.png', '-pre.png');
    await page.screenshot({ path: preShot, fullPage: false });
    result.screenshots.push(preShot);

    if (dryRun) {
      result.success = true;
      result.error = 'DRY RUN: Post composed but not submitted';
      console.log(JSON.stringify(result));
      process.exit(0);
    }

    // Submit
    await page.locator('[data-testid="tweetButtonInline"], [data-testid="tweetButton"]').first().click();
    await sleep(randomDelay(3000, 5000));
    await page.screenshot({ path: screenshotPath, fullPage: false });
    result.screenshots.push(screenshotPath);

    // Reply (if present, wait 2-5 min)
    if (parsed.reply) {
      await sleep(randomDelay(120000, 300000));
      await page.goto('https://x.com/eddiebe', { waitUntil: 'domcontentloaded', timeout: 15000 });
      await sleep(randomDelay(2000, 3000));
      await page.locator('article[data-testid="tweet"]').first().click();
      await sleep(randomDelay(1500, 2500));
      await page.locator('[data-testid="tweetTextarea_0"]').first().click();
      await sleep(randomDelay(500, 1000));
      await humanType(page, parsed.reply);
      await sleep(randomDelay(1000, 2000));
      await page.locator('[data-testid="tweetButtonInline"], [data-testid="tweetButton"]').first().click();
      await sleep(randomDelay(2000, 3000));
      const replyShot = screenshotPath.replace('.png', '-reply.png');
      await page.screenshot({ path: replyShot, fullPage: false });
      result.screenshots.push(replyShot);
    }

    result.success = true;

  } else if (effectiveMode === 'thread') {
    if (parsed.threadParts.length === 0) {
      result.error = 'No thread parts found';
      console.log(JSON.stringify(result));
      process.exit(1);
    }

    // Post first tweet
    const textbox = page.locator('[data-testid="tweetTextarea_0"]').first();
    if (!(await textbox.isVisible({ timeout: 3000 }).catch(() => false))) {
      await page.locator('[data-testid="SideNav_NewTweet_Button"], a[href="/compose/post"]').first().click();
      await sleep(randomDelay(1000, 2000));
    }
    await page.locator('[data-testid="tweetTextarea_0"]').first().click();
    await sleep(randomDelay(500, 1000));
    await humanType(page, parsed.threadParts[0].body);

    const preShot = screenshotPath.replace('.png', '-thread-1-pre.png');
    await page.screenshot({ path: preShot, fullPage: false });
    result.screenshots.push(preShot);

    if (dryRun) {
      result.success = true;
      result.error = `DRY RUN: Thread tweet 1/${parsed.threadParts.length} composed`;
      console.log(JSON.stringify(result));
      process.exit(0);
    }

    await page.locator('[data-testid="tweetButtonInline"], [data-testid="tweetButton"]').first().click();
    await sleep(randomDelay(3000, 5000));
    const t1Shot = screenshotPath.replace('.png', '-thread-1.png');
    await page.screenshot({ path: t1Shot, fullPage: false });
    result.screenshots.push(t1Shot);

    // Reply chain
    for (let i = 1; i < parsed.threadParts.length; i++) {
      await sleep(randomDelay(30000, 90000)); // 30-90s between tweets

      await page.goto('https://x.com/eddiebe', { waitUntil: 'domcontentloaded', timeout: 15000 });
      await sleep(randomDelay(2000, 3000));
      await page.locator('article[data-testid="tweet"]').first().click();
      await sleep(randomDelay(1500, 2500));

      if (i > 1) {
        await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
        await sleep(randomDelay(1000, 2000));
      }

      await page.locator('[data-testid="tweetTextarea_0"]').first().click();
      await sleep(randomDelay(500, 1000));
      await humanType(page, parsed.threadParts[i].body);
      await sleep(randomDelay(1000, 2000));

      await page.locator('[data-testid="tweetButtonInline"], [data-testid="tweetButton"]').first().click();
      await sleep(randomDelay(3000, 5000));

      const shot = screenshotPath.replace('.png', `-thread-${i + 1}.png`);
      await page.screenshot({ path: shot, fullPage: false });
      result.screenshots.push(shot);
    }

    result.success = true;
  }

  console.log(JSON.stringify(result));
} catch (err) {
  result.error = err.message;
  console.log(JSON.stringify(result));
  process.exit(1);
} finally {
  if (browser) await browser.close().catch(() => {});
}
