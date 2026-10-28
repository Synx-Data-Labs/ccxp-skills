// Types and $.state contract of the ccxp-hud mod (hud/register.tsx). The
// contract must be self-contained, so the shared shapes are defined here and the
// module's files import them from '../types'.

export type Field = 'repo' | 'branch' | 'task' | 'ap' | 'ctx' | 'jobs' | 'ci' | 'rate' | 'cost' | 'lastat'

/** Which CI run the band shows; unset (undefined) means no CI segment. */
export type CiConfig = {
  /** Workflow file name (e.g. `nightly.yml`) or numeric id. Required. */
  workflow: string
  /** Branch to look at; undefined means the repo's default branch. */
  branch?: string
  /** `owner/repo`; undefined means the current repo. */
  repo?: string
}

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
  /** Draw the band as a full-width tinted bar (`/hud fill on`); default false. */
  fill: boolean
  /** CI segment source; undefined (the default) hides the segment. */
  ci?: CiConfig
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

export type CiState = 'passing' | 'failing' | 'running' | 'unknown'

export type Ci = {
  state: CiState
  /** Epoch seconds the last run was created, 0 when unknown. */
  at: number
}

export type HelperData = {
  /** Repository name (origin's last path part, else the folder name); always present. */
  repo: string
  task_id: string
  task_title: string
  branch: string
  worktree: string
  /** The session cwd the helper ran for ('' when unknown). */
  cwd: string
  /** owner/name (or the main worktree's folder name when there is no remote); null outside a git repo. */
  repo_slug: string | null
  /** Working-tree root of `cwd`; null outside a git repo. */
  repo_root: string | null
  /** Short commit id when HEAD is detached, else ''. */
  head: string
  /** Changed tracked files (capped at 99); null when unknown or not a repo. */
  dirty: number | null
  /** gh account of the directory (direnv GH_CONFIG_DIR + hosts.yml, never the token); null when unknown. */
  gh_account: string | null
  autopilot: Autopilot | null
  /** Job ledger (hud/scripts/ledger.sh), null when there is none. */
  ledger: Ledger | null
  /** Last run of the configured CI workflow (cached by the helper), null when unconfigured or unknown. */
  ci: Ci | null
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
    'ccxp-skills': { snapshot: Snapshot; config: HudConfig; details: boolean }
  }
}
