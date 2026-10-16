/**
 * The model ID ~/.hydra/config/llm.json maps a tier to. The router's chat tool
 * loop and classifier reach the API themselves, so they look the ID up here
 * instead of hard-coding it (phase 5, docs/LLM-GATEWAY.md).
 */
import { readFileSync } from 'fs'
import os from 'os'
import path from 'path'

const HYDRA_ROOT = process.env.HYDRA_ROOT || path.join(os.homedir(), '.hydra')

export function modelFor(tier: 'small' | 'mid' | 'large' = 'small', lane: 'api' | 'sub' = 'api'): string {
  const cfg = JSON.parse(readFileSync(path.join(HYDRA_ROOT, 'config', 'llm.json'), 'utf8'))
  return (cfg.tiers[tier] ?? cfg.tiers.small)[lane]
}
