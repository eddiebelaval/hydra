#!/usr/bin/env node
/**
 * mara-parse-content.js
 *
 * Parses ready-to-post markdown files into structured JSON.
 * Handles three formats: single post, LinkedIn (with first comment), and thread.
 *
 * Usage: node mara-parse-content.js --file <path>
 * Output: JSON to stdout
 */

import { readFileSync } from 'fs';
import { basename } from 'path';

const args = process.argv.slice(2);
const fileIdx = args.indexOf('--file');
if (fileIdx === -1 || !args[fileIdx + 1]) {
  console.error('Usage: node mara-parse-content.js --file <path>');
  process.exit(1);
}

const filePath = args[fileIdx + 1];
const content = readFileSync(filePath, 'utf-8');
const filename = basename(filePath);

function parsePlatform(text) {
  // Try explicit "Post to:" metadata line first (old format)
  const match = text.match(/Post to:\s*(.+)/i);
  if (match) {
    const raw = match[1].trim().toLowerCase();
    if (raw.includes('linkedin')) return 'linkedin';
    if (raw.includes('@id8labs') || raw.includes('@eddiebe') || raw.includes('x.com')) return 'x';
    if (raw.includes('substack')) return 'substack';
    return raw;
  }
  // Fallback: scan H1 title line for platform markers (new format)
  const h1 = text.match(/^#\s+(.+)/m);
  if (h1) {
    const title = h1[1].toLowerCase();
    if (title.includes('linkedin')) return 'linkedin';
    if (title.includes('x (') || title.includes('@id8labs') || title.includes('@eddiebe')) return 'x';
    if (title.includes('substack')) return 'substack';
  }
  return 'unknown';
}

function parseTimeWindow(text) {
  const match = text.match(/Time:\s*(.+)/i);
  return match ? match[1].trim() : null;
}

function hasPlaceholders(text) {
  return /\[UPDATE[:\s]/i.test(text);
}

function isManualOnly(text) {
  return /\bMANUAL\b/i.test(text) || /\boutreach\b/i.test(text.split('---')[0]);
}

function extractSection(text, header) {
  const pattern = new RegExp(`## ${header}[^\\n]*\\n+([\\s\\S]*?)(?=\\n## |$)`, 'i');
  const match = text.match(pattern);
  if (!match) return null;
  return match[1].trim().replace(/^-+\s*$/gm, '').trim() || null;
}

function parseThreadParts(text) {
  const parts = [];
  const tweetPattern = /## TWEET (\d+)\/(\d+)[^\n]*\n+([\s\S]*?)(?=\n## TWEET \d|$)/gi;
  let match;
  while ((match = tweetPattern.exec(text)) !== null) {
    parts.push({
      number: parseInt(match[1]),
      total: parseInt(match[2]),
      body: match[3].trim().replace(/^-+\s*$/gm, '').trim()
    });
  }
  return parts;
}

function detectPostType(text) {
  if (/## TWEET \d+\/\d+/i.test(text)) return 'thread';
  return 'single';
}

// Parse
const platform = parsePlatform(content);
const timeWindow = parseTimeWindow(content);
const postType = detectPostType(content);
const placeholders = hasPlaceholders(content);
const manual = isManualOnly(content);

const result = {
  filename,
  platform,
  timeWindow,
  postType,
  hasPlaceholders: placeholders,
  isManualOnly: manual,
  body: null,
  reply: null,
  firstComment: null,
  threadParts: [],
};

if (postType === 'thread') {
  result.threadParts = parseThreadParts(content);
} else {
  // Single post: extract POST body
  const postBody = extractSection(content, 'POST');
  if (postBody) {
    // Strip the "copy everything below this line" instruction
    result.body = postBody
      .replace(/^\(copy everything[^)]*\):?\s*/i, '')
      .replace(/^copy everything[^:]*:\s*/i, '')
      .trim();
  }

  // Check for reply or first comment
  result.reply = extractSection(content, 'REPLY');
  result.firstComment = extractSection(content, 'FIRST COMMENT');
}

console.log(JSON.stringify(result, null, 2));
