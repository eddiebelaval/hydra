/**
 * TypeScript door to the Hydra LLM gateway (~/.hydra/lib/hydra_llm.py).
 *
 * The gateway picks the lane (subscription claude -p first for batch work,
 * metered API as fallback), meters the call to hydra.db llm_calls, and pauses
 * a capped lane instead of failing every run. Spec: ~/.hydra/docs/LLM-GATEWAY.md
 *
 * Returns '' when the gateway skips (every lane paused or the job is over
 * budget, exit 75): callers treat that the same as "nothing to send".
 */
import { execFileSync } from 'child_process'
import os from 'os'
import path from 'path'

export type GatewayTask = 'decide' | 'summarize' | 'extract' | 'write' | 'chat'
export type GatewayTier = 'small' | 'mid' | 'large'

export interface GatewayOptions {
  system?: string
  task?: GatewayTask
  tier?: GatewayTier
  maxTokens?: number
  timeoutSec?: number
}

const HYDRA_ROOT = process.env.HYDRA_ROOT || path.join(os.homedir(), '.hydra')

export function gatewayComplete(job: string, prompt: string, opts: GatewayOptions = {}): string {
  const timeoutSec = opts.timeoutSec ?? 180
  const args = [
    path.join(HYDRA_ROOT, 'lib', 'hydra_llm.py'),
    '--job', job,
    '--task', opts.task ?? 'write',
    '--tier', opts.tier ?? 'small',
    '--max-tokens', String(opts.maxTokens ?? 1000),
    '--timeout', String(timeoutSec),
  ]
  if (opts.system) args.push('--system', opts.system)
  try {
    return execFileSync('python3', args, {
      input: prompt,
      encoding: 'utf8',
      timeout: (timeoutSec + 30) * 1000,
      stdio: ['pipe', 'pipe', 'inherit'],
      maxBuffer: 10 * 1024 * 1024,
    }).trim()
  } catch (err) {
    const status = (err as { status?: number }).status
    if (status === 75) return ''
    throw err
  }
}
