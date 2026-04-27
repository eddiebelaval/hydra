#!/usr/bin/env node
/**
 * mara-check-login.js
 *
 * Checks if Chrome debug profile is logged into a given platform via CDP.
 * Exit 0 = logged in, Exit 1 = logged out or error.
 *
 * Usage: node mara-check-login.js --platform x|linkedin
 */

import {
  connectChrome, getPage, sleep,
  getArg as _getArg,
} from './lib.js';

const args = process.argv.slice(2);
const platform = _getArg(args, 'platform');

if (!platform) {
  console.error('Usage: node mara-check-login.js --platform x|linkedin');
  process.exit(1);
}

const CHECKS = {
  x: {
    url: 'https://x.com/home',
    loggedIn: '[data-testid="SideNav_AccountSwitcher_Button"], [data-testid="AppTabBar_Home_Link"]',
    loggedOut: '[data-testid="loginButton"], [href="/login"], a[href="/i/flow/login"]',
  },
  linkedin: {
    url: 'https://www.linkedin.com/feed/',
    loggedIn: '.feed-shared-update-v2, .share-box-feed-entry__trigger, button:has-text("Start a post")',
    loggedOut: '.sign-in-form, [data-tracking-control-name="guest_homepage-basic_sign-in-button"]',
  },
};

const check = CHECKS[platform];
if (!check) {
  console.error(`Unknown platform: ${platform}. Use: x, linkedin`);
  process.exit(1);
}

let browser;
try {
  const conn = await connectChrome();
  browser = conn.browser;
  const page = await getPage(conn.context);

  await page.goto(check.url, { waitUntil: 'domcontentloaded', timeout: 15000 });
  await sleep(3000);

  const loggedIn = await page.locator(check.loggedIn).first().isVisible({ timeout: 5000 }).catch(() => false);
  if (loggedIn) {
    console.log(JSON.stringify({ platform, status: 'logged_in' }));
    process.exit(0);
  }

  const loggedOut = await page.locator(check.loggedOut).first().isVisible({ timeout: 3000 }).catch(() => false);
  if (loggedOut) {
    console.log(JSON.stringify({ platform, status: 'logged_out' }));
    process.exit(1);
  }

  console.log(JSON.stringify({ platform, status: 'unknown', note: 'Could not determine login state' }));
  process.exit(1);
} catch (err) {
  console.error(JSON.stringify({ platform, status: 'error', error: err.message }));
  process.exit(1);
} finally {
  if (browser) await browser.close().catch(() => {});
}
