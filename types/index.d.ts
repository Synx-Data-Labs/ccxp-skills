// Types and $.state contract of the ccxp-hud mod (hud/register.tsx). The
// contract must be self-contained, so the shared shapes are defined here and the
// module's files import them from '../types'.

export type Field = 'ap' | 'ctx' | 'branch' | 'task' | 'jobs' | 'rate' | 'cost' | 'lastat'

export type HudConfig = {
  enabled: boolean
  userMessage: boolean
  band: boolean
  userBorder: string
  userColor: string
  fields: Field[]
  pollSeconds: number
  ctxWarn: number
  ctxCrit: number
}

export type Autopilot = {
  status: string
  prefix: string
  elapsed_hr: number
  requested_hr: number
  stuck: number
  cycle: number
  last_outcome: string
  last_task: string
  stuck_reason: string
  stop_reason: string
  /** Tasks merged this run; 0 for state files written before the field existed. */
  merged: number
}

export type Ledger = {
  running: { job: number; title: string }[]
  lifetime_jobs: number
  parked: number
  parked_ids: string[]
  next_job: number
  updated_at: string
}

export type HelperData = {
  task_id: string
  task_title: string
  branch: string
  worktree: string
  autopilot: Autopilot | null
  /** Job ledger (hud/scripts/ledger.sh), null when there is none. */
  ledger: Ledger | null
  /** Epoch seconds of the session's last submitted prompt, 0 when unknown. */
  last_input_at: number
}

export type Jobs = { running: number; waiting: number; failed: number }

export type Snapshot = {
  helper: HelperData | null
  /** Context left, 0-100, or null before the first reading. */
  ctxLeft: number | null
  rateUsed: number | null
  costUsd: number | null
  jobs: Jobs
  /** True when the last helper run failed: the helper part is the previous one. */
  stale: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'ccxp-skills': { snapshot: Snapshot; config: HudConfig }
  }
}
