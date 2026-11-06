// Types and $.state contract of the ccxp-hud mod (hud/register.tsx). The
// contract must be self-contained, so the shared shapes are defined here and the
// module's files import them from '../types'.

export type Field = 'repo' | 'branch' | 'task' | 'ap' | 'ctx' | 'jobs' | 'ci' | 'rate' | 'cost' | 'lastat' | 'ver' | 'queue' | 'nightly'

/** Which CI run the band shows; unset (undefined) means no CI segment. */
export type CiConfig = {
  /** Workflow file name (e.g. `nightly.yml`) or numeric id. Required. */
  workflow: string
  /** Branch to look at; undefined means the repo's default branch. */
  branch?: string
  /** `owner/repo`; undefined means the current repo. */
  repo?: string
}

/** Where the queue cell reads dev/TODO from: this clone's working tree (default) or the repo's default branch on origin (git object reads, no checkout). */
export type QueueSource = 'working-tree' | 'default-branch'

export type QueueConfig = {
  source: QueueSource
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
  /** Queue cell source; undefined means `{ source: 'working-tree' }` (the original behaviour). A project file's value replaces the user file's. */
  queue?: QueueConfig
}

/** Rolling-24h and lifetime autopilot progress (`autopilot-state.sh stats`); absent when there is nothing to show. */
export type ApStats = {
  /** The history log has at least one entry. */
  has_history: boolean
  /** merged_24h/cycles_24h are an estimate from the state's calendar-day counters (the log does not cover the whole window; can be too high or too low); false = exact. No trend arrow is drawn for an estimate. */
  approx: boolean
  merged_24h: number
  cycles_24h: number
  /** Lifetime merged tasks per 24 h. */
  avg_merged_24h: number
  /** merged_24h against the average at one decimal: up = better (green arrow), down = slower (red arrow), flat = same (no arrow). */
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

/** Jobs started in the rolling last 24 h against the lifetime average per day (`ledger.sh stats`); absent when the ledger has never counted a job. */
export type JobStats = {
  /** jobs_24h may be too low (the start log does not cover the whole window yet); false = exact. No trend arrow is drawn for it. */
  approx: boolean
  /** The average rests on an estimated first-job time (the log was seeded from the lifetime counter). */
  avg_approx: boolean
  jobs_24h: number
  /** Lifetime jobs per day. */
  avg_jobs_day: number
  /** jobs_24h against the average at one decimal: up = busier (green arrow), down = quieter (red arrow), flat = same (no arrow). */
  trend: 'up' | 'down' | 'flat'
}

export type Ledger = {
  running: { job: number; title: string; flags: string }[]
  lifetime_jobs: number
  stats: JobStats | null
  /** Parked items; the HUD shows only the count (length). */
  parked: { id: string }[]
  next_job: number
  updated_at: string
}

/**
 * Breakdown of dev/TODO/queue.md; every task is in exactly one of ready|held|epic|claimed, so those sum to `total`.
 * `held` = a status the HUD counts as not takeable (Blocked by an open task, BLOCKED, SUPERVISED, needs manual, sign-off); auto-pick's own gate is slightly wider.
 * `revisited` and `autoparked` come from the autopilot state, not from the tasks.
 */
export type Queue = {
  total: number
  ready: number
  held: number
  epic: number
  /** Held by another session; shown only when above 0. */
  claimed: number
  /** Queued tasks the autopilot visited without progress; shown only when above 0. */
  revisited: number
  /** Tasks the autopilot parked since this run started; shown only when above 0. */
  autoparked: number
  /** Set when the queue was read from origin/<branch> (queue.source `default-branch`): the cell then reads `queue@<branch>`. */
  branch?: string
  /** `default-branch` was asked for but origin/<default> was unavailable, so the working tree was read; the cell reads `queue@wt`. */
  fallback?: boolean
  /** High watermark of the queue length (hud-queue-hwm.sh); absent when unknown. Always d180 >= d30 >= d7 >= total (last 180 / 30 / 7 days). */
  hwm?: QueueHwm
}

/** The largest queue length seen over the last 180 days, the last 30 days and the last 7 days. */
export type QueueHwm = { d180: number; d30: number; d7: number }

/** SynxDB nightly (hud-nightly.sh): red and green days in the last 30 UTC days, and the last 7 days as a strip. */
export type Nightly = {
  /** Days in the last 30 on which some nightly run failed or timed out. */
  red: number
  /** Days in the last 30 on which every counted nightly run succeeded; absent in a cache written before the green count existed. */
  green?: number
  /** Last 7 UTC days, oldest to newest: `+` green day (every run succeeded), `-` red day, `.` no completed run. */
  strip: string
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
  /** Nightly last-7-days strip and 30-day green and red day counts (cached by the helper), null when unknown. */
  nightly: Nightly | null
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
  /** Epoch seconds when the 5-hour window resets, or null when the engine does not say. */
  rateResetsAt: number | null
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
