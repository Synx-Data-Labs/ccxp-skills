// Types and $.state contract of the ccxp-hud mod (hud/register.tsx). The
// contract must be self-contained, so the shared shapes are defined here and the
// module's files import them from '../types'.

export type Field = 'repo' | 'branch' | 'task' | 'ap' | 'ctx' | 'jobs' | 'ci' | 'rate' | 'cost' | 'lastat' | 'ver' | 'queue'

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
  /** Fill band colour: a name (gray, blue, green, yellow, purple) or `#rrggbb`; default gray. The fill itself is always on. */
  fillColor: string
  /** Show the ccxp-skills version segment (`ccxp 5.0.0`, plus `→ 5.1.0` when newer is released); default true. */
  version: boolean
  /** CI segment source; undefined (the default) hides the segment. */
  ci?: CiConfig
}

/** Rolling-24h and lifetime autopilot progress (`autopilot-state.sh stats`); absent when there is nothing to show. */
export type ApStats = {
  /** The history log has at least one entry; false = only the lifetime average is known. */
  has_history: boolean
  merged_24h: number
  cycles_24h: number
  /** Lifetime merged tasks per 24 h. */
  avg_merged_24h: number
  /** merged_24h against the average (1 decimal). */
  trend: 'up' | 'down' | 'flat'
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
  /** Epoch seconds of the next loop wake (`next_wake_at`); 0 when absent or unparseable. */
  next_wake_at: number
  /** A cycle is running (`busy_since` set and under 3 h old). */
  busy: boolean
  /** Task id the running cycle drives (`current_task`); "" when idle or not recorded. */
  current_task: string
  stats: ApStats | null
}

export type Ledger = {
  running: { job: number; title: string }[]
  lifetime_jobs: number
  /** Parked items; the HUD shows only the count (length). */
  parked: { id: string }[]
  next_job: number
  updated_at: string
}

/** Breakdown of dev/TODO/queue.md; every task is in exactly one bucket, so they sum to `total`. */
export type Queue = {
  total: number
  ready: number
  blocked: number
  decision: number
  external: number
  epic: number
  /** Held by another session; shown only when above 0. */
  claimed: number
}

export type CiState = 'passing' | 'failing' | 'running' | 'unknown'

export type Ci = {
  state: CiState
  /** Epoch seconds the last run was created, 0 when unknown. */
  at: number
}

/** The ccxp-skills plugin version segment; `latest` is set only when strictly newer than `installed`. */
export type PluginVersion = {
  installed: string
  latest: string | null
  /** The plugin's GitHub repo URL from its plugin.json (`https://github.com/<owner>/<repo>`); absent when unknown. */
  url?: string
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
  /** dev/TODO/queue.md breakdown; null when the repo has no queue. */
  queue: Queue | null
  /** Last run of the configured CI workflow (cached by the helper), null when unconfigured or unknown. */
  ci: Ci | null
  /** Installed ccxp-skills version and the newer released one (hud-version.sh), null when off or unknown. */
  plugin: PluginVersion | null
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
