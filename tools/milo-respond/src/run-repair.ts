#!/usr/bin/env tsx
/**
 * One-shot self-repair runner. Use for manual cleanup or testing.
 * Usage: npx tsx src/run-repair.ts
 */

import Database from 'better-sqlite3'
import { runSelfRepair } from './self-repair.js'

const DB_PATH = process.env.HYDRA_DB || `${process.env.HOME}/.hydra/hydra.db`
const db = new Database(DB_PATH, { readonly: false })

try {
  const report = runSelfRepair(db)

  console.log('Self-Repair Report')
  console.log('==================')
  console.log(`Timestamp: ${report.timestamp}`)
  console.log(`Issues found: ${report.stats.issues_found}`)
  console.log(`Auto-repaired: ${report.stats.auto_repaired}`)
  console.log(`Flagged for review: ${report.stats.flagged}`)

  if (report.actions.filter(a => a.action === 'auto_repaired').length > 0) {
    console.log('\nAuto-repaired:')
    for (const a of report.actions.filter(a => a.action === 'auto_repaired')) {
      console.log(`  [${a.detection.entity_type}] ${a.details}`)
    }
  }

  if (report.actions.filter(a => a.action === 'flagged_for_review').length > 0) {
    console.log('\nFlagged for review:')
    for (const a of report.actions.filter(a => a.action === 'flagged_for_review')) {
      console.log(`  [${a.detection.entity_type}] ${a.details}`)
    }
  }
} finally {
  db.close()
}
