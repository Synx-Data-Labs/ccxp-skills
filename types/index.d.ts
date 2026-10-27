// Types and $.state contract of the ccxp-hud mod (hud/register.tsx). The
// contract must be self-contained, so the shared shapes are defined here and the
// module's files import them from '../types'.

export type Field = 'repo' | 'ap' | 'ctx' | 'branch' | 'task' | 'jobs' | 'rate' | 'cost' | 'lastat'

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
  /** The session cwd the helper ran for ('' when unknown). */
  cwd: string
  /** owner/name (or the folder name when there is no remote); null outside a git repo. */
  repo: string | null
  /** Working-tree root of `cwd`; null outside a git repo. */
  repo_root: string | null
  /** Short commit id when HEAD is detached, else ''. */
  head: string
  /** Changed tracked files (capped at 99); null when unknown or not a repo. */
  dirty: number | null
  /** gh account of the directory (direnv GH_CONFIG_DIR + hosts.yml); null when unknown. */
  gh_account: string | null
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
  /** True for a couple of refreshes after the working repo changed (a `/cd`, or a shell cd). */
  moved: boolean
  /** `$.session.root()` at the last refresh (null when unreadable); the band shows `(root: X)` only when the cwd is outside it. */
  sessionRoot: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'ccxp-skills': { snapshot: Snapshot; config: HudConfig }
  }
}
