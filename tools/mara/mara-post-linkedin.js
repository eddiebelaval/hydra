#!/usr/bin/env node
/**
 * mara-post-linkedin.js
 *
 * Posts to LinkedIn via CDP connection to Chrome debug instance.
 *
 * Usage:
 *   node mara-post-linkedin.js --content <file> --screenshot <path> [--dry-run]
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
const screenshotPath = getArg('screenshot', '/tmp/mara-post-linkedin.png');
const dryRun = hasFlag('dry-run');

if (!contentFile) {
  console.error('Usage: node mara-post-linkedin.js --content <file> --screenshot <path> [--dry-run]');
  process.exit(1);
}

const parsed = parseContentFile(readFileSync(contentFile, 'utf-8'));

if (parsed.platform !== 'linkedin') {
  console.error(JSON.stringify({ success: false, error: `Not a LinkedIn post. Platform: ${parsed.platform}` }));
  process.exit(1);
}
if (parsed.hasPlaceholders) {
  console.error(JSON.stringify({ success: false, error: 'Content has [UPDATE:] placeholders that need filling' }));
  process.exit(1);
}
if (!parsed.body) {
  console.error(JSON.stringify({ success: false, error: 'No post body found' }));
  process.exit(1);
}

const result = { success: false, error: null, screenshots: [], dryRun };
let browser;

try {
  mkdirSync(dirname(screenshotPath), { recursive: true });
  const conn = await connectChrome();
  browser = conn.browser;
  const page = await getPage(conn.context);

  await page.goto('https://www.linkedin.com/feed/', { waitUntil: 'domcontentloaded', timeout: 20000 });
  await sleep(randomDelay(2000, 4000));

  // Verify logged in
  const isLoggedIn = await page.locator('.feed-shared-update-v2, .share-box-feed-entry__trigger, button:has-text("Start a post")')
    .first().isVisible({ timeout: 8000 }).catch(() => false);

  if (!isLoggedIn) {
    result.error = 'Not logged in to LinkedIn. Log in manually with headed Chrome.';
    await page.screenshot({ path: screenshotPath, fullPage: false });
    result.screenshots.push(screenshotPath);
    console.log(JSON.stringify(result));
    process.exit(1);
  }

  // Click "Start a post"
  await page.locator('button.share-box-feed-entry__trigger, button:has-text("Start a post")').first().click();
  await sleep(randomDelay(1500, 3000));

  // Wait for editor
  const editor = page.locator('.ql-editor[data-placeholder], [role="textbox"][aria-label*="post"], div[role="textbox"], [contenteditable="true"]').first();
  await editor.waitFor({ state: 'visible', timeout: 10000 });
  await editor.click();
  await sleep(randomDelay(500, 1000));

  await humanType(page, parsed.body);
  await sleep(randomDelay(1000, 2000));

  const preShot = screenshotPath.replace('.png', '-pre.png');
  await page.screenshot({ path: preShot, fullPage: false });
  result.screenshots.push(preShot);

  if (dryRun) {
    result.success = true;
    result.error = 'DRY RUN: Post composed but not submitted';
    console.log(JSON.stringify(result));
    process.exit(0);
  }

  // Post
  await page.locator('button.share-actions__primary-action, button:has-text("Post"):not(:has-text("Repost"))').first().click();
  await sleep(randomDelay(3000, 5000));
  await page.screenshot({ path: screenshotPath, fullPage: false });
  result.screenshots.push(screenshotPath);

  // First comment (wait 2-5 min)
  if (parsed.firstComment) {
    await sleep(randomDelay(120000, 300000));
    await page.goto('https://www.linkedin.com/in/eddiebelaval/recent-activity/all/', {
      waitUntil: 'domcontentloaded', timeout: 15000 });
    await sleep(randomDelay(2000, 3000));

    await page.locator('button[aria-label*="Comment"], button:has-text("Comment")').first().click();
    await sleep(randomDelay(1000, 2000));

    const commentBox = page.locator('.comments-comment-texteditor .ql-editor, div[role="textbox"]').first();
    await commentBox.click();
    await sleep(randomDelay(500, 1000));
    await humanType(page, parsed.firstComment);
    await sleep(randomDelay(1000, 2000));

    await page.locator('button.comments-comment-box__submit-button, button[aria-label*="Post comment"]').first().click();
    await sleep(randomDelay(2000, 3000));

    const commentShot = screenshotPath.replace('.png', '-comment.png');
    await page.screenshot({ path: commentShot, fullPage: false });
    result.screenshots.push(commentShot);
  }

  result.success = true;
  console.log(JSON.stringify(result));
} catch (err) {
  result.error = err.message;
  console.log(JSON.stringify(result));
  process.exit(1);
} finally {
  if (browser) await browser.close().catch(() => {});
}
