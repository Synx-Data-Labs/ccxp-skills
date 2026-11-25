// ccxp-hud model: pure snapshot + band layout. No `$`, so it is unit-testable.

import type { ApConfig, ApStats, Behind, Bus, Autopilot, Ci, CiState, Field, HelperData, HudConfig, JobStats, Jobs, Issues, Ledger, Nightly, PluginVersion, Queue, QueueMax, Snapshot } from '../types'

export type { Autopilot, Ci, HelperData, Jobs, Snapshot }

export const EMPTY: Snapshot = {
  helper: null,
  ctxLeft: null,
  rateUsed: null,
  rateResetsAt: null,
  rate7Used: null,
  rate7ResetsAt: null,
  jobs: { running: 0, waiting: 0, failed: 0 },
  stale: false,
  moved: false,
  sessionRoot: null,
}

/** The plugin's public GitHub location, drawn in details when the manifest has none (a bare URL: terminals make it clickable). */
export const PLUGIN_URL_DEFAULT = 'https://github.com/Synx-Data-Labs/ccxp-skills'
// Keep in sync with hvr-url in hud/scripts/hud-version.sh. Untrusted: only a plain github.com/<owner>/<repo> URL is ever drawn (no escape bytes, spaces or paths).
const PLUGIN_URL_RE = /^https:\/\/github\.com\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,59}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/
const VERSION_RE = /^\d{1,9}\.\d{1,9}\.\d{1,9}(-[0-9A-Za-z.-]{1,40})?$/

/** Strictly newer by numeric semver (10 > 9, not a string compare); a prerelease sorts below its release. */
export function isNewer(a: string, b: string): boolean {
  if (!VERSION_RE.test(a) || !VERSION_RE.test(b)) return false
  const [ca = '', pa] = a.split('-', 2)
  const [cb = '', pb] = b.split('-', 2)
  const na = ca.split('.').map(Number)
  const nb = cb.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (na[i] !== nb[i]) return na[i]! > nb[i]!
  return pa === undefined && pb !== undefined
}

const CI_STATES: readonly string[] = ['passing', 'failing', 'running', 'unknown']

function str(x: unknown): string {
  return typeof x === 'string' ? x : ''
}

function strOrNull(x: unknown): string | null {
  return typeof x === 'string' && x !== '' ? x : null
}

function num(x: unknown): number {
  return typeof x === 'number' && Number.isFinite(x) ? x : 0
}

/** The helper's autopilot `stats` object; null when absent or malformed. */
function parseStats(x: unknown): ApStats | null {
  if (typeof x !== 'object' || x === null || Array.isArray(x)) return null
  const o = x as Record<string, unknown>
  const trend = o.trend === 'up' || o.trend === 'down' ? o.trend : 'flat'
  return { has_history: o.has_history === true, approx: o.approx === true, merged_24h: num(o.merged_24h), cycles_24h: num(o.cycles_24h), avg_merged_24h: num(o.avg_merged_24h), trend }
}

function parseJobStats(x: unknown): JobStats | null {
  if (typeof x !== 'object' || x === null || Array.isArray(x)) return null
  const o = x as Record<string, unknown>
  const trend = o.trend === 'up' || o.trend === 'down' ? o.trend : 'flat'
  return { approx: o.approx === true, avg_approx: o.avg_approx === true, jobs_24h: Math.max(0, Math.floor(num(o.jobs_24h))), avg_jobs_day: Math.max(0, num(o.avg_jobs_day)), trend }
}

/** Validates the helper's stdout; null on anything unusable (the mod then goes stale). */
export function parseHelper(stdout: string): HelperData | null {
  let raw: unknown
  try {
    raw = JSON.parse(stdout)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const r = raw as Record<string, unknown>
  // "{}" is the helper's own failure answer.
  if (!('branch' in r) && !('task_id' in r)) return null
  const ap = r.autopilot
  let autopilot: Autopilot | null = null
  if (typeof ap === 'object' && ap !== null && !Array.isArray(ap)) {
    const a = ap as Record<string, unknown>
    autopilot = {
      status: str(a.status),
      prefix: str(a.prefix),
      elapsed_hr: num(a.elapsed_hr),
      requested_hr: num(a.requested_hr),
      stuck: num(a.stuck),
      cycle: num(a.cycle),
      last_outcome: str(a.last_outcome),
      last_task: str(a.last_task),
      stuck_reason: str(a.stuck_reason),
      stop_reason: str(a.stop_reason),
      merged: num(a.merged),
      next_wake_at: num(a.next_wake_at),
      busy: a.busy === true,
      current_task: str(a.current_task),
      busy_slots: num(a.busy_slots),
      busy_routine: typeof a.busy_routine === 'number' ? num(a.busy_routine) : num(a.busy_slots), // an older helper has no split: all busy cycles are routine
      stats: parseStats(a.stats),
    }
  }
  const apc = r.ap_config
  let ap_config: ApConfig | null = null
  if (typeof apc === 'object' && apc !== null && !Array.isArray(apc)) {
    const c = apc as Record<string, unknown>
    const whole = (x: unknown) => (typeof x === 'number' && Number.isFinite(x) && x >= 0 ? Math.floor(x) : null)
    const dop = whole(c.max_dop)
    if (dop !== null && dop > 0) ap_config = { max_dop: dop, reserved_slots: whole(c.reserved_slots), source: c.source === 'override' ? 'override' : 'default', file: c.file === true }
  }
  const led = r.ledger
  let ledger: Ledger | null = null
  if (typeof led === 'object' && led !== null && !Array.isArray(led)) {
    const l = led as Record<string, unknown>
    ledger = {
      running: (Array.isArray(l.running) ? l.running : [])
        .filter((x): x is Record<string, unknown> => typeof x === 'object' && x !== null)
        .map(x => ({ job: num(x.job), title: str(x.title), flags: str(x.flags) })),
      lifetime_jobs: num(l.lifetime_jobs),
      stats: parseJobStats(l.stats),
      // v3: array of {id,...}; old files: a count plus parked_ids
      parked: (Array.isArray(l.parked)
        ? l.parked.map(x => (typeof x === 'string' ? x : typeof x === 'object' && x !== null ? (x as Record<string, unknown>).id : null))
        : Array.isArray(l.parked_ids) ? l.parked_ids : [])
        .filter((x): x is string => typeof x === 'string').map(id => ({ id })),
      next_job: num(l.next_job),
      updated_at: str(l.updated_at),
    }
  }
  const qu = r.queue
  let queue: Queue | null = null
  if (typeof qu === 'object' && qu !== null && !Array.isArray(qu)) {
    const q = qu as Record<string, unknown>
    // Counts are clamped to whole non-negative numbers; the buckets are the helper's job to keep summing to total.
    const n = (x: unknown) => Math.max(0, Math.floor(num(x)))
    queue = { total: n(q.total), ready: n(q.ready), blocked: n(q.blocked), epic: n(q.epic), claimed: n(q.claimed), apholds: n(q.apholds) }
    // Untrusted: the branch is only drawn when it is a plain git ref name (the same shape the config accepts for `ci.branch`).
    const branch = str(q.branch)
    if (q.source === 'default-branch' && /^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$/.test(branch)) queue.branch = branch
    else if (q.fallback === true) queue.fallback = true
    // The maxima are three separate windows (not nested): only this week is required (never below the current length); an older window the helper has no data for is null and drawn as `-`.
    const h = q.hwm
    if (typeof h === 'object' && h !== null && !Array.isArray(h)) {
      const hw = h as Record<string, unknown>
      if (typeof hw.tw === 'number' && Number.isFinite(hw.tw)) {
        const old = (x: unknown) => (typeof x === 'number' && Number.isFinite(x) ? n(x) : null)
        queue.hwm = { lm: old(hw.lm), lw: old(hw.lw), tw: Math.max(n(hw.tw), queue.total) }
      }
    }
  }
  const c = r.ci
  let ci: Ci | null = null
  if (typeof c === 'object' && c !== null && !Array.isArray(c)) {
    // Untrusted: only the four known states get through, nothing else is ever drawn.
    const state = str((c as Record<string, unknown>).state)
    if (CI_STATES.includes(state as CiState)) {
      ci = { state: state as CiState, at: num((c as Record<string, unknown>).at) }
      // Untrusted: only an exact GitHub run address of a failing run is kept.
      const u = str((c as Record<string, unknown>).url)
      if (state === 'failing' && /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/actions\/runs\/\d+$/.test(u)) ci.url = u
      const e = (c as Record<string, unknown>).eta
      if (state === 'running' && typeof e === 'object' && e !== null && !Array.isArray(e)) {
        const eo = e as Record<string, unknown>
        const [start, typ, min, max, count] = [eo.start, eo.typ, eo.min, eo.max, eo.n].map(num) as [number, number, number, number, number]
        if (start > 0 && typ > 0 && min > 0 && max >= min && count >= 3) ci.eta = { start, typ, min, max, n: count }
      }
    }
  }
  const ni = r.nightly
  let nightly: Nightly | null = null
  if (typeof ni === 'object' && ni !== null && !Array.isArray(ni)) {
    // Untrusted: whole red and (optional) green counts (0-31) and a 7-character strip of + - . , nothing else is ever drawn.
    const o = ni as Record<string, unknown>
    if (typeof o.red === 'number' && Number.isFinite(o.red) && o.red >= 0 && typeof o.strip === 'string' && /^[-+.]{7}$/.test(o.strip)) {
      const green = typeof o.green === 'number' && Number.isFinite(o.green) && o.green >= 0 ? Math.min(31, Math.floor(o.green)) : undefined
      nightly = { red: Math.min(31, Math.floor(o.red)), ...(green !== undefined ? { green } : {}), strip: o.strip }
    }
  }
  const is = r.issues
  let issues: Issues | null = null
  if (typeof is === 'object' && is !== null && !Array.isArray(is)) {
    // Untrusted: whole non-negative counts only; undelivered is capped at open, the windows are nested (and at least the open count).
    const o = is as Record<string, unknown>
    const cnt = (x: unknown) => Math.max(0, Math.floor(num(x)))
    if (typeof o.open === 'number' && Number.isFinite(o.open) && o.open >= 0 && typeof o.undelivered === 'number' && Number.isFinite(o.undelivered) && o.undelivered >= 0) {
      const open = cnt(o.open)
      issues = { open, undelivered: Math.min(cnt(o.undelivered), open) }
      const h = o.hwm
      if (typeof h === 'object' && h !== null && !Array.isArray(h)) {
        const hw = h as Record<string, unknown>
        if ([hw.d180, hw.d30, hw.d7].every(x => typeof x === 'number' && Number.isFinite(x))) {
          const d7 = Math.max(cnt(hw.d7), open)
          const d30 = Math.max(cnt(hw.d30), d7)
          issues.hwm = { d180: Math.max(cnt(hw.d180), d30), d30, d7 }
        }
      }
    }
  }
  const bs = r.bus
  let bus: Bus | null = null
  if (typeof bs === 'object' && bs !== null && !Array.isArray(bs)) {
    // Untrusted: a positive whole count and a plain agent name (a-z, 0-9, dash); nothing else is ever drawn.
    const o = bs as Record<string, unknown>
    if (typeof o.unread === 'number' && Number.isFinite(o.unread) && o.unread >= 1) bus = { unread: Math.min(Math.floor(o.unread), 999), from: typeof o.from === 'string' && /^[a-z0-9-]{1,32}$/.test(o.from) ? o.from : '' }
  }
  const bh = r.behind
  let behind: Behind | null = null
  if (typeof bh === 'object' && bh !== null && !Array.isArray(bh)) {
    // Untrusted: whole non-negative counts (capped for display), a known base; nothing to show when both are 0.
    const o = bh as Record<string, unknown>
    const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? Math.min(Math.floor(v), 99999) : 0)
    const b = n(o.behind), a = n(o.ahead)
    if (b + a > 0) behind = { behind: b, ahead: a, base: o.base === 'origin' ? 'origin' : 'upstream' }
  }
  const pl = r.plugin
  let plugin: PluginVersion | null = null
  if (typeof pl === 'object' && pl !== null && !Array.isArray(pl)) {
    // Untrusted: only plain X.Y.Z (optional prerelease) strings get through, nothing else is ever drawn.
    const installed = str((pl as Record<string, unknown>).installed)
    const latest = str((pl as Record<string, unknown>).latest)
    const url = str((pl as Record<string, unknown>).url)
    // Untrusted: a positive whole count only (the commit subjects are never read or drawn).
    const un = (pl as Record<string, unknown>).unreleased
    let unreleased: PluginVersion['unreleased']
    if (typeof un === 'object' && un !== null && !Array.isArray(un)) {
      const u = un as Record<string, unknown>
      if (typeof u.count === 'number' && Number.isFinite(u.count) && u.count >= 1) unreleased = { count: Math.min(Math.floor(u.count), 9999) }
    }
    if (VERSION_RE.test(installed)) plugin = { installed, latest: VERSION_RE.test(latest) ? latest : null, ...(PLUGIN_URL_RE.test(url) ? { url } : {}), ...(unreleased ? { unreleased } : {}) }
  }
  return {
    repo: str(r.repo),
    task_id: str(r.task_id),
    task_title: str(r.task_title),
    branch: str(r.branch),
    worktree: str(r.worktree),
    cwd: str(r.cwd),
    repo_slug: strOrNull(r.repo_slug),
    repo_root: strOrNull(r.repo_root),
    head: str(r.head),
    dirty: typeof r.dirty === 'number' && Number.isFinite(r.dirty) ? r.dirty : null,
    gh_account: strOrNull(r.gh_account),
    behind,
    autopilot,
    ap_config,
    ledger,
    queue,
    ci,
    nightly,
    issues,
    bus,
    plugin,
    last_input_at: num(r.last_input_at),
  }
}

/** Counts the session's agents by what the band shows. */
export function countJobs(agents: ReadonlyArray<{ status: string }>): Jobs {
  const jobs = { running: 0, waiting: 0, failed: 0 }
  for (const a of agents) {
    if (a.status === 'running' || a.status === 'pending') jobs.running += 1
    else if (a.status === 'waiting' || a.status === 'idle') jobs.waiting += 1
    else if (a.status === 'failed' || a.status === 'killed') jobs.failed += 1
  }
  return jobs
}

export type Tone = 'success' | 'warning' | 'error'

/**
 * Colour of the context LEFT percentage (register.tsx: ctxLeft = 100 - percent used):
 * green when strictly more than `ctxWarn` (default 75) is left, yellow when strictly more
 * than `ctxCrit` (default 50), red at or below that. So 75 is yellow and 50 is red.
 */
export function ctxTone(left: number, cfg: Pick<HudConfig, 'ctxWarn' | 'ctxCrit'>): Tone {
  if (left > cfg.ctxWarn) return 'success'
  if (left > cfg.ctxCrit) return 'warning'
  return 'error'
}

/** Limit cell colouring by the gap to runout, in minutes (owner decision d166): more than GREEN is green, more than YELLOW up to GREEN is yellow, YELLOW or less is red. */
export const RATE_GAP_GREEN_MIN = 30
export const RATE_GAP_YELLOW_MIN = 10

/** Colour of the limit cell from the seconds until it runs out; null (it will not run out before the reset) is green. */
export function gapTone(gapSec: number | null): Tone {
  if (gapSec === null) return 'success'
  if (gapSec > RATE_GAP_GREEN_MIN * 60) return 'success'
  if (gapSec > RATE_GAP_YELLOW_MIN * 60) return 'warning'
  return 'error'
}

/** Rate-limit window length the engine reports for `five_hour`. */
export const RATE_WINDOW_SEC = 5 * 3600
/** ... and for `seven_day`. */
export const RATE_WINDOW_7D_SEC = 7 * 86400

/**
 * Seconds until a limit window hits 100% at the burn rate so far (used% / elapsed time in the window), or null when it
 * would not run out before the window resets, or when there is too little to go on (no reset time, under 1% used, or
 * under 2 minutes elapsed). `resetsAt` is epoch seconds; `windowSec` is the window length (5 hours by default).
 */
export function rateRunoutSec(used: number, resetsAt: number | null, nowMs: number, windowSec: number = RATE_WINDOW_SEC): number | null {
  if (resetsAt === null) return null
  if (used >= 100 || !(used >= 1)) return null // already at the limit, or too little used to project
  const remaining = resetsAt - nowMs / 1000
  const elapsed = windowSec - remaining
  if (remaining <= 0 || elapsed < 120) return null
  const secToFull = ((100 - used) * elapsed) / used
  return secToFull < remaining ? secToFull : null
}

/** Hours form of `rateRunoutSec`. */
export function rateRunoutHours(used: number, resetsAt: number | null, nowMs: number, windowSec: number = RATE_WINDOW_SEC): number | null {
  const s = rateRunoutSec(used, resetsAt, nowMs, windowSec)
  return s === null ? null : s / 3600
}

/** `1.5h` from an hour or more, `40m` below (never `0m`). */
export function formatRunout(hours: number): string {
  const min = Math.max(1, Math.round(hours * 60))
  if (min >= 60) return `${Math.round(hours * 10) / 10}h`
  return `${min}m`
}

/** Reset time as epoch seconds: accepts seconds, milliseconds or an ISO string; null when absent or unparseable. */
export function resetEpochSec(v: unknown): number | null {
  const n = typeof v === 'string' ? (/^\d+(\.\d+)?$/.test(v) ? Number(v) : Date.parse(v) / 1000) : v
  if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return null
  return n > 1e11 ? n / 1000 : n
}

/** Zones whose short English name is only a GMT offset in ICU but which have an everyday abbreviation. */
const TZ_ABBR: Record<string, string> = { 'Asia/Shanghai': 'CST', 'Asia/Hong_Kong': 'HKT', 'Asia/Tokyo': 'JST', 'Asia/Seoul': 'KST', 'Asia/Singapore': 'SGT', 'Asia/Kolkata': 'IST' }

/**
 * Reset clock time in the local zone with its abbreviation: `13:55 CST`, with the weekday when the reset is not today
 * (`Thu 13:55 CST`). The abbreviation comes from the system timezone (`tz` overrides it, for tests); a zone with no
 * abbreviation shows its offset (`GMT+8`). null when `resetsAt` is not a usable time.
 */
export function formatResetClock(resetsAt: number, nowMs: number, tz?: string): string | null {
  if (!Number.isFinite(resetsAt)) return null
  const zone = tz ?? Intl.DateTimeFormat().resolvedOptions().timeZone
  const at = new Date(resetsAt * 1000)
  const part = (locale: string, o: Intl.DateTimeFormatOptions, d: Date = at) => new Intl.DateTimeFormat(locale, { timeZone: zone, ...o }).format(d)
  const hm = part('en-GB', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
  const abbr = (l: string) => new Intl.DateTimeFormat(l, { timeZone: zone, timeZoneName: 'short' }).formatToParts(at).find(p => p.type === 'timeZoneName')?.value ?? ''
  let name = abbr('en-US')
  if (/^(GMT|UTC)[+-]/.test(name)) name = abbr('en-GB')
  if (/^(GMT|UTC)[+-]/.test(name) && TZ_ABBR[zone]) name = TZ_ABBR[zone]!
  const sameDay = part('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit' }) === part('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit' }, new Date(nowMs))
  return `${sameDay ? '' : `${part('en-US', { weekday: 'short' })} `}${hm}${name ? ` ${name}` : ''}`
}

/** One subscription window as the HUD knows it: percent used and the reset epoch (seconds), either may be unknown. */
export type RateWindow = { label: string; used: number; resetsAt: number | null; sec: number }

/**
 * The windows worth showing: a window with no percent is absent, and so is one whose reset time has passed
 * (the engine drops it then; a stale value would only mislead). 5-hour first, then 7-day.
 */
export function rateWindows(snap: Pick<Snapshot, 'rateUsed' | 'rateResetsAt' | 'rate7Used' | 'rate7ResetsAt'>, nowMs: number): RateWindow[] {
  const out: RateWindow[] = []
  const add = (label: string, used: number | null, resetsAt: number | null, sec: number) => {
    if (used === null || !Number.isFinite(used)) return
    if (resetsAt !== null && resetsAt - nowMs / 1000 <= 0) return
    out.push({ label, used, resetsAt, sec })
  }
  add('5h', snap.rateUsed, snap.rateResetsAt, RATE_WINDOW_SEC)
  add('7d', snap.rate7Used, snap.rate7ResetsAt, RATE_WINDOW_7D_SEC)
  return out
}

const leftOf = (w: RateWindow): number => Math.max(0, 100 - Math.round(w.used))

/** Seconds until a window is spent: 0 when nothing is left, null when it will not run out before its own reset. */
function gapOf(w: RateWindow, nowMs: number): number | null {
  return leftOf(w) <= 0 ? 0 : rateRunoutSec(w.used, w.resetsAt, nowMs, w.sec)
}

/**
 * The window that binds first (owner decision d167, amended): the earliest projected runout that falls before the window's
 * own reset; a window with no runout before its reset ranks last. When none runs out, or on a tie, the one with less % left
 * (the old rule); a full tie keeps the 5-hour window.
 */
export function firstToRunOut(ws: RateWindow[], nowMs: number): { w: RateWindow; gap: number | null } {
  const ranked = ws.map(w => ({ w, gap: gapOf(w, nowMs) }))
  return ranked.reduce((a, b) => {
    const ga = a.gap ?? Infinity
    const gb = b.gap ?? Infinity
    if (gb !== ga) return gb < ga ? b : a
    return leftOf(b.w) < leftOf(a.w) ? b : a
  })
}

/**
 * The limit cell (owner decisions d166, d167): the percent LEFT of the window that runs out first, `runs out in 28m` when
 * the burn rate would run it dry before it resets, and `reset 13:55 CST`, no window label. All of it is coloured by the gap
 * to runout (`gapTone`): no runout before the reset is green, and a spent limit (0 left) is red. The gap is taken in whole
 * minutes, rounded down, so the colour and the text agree (10m20s reads `10m` and is red). `parts` picks the pieces
 * so the narrow forms can drop the reset time first, then the runout. No window: null.
 */
function rateSegs(snap: Snapshot, nowMs: number, parts: { runout: boolean; reset: boolean }): Seg[] | null {
  const ws = rateWindows(snap, nowMs)
  if (ws.length === 0) return null
  const { w, gap: exact } = firstToRunOut(ws, nowMs)
  const left = leftOf(w)
  const gap = exact === null ? null : Math.floor(exact / 60) * 60
  const color = gapTone(gap)
  const segs: Seg[] = [{ text: `${left}% left`, color }]
  if (parts.runout && gap !== null && left > 0) segs.push({ text: ` · runs out in ${formatRunout(gap / 3600)}`, color })
  const clock = parts.reset && w.resetsAt !== null ? formatResetClock(w.resetsAt, nowMs) : null
  if (clock !== null) segs.push({ text: ` · reset ${clock}`, color })
  return segs
}

/** Jobs cell: green READY when nothing runs, yellow WORKING (N) otherwise; `withCount: false` is the narrow form. */
export function jobState(running: number, withCount = true): { text: string; color: Tone } {
  if (running <= 0) return { text: 'READY', color: 'success' }
  return { text: withCount ? `WORKING (${running})` : 'WORKING', color: 'warning' }
}

export function meter(left: number, width = 10): string {
  const filled = Math.max(0, Math.min(width, Math.round((left / 100) * width)))
  return '▓'.repeat(filled) + '░'.repeat(width - filled)
}

/** `alert`: part of a RED CI row (the renderer highlights the whole row); `marker`: the state word, shouted (`FAILING`) when colour is off. */
export type Seg = { text: string; color?: string; dim?: boolean; bold?: boolean; alert?: boolean; marker?: boolean }

/** Timestamp format of the last-input field, in one place: local HH:MM, plus "Mon D" when not today. */
export function formatStamp(epochSec: number, nowMs: number = Date.now()): string {
  const d = new Date(epochSec * 1000)
  const now = new Date(nowMs)
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  if (d.toDateString() === now.toDateString()) return hm
  return `${d.toLocaleString('en-US', { month: 'short' })} ${d.getDate()} ${hm}`
}

export function truncate(text: string, max: number): string {
  if (max <= 0) return ''
  return text.length <= max ? text : text.slice(0, Math.max(1, max - 1)) + '…'
}

/** Layout tier by terminal width: tiny below 70 columns, compact below 100, wide from 100 up. */
export type Tier = 'tiny' | 'compact' | 'wide'
export const TINY_BELOW = 70
export const COMPACT_BELOW = 100

export function tierOf(columns: number): Tier {
  return columns < TINY_BELOW ? 'tiny' : columns < COMPACT_BELOW ? 'compact' : 'wide'
}

/** Cuts at a word boundary (never mid-word unless the first word alone is too long) and adds "…". */
export function truncateWords(text: string, max: number): string {
  if (max <= 0) return ''
  if (text.length <= max) return text
  const head = text.slice(0, Math.max(1, max - 1))
  const cut = head.lastIndexOf(' ')
  const kept = cut >= Math.floor(max / 3) && text[head.length] !== ' ' ? head.slice(0, cut) : head
  return kept.trimEnd() + '…'
}

type Variants = Seg[][]
type Item = { field: string; variants: Variants; at: number }

const joinText = (segs: Seg[]) => segs.map(s => s.text).join('')
const widthOf = (segs: Seg[]) => segs.reduce((n, s) => n + s.text.length, 0)
const SEP = ' │ '
const CI_LOOK: Record<CiState, { glyph: string; word: string; color: string }> = {
  passing: { glyph: '✓', word: 'passing', color: 'success' },
  failing: { glyph: '✗', word: 'failing', color: 'error' },
  running: { glyph: '◐', word: 'running', color: 'warning' },
  unknown: { glyph: '?', word: 'unknown', color: 'inactive' },
}

/** Autopilot counts as ON while working, backing off, idle/capped or paused; off (no record) is OFF. */
export function isApOn(snap: Snapshot): boolean {
  const p = snap.helper?.autopilot?.prefix
  return p === '[r]' || p === '[b]' || p === '[i]' || p === '[p]'
}

/** Last path segment; '' for an empty path. */
export function baseName(path: string): string {
  const parts = path.split('/').filter(p => p !== '')
  return parts.length ? parts[parts.length - 1]! : ''
}

/** True when `cwd` is `root` or below it. */
export function isWithin(cwd: string, root: string): boolean {
  const r = root.replace(/\/+$/, '')
  return cwd === r || cwd.startsWith(r + '/')
}

/** MM-DD of a run, local time. */
function shortDate(epochSec: number): string {
  const d = new Date(epochSec * 1000)
  return `${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** Seconds as a short duration: `45m`, `4h`, `4.5h`. */
function shortDuration(sec: number): string {
  if (Math.round(sec / 60) < 60) return `${Math.max(1, Math.round(sec / 60))}m`
  return `${(Math.round(sec / 360) / 10).toString()}h`
}

const dayStart = (d: Date): number => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()

/** `HH:MM` local, with ` +Nd` when that is not today. */
function clock(epochSec: number, nowMs: number): string {
  const d = new Date(epochSec * 1000)
  const days = Math.round((dayStart(d) - dayStart(new Date(nowMs))) / 86400000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}${days > 0 ? ` +${days}d` : ''}`
}

/**
 * The ETA text of a running run, or '' (not running, no `eta`). Local time.
 * - spread (max - min) <= half the median: one time from the median, `ETA 18:40`, overdue once past it.
 * - wider spread: a range from the fastest to the slowest recent run, `ETA 14:20-19:05` (the first time is never earlier than now), overdue once past the slowest.
 * - overdue: `over usual (4h)`, the median duration, never a negative time.
 */
export function ciEta(ci: Ci, nowMs: number): string {
  const e = ci.eta
  if (ci.state !== 'running' || !e) return ''
  const now = nowMs / 1000
  const wide = e.max - e.min > e.typ / 2
  if (now > e.start + (wide ? e.max : e.typ)) return `over usual (${shortDuration(e.typ)})`
  return wide ? `ETA ${clock(Math.max(e.start + e.min, now), nowMs)}-${clock(e.start + e.max, nowMs)}` : `ETA ${clock(e.start + e.typ, nowMs)}`
}

/** A CI that must be unmissable: failing (also timed out). Yellow and green rows get no extra highlight. */
export const isCiRed = (ci: Ci): boolean => ci.state === 'failing'

/**
 * The CI row, alone on the top line: `CI (workflow) ✗ failing 10-28 (2h ago)`, shrinking to `CI ✗ failing 10-28 (2h ago)`,
 * `CI ✗ 10-28 (2h ago)`, `CI ✗ 10-28`, `CI ✗`. A red row ends with the failed run's address (no scheme, so terminals link it): `... (2h ago) github.com/o/r/actions/runs/1`; the workflow name and the state word go before it, and it drops together with the ETA when nothing else can shrink. Red rows flag every segment `alert` (the renderer draws the row in reverse
 * video, bold) and the state word `marker`.
 */
function ciRowVariants(ci: Ci, workflow: string, nowMs: number): Variants {
  const look = CI_LOOK[ci.state]
  const red = isCiRed(ci)
  const date = ci.at > 0 ? ` ${shortDate(ci.at)}` : ''
  const eta = ciEta(ci, nowMs)
  const mk = (wf: boolean, word: boolean, age: boolean, dateOn: boolean, etaOn = false, urlOn = false): Seg[] => {
    const segs: Seg[] = [
      { text: 'CI ', bold: true },
      ...(wf ? [{ text: `(${truncate(workflow, 30)}) `, dim: true }] : []),
      { text: look.glyph + (word ? ` ${look.word}` : ''), color: look.color, marker: word },
      ...(etaOn && eta ? [{ text: ` ${eta}`, color: look.color }] : []),
      ...(dateOn && date ? [{ text: date, color: look.color }] : []),
      ...(age ? ageSegs(ci.at, nowMs) : []),
      ...(urlOn && red && ci.url ? [{ text: ` ${ci.url.replace(/^https:\/\//, '')}` }] : []),
    ]
    return red ? segs.map(x => ({ ...x, alert: true, bold: true, dim: false })) : segs
  }
  return [mk(true, true, true, true, true, true), mk(false, true, true, true, true, true), mk(false, false, true, true, true, true), mk(false, false, false, true), mk(false, false, false, false)]
}

/**
 * The top CI row, or null (nothing configured or answered, or switched off in `fields`). Starts full at every width.
 * It is the one configured CI workflow only (red or green); other workflows are not shown (owner decision d143).
 */
function ciRow(snap: Snapshot, cfg: HudConfig, width: number, nowMs: number): Seg[] | null {
  const ci = snap.helper?.ci
  if (!cfg.ci || !ci) return null
  return fitRow([{ field: 'ci', variants: ciRowVariants(ci, cfg.ci.workflow, nowMs), at: 0 }], ['step:ci', 'step:ci', 'step:ci', 'step:ci', 'step:ci'], width)
}

/**
 * Latest unknown (or older than installed): `ccxp 5.1.1` (dim). Same as latest: `ccxp 5.1.1 (latest)`, "(latest)" in
 * success, narrowing to `ccxp 5.1.1 ✓`. A newer release: `ccxp 5.1.1 (5.2.0 available)`, the new number in the
 * suggestion colour, narrowing to `ccxp ↑5.2.0` then `↑5.2.0`. "latest" is only said after a successful comparison.
 */
export function versionState(p: PluginVersion): 'available' | 'latest' | 'unknown' {
  if (!p.latest) return 'unknown'
  if (isNewer(p.latest, p.installed)) return 'available'
  return p.latest === p.installed ? 'latest' : 'unknown'
}

function versionVariants(p: PluginVersion): Variants {
  const state = versionState(p)
  if (state === 'unknown') return [[{ text: `ccxp ${p.installed}`, dim: true }]]
  if (state === 'latest') {
    return [
      [{ text: `ccxp ${p.installed} `, dim: true }, { text: '(latest)', color: 'success' }],
      [{ text: `ccxp ${p.installed} `, dim: true }, { text: '✓', color: 'success' }],
    ]
  }
  const up = { text: p.latest as string, color: 'suggestion' }
  return [
    [{ text: `ccxp ${p.installed} (`, dim: true }, up, { text: ' available)', dim: true }],
    [{ text: 'ccxp ↑', dim: true }, up],
    [{ text: '↑', dim: true }, up],
  ]
}

/** The number of commits after the installed release, details only: `3 unreleased` (a count, never the commit subjects). */
function unreleasedVariants(u: NonNullable<PluginVersion['unreleased']>): Variants {
  return [[{ text: `${u.count} unreleased`, color: 'suggestion' }]]
}

function apVariants(ap: Autopilot): Variants {
  const paused = ap.prefix === '[p]'
  // Idle or capped (still on): name the state so a quiet loop is not mistaken for a working one.
  const quiet = ap.prefix === '[i]' ? ap.last_outcome : ''
  const mk = (merged: string, loops: string, pause: string): Seg[] => {
    const segs: Seg[] = [{ text: 'AP ', bold: true }]
    if (pause) segs.push({ text: pause, color: 'warning' }, { text: ' ' })
    if (quiet) segs.push({ text: quiet, color: 'warning' }, { text: ' ' })
    segs.push({ text: ap.requested_hr > 0 ? `${ap.elapsed_hr}/${ap.requested_hr}h` : `${ap.elapsed_hr}h` })
    if (ap.stuck > 0) segs.push({ text: ` ⚠${ap.stuck}`, color: 'error' })
    segs.push({ text: ` ${loops} ` }, { text: merged, color: ap.merged > 0 ? 'success' : undefined, dim: ap.merged === 0 })
    return segs
  }
  return [
    mk(`✓${ap.merged} merged`, `${ap.cycle} loops`, paused ? '⏸ paused' : ''),
    mk(`✓${ap.merged}`, `${ap.cycle} loops`, paused ? '⏸' : ''),
    mk(`✓${ap.merged}`, `${ap.cycle}L`, paused ? '⏸' : ''),
  ]
}

/**
 * How the autopilot's parallelism is used: running cycles (the state's fresh `slots`, helper field `busy_slots`) against
 * the effective `max_dop`. `routine` = the cycles routine picks may fill (max_dop less the reserved slots; all of max_dop
 * while `reserved_slots` is unknown); `capped` = the running ROUTINE cycles (urgent ones run in the reserved slots and are
 * left out) are at or above it, or no slot is physically free (running >= max_dop): the cases where `routine-free` is 0. Null without a config answer.
 */
function dopUse(h: HelperData | null): { max: number; reserved: number | null; routine: number; running: number; capped: boolean } | null {
  const c = h?.ap_config
  if (!c) return null
  const reserved = c.reserved_slots === null ? null : Math.min(c.reserved_slots, Math.max(0, c.max_dop - 1)) // the autopilot keeps at least one routine slot
  const routine = c.max_dop - (reserved ?? 0)
  const running = h?.autopilot?.busy_slots ?? 0
  // Urgent cycles run in the reserved slots: only the others count against the routine limit.
  const routineBusy = Math.min(running, h?.autopilot?.busy_routine ?? running)
  return { max: c.max_dop, reserved, routine, running, capped: running > 0 && (routineBusy >= routine || running >= c.max_dop) }
}

/** Band cell `dop 8/16` (running cycles / max_dop); warning-coloured at the routine limit. One form: it drops whole when the row is tight. */
function dopBandSegs(h: HelperData | null): Seg[] | null {
  const u = dopUse(h)
  return u ? [{ text: `dop ${u.running}/${u.max}`, color: u.capped ? 'warning' : undefined }] : null
}

/**
 * Details cell: `max_dop 16 (14 routine + 2 reserved) · 8 running`; without the reserved key `max_dop 16 · 8 running`.
 * Running above the limit (max_dop lowered under live cycles) says so: `6 running (limit lowered)`. With the autopilot
 * off the cell is just the dim configured value: `max_dop 16`.
 */
function dopDetailSegs(h: HelperData | null): Seg[] | null {
  const u = dopUse(h)
  if (!u) return null
  const on = !!h?.autopilot
  const base = u.reserved === null ? `max_dop ${u.max}` : `max_dop ${u.max} (${u.routine} routine + ${u.reserved} reserved)`
  const segs: Seg[] = [{ text: base, dim: !on }]
  if (on) segs.push({ text: ` · ${u.running} running${u.running > u.max ? ' (limit lowered)' : ''}`, color: u.capped ? 'warning' : undefined })
  return segs
}

/**
 * The autopilot's progress cell, most to least detail:
 * `last 24h: 8 merged ▲ / 26 loops · average 5.2/day`, `24h: 8 merged ▲/26 loops · average 5.2/day`,
 * `24h: ✓8▲/26L average 5.2/d`, then (narrowest only) `24h ✓8▲/26L avg 5.2/d`, `24h ✓8▲`.
 * The arrow sits right after the 24h merged count and compares it with the lifetime average per 24 h:
 * green `▲` above, red `▼` below, NO arrow when equal (both compared at the displayed one decimal, which
 * the helper's `trend` already is), none for an estimate (`~`) and none when the helper reports no trend. The colour is a theme
 * token (`success` / `error`), so under NO_COLOR the glyph stays and only the colour drops.
 * `~8` = the 24h count is an ESTIMATE from the state's calendar-day counters (the history log does not yet
 * cover the whole window, see `autopilot-state.sh stats`): it can be too high or too low, so an estimate gets
 * no arrow. No mark = exact. The cell always shows the 24h number: with no history it is an exact 0 (no cycle
 * in the window) or the `~` estimate.
 */
function apStatsVariants(ap: Autopilot): Variants | null {
  const st = ap.stats
  if (!st) return null
  const avg = st.avg_merged_24h.toFixed(1)
  const n = `${st.approx ? '~' : ''}${st.merged_24h}`
  const glyph = st.approx ? '' : st.trend === 'up' ? '▲' : st.trend === 'down' ? '▼' : ''
  const mk = (head: string, gap: string, rest: string, tail: string): Seg[] => [
    { text: head },
    ...(glyph ? [{ text: `${gap}${glyph}`, color: st.trend === 'up' ? ('success' as const) : ('error' as const) }] : []),
    ...(rest ? [{ text: rest }] : []),
    ...(tail ? [{ text: tail, dim: true }] : []),
  ]
  const c = st.cycles_24h
  return [
    mk(`last 24h: ${n} merged`, ' ', ` / ${c} loops`, ` · average ${avg}/day`),
    mk(`24h: ${n} merged`, ' ', `/${c} loops`, ` · average ${avg}/day`),
    mk(`24h: ✓${n}`, '', `/${c}L`, ` average ${avg}/d`),
    mk(`24h ✓${n}`, '', `/${c}L`, ` avg ${avg}/d`),
    mk(`24h ✓${n}`, '', '', ''),
  ]
}

/**
 * The jobs line's 24h cell (details only): `last 24h: jobs 8 ▲ / average 5.2/day`. Same conventions as the AP cell
 * (apStatsVariants): the count is jobs STARTED in the rolling last 24 h, the average is lifetime jobs per day at one
 * decimal; a green `▲` above, a red `▼` below, NO arrow when equal at that decimal or when the count is an estimate;
 * `~` before the count = it may be too low (the start log is younger than 24 h), `~` before the average = it rests on
 * an estimated first-job time. No stats, no cell (there is no total-jobs fallback).
 */
function jobStatsSegs(st: JobStats | null | undefined): Seg[] | null {
  if (!st) return null
  const glyph = st.approx ? '' : st.trend === 'up' ? '▲' : st.trend === 'down' ? '▼' : ''
  return [
    { text: `last 24h: jobs ${st.approx ? '~' : ''}${st.jobs_24h}` },
    ...(glyph ? [{ text: ` ${glyph}`, color: st.trend === 'up' ? ('success' as const) : ('error' as const) }] : []),
    { text: ` / average ${st.avg_approx ? '~' : ''}${st.avg_jobs_day.toFixed(1)}/day`, dim: true },
  ]
}

/** Commits behind this many or more turn the behind count to the warning colour (a stale clone); fewer stay neutral. */
export const BEHIND_WARN = 20

/**
 * ` ↑2 ↓134` after the branch: ahead in the neutral colour, behind neutral under BEHIND_WARN and warning from it.
 * `withAhead` false keeps only the behind count (the narrow forms). Nothing when level or unknown.
 */
function behindSegs(b: Behind | null, withAhead: boolean): Seg[] {
  if (!b) return []
  const segs: Seg[] = []
  if (withAhead && b.ahead > 0) segs.push({ text: ` ↑${b.ahead}`, dim: true })
  if (b.behind > 0) segs.push({ text: ` ↓${b.behind}`, ...(b.behind >= BEHIND_WARN ? { color: 'warning' as const } : { dim: true }) })
  return segs
}

/**
 * The repo cell, most to least detail:
 * `[→ ]owner/name @ branch[ ↑ahead][ ↓behind]* (wt X) (account) (root: X)`. It follows the session cwd (the helper is
 * run for it). `→` leads for a couple of refreshes after the working repo changed; `(root: X)` shows
 * when a shell cd left the session root; a detached HEAD reads `detached <sha>`; `↑N ↓M` = commits ahead of and behind the
 * remote (warning colour from BEHIND_WARN behind; the narrow forms keep only `↓M`); `*` = changed
 * tracked files. Shrinking drops the worktree, then the account, then shortens the names, last the branch.
 */
function repoVariants(snap: Snapshot): Variants | null {
  const h = snap.helper
  const full = h?.repo_slug || h?.repo
  if (!h || !full) return null
  const root = snap.sessionRoot && h.cwd && !isWithin(h.cwd, snap.sessionRoot) ? baseName(snap.sessionRoot) : ''
  const dirty = h.dirty !== null && h.dirty > 0
  const where = h.branch || (h.head ? `detached ${h.head}` : '')
  const build = (o: { name: number; slug: boolean; branch: number; wt: boolean; acct: boolean; root: number; gap?: 'both' | 'behind' }): Seg[] => {
    const segs: Seg[] = []
    if (snap.moved) segs.push({ text: '→ ', color: 'suggestion', bold: true })
    segs.push({ text: truncate(o.slug ? full : baseName(full) || full, o.name), bold: true })
    if (where && o.branch > 0) segs.push({ text: ` @ ${truncate(where, o.branch)}` })
    if (o.gap && h.branch) segs.push(...behindSegs(h.behind, o.gap === 'both'))
    if (dirty) segs.push({ text: '*', color: 'warning' })
    if (o.wt && h.worktree) segs.push({ text: ` (wt ${truncate(h.worktree, 24)})`, dim: true })
    if (o.acct && h.gh_account) segs.push({ text: ` (${truncate(h.gh_account, 24)})`, dim: true })
    if (o.root > 0 && root) segs.push({ text: ` (root: ${truncate(root, o.root)})`, color: 'warning' })
    return segs
  }
  const all = [
    build({ name: 48, slug: true, branch: 40, wt: true, acct: true, root: 20, gap: 'both' }),
    build({ name: 48, slug: true, branch: 40, wt: false, acct: true, root: 20, gap: 'both' }),
    build({ name: 48, slug: true, branch: 40, wt: false, acct: false, root: 20, gap: 'both' }),
    build({ name: 24, slug: false, branch: 24, wt: false, acct: false, root: 20, gap: 'both' }),
    build({ name: 16, slug: false, branch: 14, wt: false, acct: false, root: 10, gap: 'behind' }),
    build({ name: 16, slug: false, branch: 0, wt: false, acct: false, root: 0 }),
  ]
  // Identical neighbours would waste a shrink step.
  const out: Variants = []
  for (const v of all) if (out.length === 0 || joinText(out[out.length - 1]!) !== joinText(v)) out.push(v)
  return out
}

function itemFor(field: Field, snap: Snapshot, cfg: HudConfig, nowMs: number = Date.now()): Item | null {
  const h = snap.helper
  const one = (...v: Seg[][]): Item => ({ field, variants: v, at: 0 })
  switch (field) {
    case 'repo': {
      const v = repoVariants(snap)
      return v ? one(...v) : null
    }
    case 'branch': {
      const b = h?.branch
      return b ? one([{ text: ` ${b}` }], [{ text: ` ${truncate(b, 24)}` }], [{ text: ` ${truncate(b, 14)}` }]) : null
    }
    case 'task': {
      if (!h?.task_id) return null
      const t = h.task_title
      const v: Variants = []
      if (t) v.push([{ text: truncateWords(`${h.task_id} ${t}`, 60) }], [{ text: truncateWords(`${h.task_id} ${t}`, 40) }])
      v.push([{ text: h.task_id }])
      return one(...v)
    }
    case 'ap': {
      const ap = h?.autopilot
      return ap ? one(...apVariants(ap)) : null
    }
    case 'ctx': {
      if (snap.ctxLeft === null) return null
      const left = Math.round(snap.ctxLeft)
      const color = ctxTone(left, cfg)
      return one([{ text: `ctx ${left}% ${meter(left)}`, color }], [{ text: `ctx ${left}%`, color }])
    }
    case 'jobs': {
      const led = h?.ledger
      if (!led) return null // no ledger: no READY either
      const n = led.running.length
      const full = jobState(n)
      const slim = jobState(n, false)
      return one([{ text: full.text, color: full.color }], [{ text: slim.text, color: slim.color }])
    }
    case 'queue': {
      const q = h?.queue
      return q ? one(...queueVariants(q, false)) : null
    }
    case 'nightly': {
      const n = h?.nightly
      return n ? one(...nightlyVariants(n, false)) : null
    }
    case 'issues': {
      const i = h?.issues
      return i ? one(...issuesVariants(i, false)) : null
    }
    case 'bus': {
      const b = h?.bus
      return b ? one(...busVariants(b)) : null
    }
    case 'ci':
      return null // the CI cell has its own row (ciRow), never a cell of the main row
    case 'rate': {
      const full = rateSegs(snap, nowMs, { runout: true, reset: true })
      return full ? one(full, rateSegs(snap, nowMs, { runout: true, reset: false })!, rateSegs(snap, nowMs, { runout: false, reset: false })!) : null
    }
    case 'lastat': {
      const at = h?.last_input_at
      return at ? one([{ text: `you ${formatStamp(at)}`, dim: true }], [{ text: formatStamp(at), dim: true }]) : null
    }
    case 'ver':
      // `ver0` (installed only, or `(latest)`) shrinks to `✓` then is dropped early; `ver` (an update is available) is kept almost to the end.
      return cfg.version && h?.plugin ? { field: versionState(h.plugin) === 'available' ? 'ver' : 'ver0', variants: versionVariants(h.plugin), at: 0 } : null
  }
}

const maxNum = (x: number | null) => (x === null ? '-' : String(x))
/** ` ▲` when this week's peak is above last week's, ` ▼` below, nothing when equal or when there is no last week. */
const trendMark = (m: QueueMax) => (m.lw === null || m.tw === m.lw ? '' : m.tw > m.lw ? ' ▲' : ' ▼')
/** Warning colour while the queue sits at the highest of the three maxima. */
const maxTone = (total: number, m: QueueMax) => (total > 0 && total >= Math.max(m.lm ?? 0, m.lw ?? 0, m.tw) ? ('warning' as const) : undefined)

/**
 * Details (`full`): `queue 44 = 30 ready | 6 blocked | 3 epics`, the labels always in full
 * (one form only: details never abbreviates, a too-wide line is cut with an ellipsis); `epics` reads
 * singular at a count of 1. The one-row band (`!full`) starts at `queue 44 = 30r 6b 3x` and shrinks to
 * `queue 30/44`. `claimed` (held by another session) shows only above 0: `2c` in the band. `blocked` = `Blocked by` an open task. The autopilot's holds are not here: they show in the AUTOPILOT section. The max block `max 61/74/83 ▲` (details spell the labels out)
 * shows the queue's largest length in the previous 4 weeks, last week and this week (see hud-queue-hwm.sh).
 */
export function queueVariants(q: Queue, full: boolean): Variants {
  const parts: Array<[string, string, string, number]> = [
    ['ready', 'ready', 'r', q.ready],
    ['blocked', 'blocked', 'b', q.blocked],
    ['epic', 'epics', 'x', q.epic],
  ]
  if (q.claimed > 0) parts.push(['claimed', 'claimed', 'c', q.claimed])
  if (full) {
    const long: Seg[] = [{ text: `queue${q.branch ? ` (${q.branch})` : q.fallback ? ' (working tree, origin unavailable)' : ''} ${q.total} = ` }]
    parts.forEach(([one, many, , n], i) => {
      if (i > 0) long.push({ text: ' | ', dim: true })
      long.push({ text: `${n} ${n === 1 ? one : many}`, dim: n === 0 && one !== 'ready', color: one === 'ready' && n > 0 ? 'success' : undefined })
    })
    if (q.hwm) {
      const m = q.hwm, tone = maxTone(q.total, m)
      long.push({ text: ' | ', dim: true }, { text: `max ${maxNum(m.lm)} last month / ${maxNum(m.lw)} last week / ${m.tw} this week${trendMark(m)}`, dim: !tone, color: tone })
    }
    return [long]
  }
  const at = q.branch ? `@${q.branch}` : q.fallback ? '@wt' : ''
  const hw = q.hwm
  const short: Seg[] = [{ text: `queue${at} ${q.total} = ` }, ...parts.flatMap(([, , ch, n], i): Seg[] => [...(i > 0 ? [{ text: ' ' }] : []), { text: `${n}${ch}`, dim: n === 0 && ch !== 'r', color: ch === 'r' && n > 0 ? 'success' : undefined }])]
  const tiny: Seg[] = [{ text: `queue${at} ${q.ready}/${q.total}`, color: q.ready > 0 ? 'success' : undefined }]
  if (!hw) return [short, tiny]
  // Maxima: `max 31/40/52 ▲` (last month / last week / this week, `-` = no history that old, the arrow compares this week with last week), then dropped. At the highest of the three: warning colour.
  const tone = maxTone(q.total, hw)
  return [
    [...short, { text: ` · max ${maxNum(hw.lm)}/${maxNum(hw.lw)}/${hw.tw}${trendMark(hw)}`, dim: !tone, color: tone }],
    short,
    tiny,
  ]
}

/**
 * The nightly cell. Band: `nightly ++-++-+ · 30d: 16✓ 14✗` (+ green, - red, . dim; ✓ green days in the last 30 UTC days
 * in the success colour, ✗ red days in the error colour, a zero dim), then `nightly ++-++-+ 16✓ 14✗`, then `nightly ++-++-+`
 * (the strip and counts survive as long as possible; the cell is dropped last). Details (`full`) spells it out and never
 * abbreviates: `nightly ++-++-+ (last 7 days) · last 30 days: 16 green ✓ / 14 red ✗`. A cache written before the green count
 * existed has no `green`: the count reads `14✗` (band) / `14 red ✗` (details), the green part is simply absent. The glyphs
 * stay with NO_COLOR (only the colour drops).
 */
export function nightlyVariants(n: Nightly, full = false): Variants {
  const strip: Seg[] = [...n.strip].map((c): Seg => ({ text: c, color: c === '+' ? 'success' : c === '-' ? 'error' : undefined, dim: c === '.' }))
  const g = n.green
  const counts = (gTxt: string, rTxt: string): Seg[] => [
    ...(g !== undefined ? [{ text: gTxt, color: g > 0 ? ('success' as const) : undefined, dim: g === 0 }] : []),
    ...(g !== undefined ? [{ text: ' ' }] : []),
    { text: rTxt, color: n.red > 0 ? ('error' as const) : undefined, dim: n.red === 0 },
  ]
  if (full) {
    const red: Seg = { text: `${n.red} red ✗`, color: n.red > 0 ? 'error' : undefined, dim: n.red === 0 }
    const both: Seg[] = g === undefined ? [red] : [{ text: `${g} green ✓`, color: g > 0 ? 'success' : undefined, dim: g === 0 }, { text: ' / ', dim: true }, red]
    return [[{ text: 'nightly ' }, ...strip, { text: ' (last 7 days) · last 30 days: ', dim: true }, ...both]]
  }
  return [
    [{ text: 'nightly ' }, ...strip, { text: ' · 30d: ', dim: true }, ...counts(`${g}✓`, `${n.red}✗`)],
    [{ text: 'nightly ' }, ...strip, { text: ' ' }, ...counts(`${g}✓`, `${n.red}✗`)],
    [{ text: 'nightly ' }, ...strip],
  ]
}

/**
 * The customer-issues cell. Band: `issues 12 open / 7 undelivered · max 18 180d / 15 30d / 12 7d`, then `issues 12 open / 7 undeliv. · max 18/15/12`
 * (180d/30d/7d), then `issues 12/7`, then `issues 12`. The undelivered count is in the warning colour while above 0; the max block is
 * dim, warning-coloured when the open count is at its 180-day high. Details (`full`) never abbreviates:
 * `issues 12 open | 7 not delivered | max open 18 in 180 days / 15 in 30 days / 12 in 7 days`. A missing watermark just drops the max block.
 */
export function issuesVariants(i: Issues, full = false): Variants {
  const hw = i.hwm
  const tone = hw && i.open >= hw.d180 && hw.d180 > 0 ? 'warning' : undefined
  const und = (text: string): Seg => ({ text, color: i.undelivered > 0 ? 'warning' : undefined, dim: i.undelivered === 0 })
  if (full) {
    const long: Seg[] = [{ text: `issues ${i.open} open` }, { text: ' | ', dim: true }, und(`${i.undelivered} not delivered`)]
    if (hw) long.push({ text: ' | ', dim: true }, { text: `max open ${hw.d180} in 180 days / ${hw.d30} in 30 days / ${hw.d7} in 7 days`, dim: !tone, color: tone })
    return [long]
  }
  const head = (undTxt: string): Seg[] => [{ text: `issues ${i.open} open / ` }, und(undTxt)]
  const out: Seg[][] = []
  if (hw) {
    out.push([...head(`${i.undelivered} undelivered`), { text: ` · max ${hw.d180} 180d / ${hw.d30} 30d / ${hw.d7} 7d`, dim: !tone, color: tone }])
    out.push([...head(`${i.undelivered} undeliv.`), { text: ` · max ${hw.d180}/${hw.d30}/${hw.d7}`, dim: !tone, color: tone }])
  } else out.push(head(`${i.undelivered} undelivered`))
  out.push([{ text: `issues ${i.open}/` }, und(`${i.undelivered}`)], [{ text: `issues ${i.open}` }])
  return out
}

/**
 * The cross-account bus cell: notes from another Claude Code session wait for this profile. `bus 2 · home` (warning colour:
 * someone is waiting), narrowing to `bus 2`. Nothing when nothing is unread or the bus is off. `full` (details) is the long form only.
 */
export function busVariants(b: Bus, full = false): Variants {
  const long: Seg[] = [{ text: b.from ? `bus ${b.unread} · ${b.from}` : `bus ${b.unread}`, color: 'warning' }]
  if (full) return [[{ text: `bus ${b.unread} unread note${b.unread === 1 ? '' : 's'}${b.from ? ` · newest from ${b.from}` : ''}`, color: 'warning' }]]
  return [long, [{ text: `bus ${b.unread}`, color: 'warning' }]]
}

/** Band order per mode; `fields` in the config only switches members of the mode on or off. */
const ORDER = {
  off: ['repo', 'branch', 'task', 'jobs', 'queue', 'nightly', 'issues', 'bus', 'rate', 'lastat', 'ver'],
  on: ['ap', 'queue', 'nightly', 'issues', 'bus', 'ctx', 'jobs', 'rate', 'lastat', 'ver'], // AP, its 24h cell, then queue: AP and queue share a row
} as const

/** Shrink and drop steps, applied one at a time until the row fits (see README). */
const STEPS = {
  off: ['drop:stale', 'step:rate', 'step:rate', 'drop:rate', 'drop:lastat', 'step:queue', 'step:queue', 'step:queue', 'step:ver0', 'drop:ver0', 'step:nightly', 'step:nightly', 'step:issues', 'step:issues', 'step:issues', 'drop:issues', 'step:bus', 'drop:queue', 'drop:nightly', 'drop:bus', 'step:ver', 'step:ver', 'step:jobs', 'step:task', 'step:task', 'step:repo', 'step:repo', 'drop:task', 'step:repo', 'step:repo', 'step:repo', 'drop:ver'],
  on: ['drop:stale', 'step:rate', 'step:rate', 'drop:rate', 'drop:lastat', 'step:queue', 'step:queue', 'step:queue', 'step:ver0', 'drop:ver0', 'step:nightly', 'step:nightly', 'step:issues', 'step:issues', 'step:issues', 'drop:issues', 'step:bus', 'drop:queue', 'drop:nightly', 'drop:bus', 'step:ver', 'step:ver', 'step:ctx', 'step:jobs', 'step:apstats', 'step:apstats', 'step:apstats', 'step:apstats', 'step:ap', 'step:ap', 'drop:dop', 'drop:ctx', 'drop:apstats', 'drop:ver', 'drop:stall'],
}

function render(items: Item[]): Seg[] {
  const out: Seg[] = []
  items.forEach((it, i) => {
    if (i > 0) out.push({ text: SEP, dim: true })
    out.push(...it.variants[it.at]!)
  })
  return out
}

/**
 * The band: up to TWO rows. With `ci` configured (and an answer) the CI cell is alone on the TOP row; the
 * second row has the rest. Two modes: autopilot ON (AP, 24h, queue, ctx, jobs, last input) and OFF (repo,
 * branch, task, jobs, queue, last input). The tier only picks how abbreviated each field starts; when the
 * row is still too wide the steps in STEPS shrink or drop fields. No `ci`: one row, as ever.
 * Returns [] when there is nothing to show (the caller then yields to the engine).
 */
export function bandRows(snap: Snapshot, cfg: HudConfig, columns: number, nowMs: number = Date.now()): Seg[][] {
  const tier = tierOf(columns)
  const width = Math.max(20, columns - 2) // the band has one column of padding each side
  const mode = isApOn(snap) ? 'on' : 'off'
  const start = tier === 'wide' ? 0 : tier === 'compact' ? 1 : 2
  let items: Item[] = []
  for (const f of ORDER[mode]) {
    // The version segment is switched by its own `version` key, not by `fields`.
    if (f !== 'ver' && !cfg.fields.includes(f)) continue
    const it = itemFor(f, snap, cfg, nowMs)
    // The tier sets how detailed the AP and ctx cells start; the rest start full and shrink only to fit.
    if (it) items.push({ ...it, at: f === 'ap' || f === 'ctx' ? Math.min(start, it.variants.length - 1) : 0 })
    // The 24h progress cell rides with the AP cell (same switch); it shrinks after the ctx bar, CI and jobs cells, so the 24h merged count and the average survive common widths.
    if (f === 'ap' && it) {
      const dop = dopBandSegs(snap.helper)
      if (dop) items.push({ field: 'dop', variants: [dop], at: 0 })
      const sv = apStatsVariants(snap.helper!.autopilot!)
      if (sv) items.push({ field: 'apstats', variants: sv, at: Math.min(tier === 'wide' ? 0 : tier === 'compact' ? 1 : 3, sv.length - 1) })
      // A loop days late is dead, not "due": the band says so (red) right after the AP cells. Not shown while paused or busy.
      const late = stalledFor(snap.helper!.autopilot!, nowMs)
      if (late > 0) items.push({ field: 'stall', variants: [[{ text: `stalled ${formatSpan(late, false)}`, color: 'error', bold: true }]], at: 0 })
    }
  }
  // The repo cell already carries the branch (or `detached <sha>`): do not say it twice.
  if (items.some(it => it.field === 'repo')) items = items.filter(it => it.field !== 'branch')
  if (snap.stale) items.push({ field: 'stale', variants: [[{ text: 'stale', dim: true }]], at: 0 })
  const rows: Seg[][] = []
  // CI is its own top row; `fields` switches it like any other cell.
  const top = cfg.fields.includes('ci') ? ciRow(snap, cfg, width, nowMs) : null
  if (top && top.length > 0) rows.push(top)
  const row = items.length === 0 ? [] : fitRow(items, STEPS[mode], width)
  if (row.length > 0) rows.push(row)
  return rows
}

/**
 * Applies the shrink and drop steps one at a time until the row fits `width`, then, as a last
 * resort on absurdly narrow terminals, cuts the text (never wraps). [] when nothing is left.
 */
function fitRow(all: Item[], steps: readonly string[], width: number, ellipsis = false): Seg[] {
  let items = all
  const total = () => widthOf(render(items))
  for (const step of steps) {
    if (total() <= width) break
    const [op, field] = step.split(':')
    if (op === 'drop') items = items.filter(it => it.field !== field)
    else items = items.map(it => (it.field === field && it.at < it.variants.length - 1 ? { ...it, at: it.at + 1 } : it))
  }
  if (items.length === 0) return []
  const row = render(items)
  if (widthOf(row) > width) {
    // `ellipsis` (details): the cut ends in `…` so a clipped line says so; it takes one extra column.
    let over = widthOf(row) - width + (ellipsis ? 1 : 0)
    for (let i = row.length - 1; i >= 0 && over > 0; i--) {
      const cur = row[i]!
      const cut = Math.min(over, cur.text.length)
      row[i] = { ...cur, text: cur.text.slice(0, cur.text.length - cut) }
      over -= cut
    }
    if (ellipsis) {
      let j = row.length - 1
      while (j > 0 && row[j]!.text === '') j--
      row[j] = { ...row[j]!, text: row[j]!.text + '…' }
    }
  }
  return row
}

/** "just now", "5m ago", "3h ago", "2d ago" for an epoch-seconds time (never negative). */
export function formatAge(epochSec: number, nowMs: number = Date.now()): string {
  const s = Math.max(0, Math.floor(nowMs / 1000 - epochSec))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

const ageSegs = (at: number, nowMs: number): Seg[] => (at > 0 ? [{ text: ` (${formatAge(at, nowMs)})`, dim: true }] : [])

/** "in <1m", "in 12m", "in 1h 5m", "in 2d" until an epoch-seconds time; "now" when it is due or past. */
export function formatIn(epochSec: number, nowMs: number = Date.now()): string {
  const s = Math.floor(epochSec - nowMs / 1000)
  if (s <= 0) return 'now'
  if (s < 60) return 'in <1m'
  const m = Math.floor(s / 60)
  if (m < 60) return `in ${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return m % 60 ? `in ${h}h ${m % 60}m` : `in ${h}h`
  return `in ${Math.floor(h / 24)}d`
}

/**
 * How late a wake may be before the loop counts as stalled: 10 minutes. A wake time is when the loop is DUE; the
 * autopilot's own tick, a slow cycle or a laptop wake-up can run a few minutes behind, so "due" holds up to the grace
 * and "overdue" (details) / "stalled" (band) only beyond it. A loop that is days late is dead, not due.
 */
export const STALL_GRACE_SEC = 600

/** A span of seconds as `2d 16h`, `3h 5m`, `45m` (`long`), or only the largest unit `2d`, `3h`, `45m` (the one-row band). */
export function formatSpan(sec: number, long: boolean): string {
  const s = Math.max(0, Math.floor(sec))
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  if (d > 0) return long && h > 0 ? `${d}d ${h}h` : `${d}d`
  if (h > 0) return long && m > 0 ? `${h}h ${m}m` : `${h}h`
  return `${m}m`
}

/**
 * Seconds the autopilot's next loop is overdue beyond the grace, or 0 when it is not stalled: not paused, no cycle
 * running (a busy loop is working, its stored wake time is stale by design) and a known wake time well in the past.
 */
export function stalledFor(ap: Autopilot, nowMs: number): number {
  if (ap.prefix === '[p]' || ap.busy || ap.next_wake_at <= 0) return 0
  const late = Math.floor(nowMs / 1000 - ap.next_wake_at)
  return late > STALL_GRACE_SEC ? late : 0
}

/** Width of the section label column in `/hud details`: the longest label (`SESSION`, `SUPPORT`, `RELEASE`) plus two spaces. */
export const DETAIL_LABEL_WIDTH = 10

/** Splits segments into words and spaces (each keeping its style) and fills lines of at most `avail` columns, breaking at spaces; a single word longer than a line is broken hard. Nothing is ever cut off. */
function wrapSegs(segs: Seg[], avail: number): Seg[][] {
  // Words are found across segment boundaries (a word made of several styled pieces, like the nightly strip, stays whole).
  type Piece = { seg: Seg; text: string }
  const words: Array<{ space: boolean; pieces: Piece[]; len: number }> = []
  let prevSpace: boolean | null = null
  for (const sg of segs) {
    for (const ch of sg.text) {
      const space = /\s/.test(ch)
      if (prevSpace !== space) words.push({ space, pieces: [], len: 0 })
      prevSpace = space
      const w = words[words.length - 1]!
      const last = w.pieces[w.pieces.length - 1]
      if (last && last.seg === sg) last.text += ch
      else w.pieces.push({ seg: sg, text: ch })
      w.len += 1
    }
  }
  const lines: Seg[][] = [[]]
  let used = 0
  const push = (pieces: Piece[]) => pieces.forEach(pc => lines[lines.length - 1]!.push({ ...pc.seg, text: pc.text }))
  for (const w of words) {
    if (w.space && used === 0) continue // no leading blanks on a line
    if (!w.space && used + w.len > avail && used > 0) {
      lines.push([])
      used = 0
    }
    if (!w.space && w.len > avail) {
      // a single word longer than a line: break it hard
      let left = avail - used
      let line: Piece[] = []
      let n = 0
      for (const pc of w.pieces) {
        for (const ch of pc.text) {
          if (n === left) {
            push(line)
            lines.push([])
            line = []
            n = 0
            left = avail
            used = 0
          }
          const lp = line[line.length - 1]
          if (lp && lp.seg === pc.seg) lp.text += ch
          else line.push({ seg: pc.seg, text: ch })
          n += 1
        }
      }
      push(line)
      used = n
      continue
    }
    push(w.pieces)
    used += w.len
  }
  return lines.filter((l, i) => l.length > 0 || i === 0).map(l => {
    const out = l.slice() // drop trailing blanks
    while (out.length > 0 && out[out.length - 1]!.text.trim() === '') out.pop()
    return out
  })
}

/**
 * One section of the details view: the bold label, then the cells joined by ` │ `. A row that would be wider than the
 * terminal wraps onto further lines indented under the cells (cells stay whole when they fit; a cell wider than a line
 * wraps at its own spaces). Nothing is truncated. [] when the section has no cell.
 */
function sectionRows(label: string, cells: Array<Seg[] | null>, width: number): Seg[][] {
  const live = cells.filter((c): c is Seg[] => c !== null && c.length > 0)
  if (live.length === 0) return []
  const avail = Math.max(10, width - DETAIL_LABEL_WIDTH)
  const lines: Seg[][] = []
  let cur: Seg[] = []
  const flush = () => {
    if (cur.length > 0) lines.push(cur)
    cur = []
  }
  for (const cell of live) {
    if (cur.length > 0 && widthOf(cur) + SEP.length + widthOf(cell) <= avail) {
      cur.push({ text: SEP, dim: true }, ...cell)
    } else if (cur.length === 0 && widthOf(cell) <= avail) {
      cur = [...cell]
    } else if (widthOf(cell) <= avail) {
      flush()
      cur = [...cell]
    } else {
      // a cell wider than a line: put it on fresh lines of its own, wrapped at its spaces; the last line may host the next cell
      flush()
      const wrapped = wrapSegs(cell, avail)
      wrapped.slice(0, -1).forEach(l => lines.push(l))
      cur = wrapped[wrapped.length - 1]!
    }
  }
  flush()
  return lines.map((l, i) => [{ text: i === 0 ? label.padEnd(DETAIL_LABEL_WIDTH) : ' '.repeat(DETAIL_LABEL_WIDTH), bold: i === 0, dim: i > 0 }, ...l])
}

/** A ledger row started by an autopilot cycle (ledger `--flags autopilot`); everything else is WORK. */
function isApJob(j: { flags?: string }): boolean {
  return (j.flags ?? '').split(',').includes('autopilot')
}

/**
 * `/hud details`: the band expanded into labeled SECTIONS, one row each (a long row wraps onto an indented line, nothing is
 * truncated or abbreviated; the one-row band keeps the short forms). A section with nothing to say is left out. Order:
 *   SESSION  context left, subscription limit left with its reset time, unread bus notes, last prompt (stamp and age)
 *   CLONE     repo, branch, dirty mark, claimed task (and `stale`)
 *   BUILD    CI (first; a red CI is drawn highlighted), nightly: 7-day strip and the last 30 days' green and red counts
 *   SUPPORT  the customer-issue stats (opt-in)
 *   AUTOPILOT autopilot on/paused/off, max_dop and how it is used, holds, next loop (or overdue / running cycles), its 24h cell
 *   WORK     the ledger rows WITHOUT the autopilot flag: jobs state (READY / WORKING (N)), parked, last 24h jobs
 *   QUEUE    the queue breakdown (dev/TODO/queue.md), labels in full
 *   RELEASE  the plugin's GitHub URL, the ccxp version label, the number of unreleased commits
 * Details is a SUPERSET of the band: every cell the band can show has its full-form counterpart here (pinned by the
 * superset test in pure.test.ts). It ignores `fields`: the rows are the view. [] when there is no data at all.
 */
export function detailRows(snap: Snapshot, cfg: HudConfig, columns: number, nowMs: number = Date.now()): Seg[][] {
  const h = snap.helper
  const width = Math.max(20, columns - 2)
  const one = (field: string, ...v: Seg[][]): Item => ({ field, variants: v, at: 0 })
  const pick = (f: Field) => itemFor(f, snap, cfg, nowMs)
  const full = (it: Item | null): Seg[] | null => (it ? it.variants[0]! : null)
  const rows: Seg[][] = []
  const section = (label: string, cells: Array<Item | Seg[] | null>) => {
    rows.push(...sectionRows(label, cells.map(c => (c === null || Array.isArray(c) ? c : full(c))), width))
  }

  // SESSION: context is what is LEFT (the band's ctx); the rate cell is the share LEFT of the subscription window that runs out first,
  // when it runs out and when it resets, coloured by the gap to runout (owner decisions d166, d167). The API-equivalent cost cell was retired.
  const usage: Array<Item | null> = []
  if (snap.ctxLeft !== null) {
    const left = Math.round(snap.ctxLeft)
    usage.push(one('ctx', [{ text: `context ${left}% left ${meter(left)}`, color: ctxTone(left, cfg) }]))
  }
  const rateDetail = rateSegs(snap, nowMs, { runout: true, reset: true })
  if (rateDetail) usage.push(one('rate', rateDetail))
  const at = h?.last_input_at
  section('SESSION', [
    ...usage,
    h?.bus ? full(one('bus', ...busVariants(h.bus, true))) : null,
    at ? [{ text: `you ${formatStamp(at, nowMs)}`, dim: true }, ...ageSegs(at, nowMs)] : null,
  ])

  // CLONE: where you are
  section('CLONE', [pick('repo'), pick('task'), snap.stale ? one('stale', [{ text: 'stale', dim: true }]) : null])

  // BUILD: CI first (highlighted when red; only when `ci` is set and answered), the nightly right after it
  const ci = h?.ci
  section('BUILD', [cfg.ci && ci ? ciRowVariants(ci, cfg.ci.workflow, nowMs)[0]! : null, h?.nightly ? full(one('nightly', ...nightlyVariants(h.nightly, true))) : null])

  // SUPPORT: the customer-issue stats (opt-in): open, not delivered, max open over 180 / 30 / 7 days
  section('SUPPORT', [h?.issues ? full(one('issues', ...issuesVariants(h.issues, true))) : null])

  // WORK: autopilot, the next loop, its 24h cell, then the jobs from the ledger (no ledger: no jobs cells)
  const ap = h?.autopilot
  let apItem: Item | null = null
  if (ap) {
    const f = apVariants(ap)
    const withStatus: Seg[] = ap.prefix === '[p]' || !ap.status ? f[0]! : [f[0]![0]!, { text: `${truncate(ap.status, 14)} ` }, ...f[0]!.slice(1)]
    apItem = one('ap', withStatus)
  } else if (h) {
    apItem = one('ap', [{ text: 'AP ', bold: true }, { text: 'off', dim: true }])
  }
  // The next loop: the clock time and the wait; paused says so (the stored time is stale then); nothing when unknown.
  // A wake time that passed by more than the grace is not "due" but a stalled loop: warn-coloured, with how late it is.
  let wakeItem: Item | null = null
  if (ap?.prefix === '[p]') {
    wakeItem = one('wake', [{ text: 'next loop paused', dim: true }])
  } else if (ap?.busy) {
    // A cycle is running: name its job (the running ledger row flagged autopilot, highest number) rather than a due time that is stale until the cycle ends.
    // With parallel cycles (busy_slots > 1) name that many rows, the highest-numbered ones, ascending: `running r596,r597`.
    const run = (h?.ledger?.running ?? []).filter(j => j.job > 0 && isApJob(j)).map(j => j.job).sort((a, b) => b - a)
    const shown = run.slice(0, Math.max(1, ap.busy_slots || 0)).sort((a, b) => a - b)
    wakeItem = one('wake', [{ text: shown.length > 0 ? `running ${shown.map(n => `r${n}`).join(',')}` : 'running' }])
  } else if (ap && ap.next_wake_at > 0) {
    const late = stalledFor(ap, nowMs)
    if (late > 0) {
      wakeItem = one('wake', [{ text: `next loop overdue ${formatSpan(late, true)}`, color: 'error', bold: true }])
    } else if (formatIn(ap.next_wake_at, nowMs) === 'now') {
      wakeItem = one('wake', [{ text: 'next loop due', dim: true }])
    } else {
      wakeItem = one('wake', [{ text: `next loop ${formatStamp(ap.next_wake_at, nowMs)} (${formatIn(ap.next_wake_at, nowMs)})` }])
    }
  }
  const apStats = ap ? apStatsVariants(ap) : null
  const led = h?.ledger
  const jobCells: Array<Item | null> = []
  if (led) {
    // WORK counts only the rows without the `autopilot` flag: the autopilot's cycles are summarised in AUTOPILOT.
    const state = jobState(led.running.filter(j => !isApJob(j)).length)
    const parked = led.parked.length
    const js = jobStatsSegs(led.stats)
    jobCells.push(one('state', [{ text: state.text, color: state.color }]), one('parked', [{ text: `parked ${parked}`, dim: parked === 0 }]), js ? one('jobs24', js) : null)
  }
  const dopSegs = dopDetailSegs(h)
  // Holds (the state file's `.holds`, via the queue breakdown): only while there is an autopilot record (on, paused, idle), and only above 0.
  const holds = ap ? h?.queue?.apholds ?? 0 : 0
  const holdsItem = holds > 0 ? one('apholds', [{ text: `${holds} held by autopilot`, color: 'warning' }]) : null
  section('AUTOPILOT', [apItem, dopSegs ? one('dop', dopSegs) : null, holdsItem, wakeItem, apStats ? one('apstats', apStats[0]!) : null])
  section('WORK', jobCells)

  // QUEUE: the breakdown (labels in full)
  section('QUEUE', [h?.queue ? full(one('queue', ...queueVariants(h.queue, true))) : null])

  // RELEASE: the plugin's GitHub location as a bare URL (terminals make it cmd-clickable; no OSC 8) from the manifest via the helper
  // (the public URL otherwise), the version label, then how many commits came after the installed release (a count only). Shown with the version label, so only when that is.
  const verItem = pick('ver')
  const urlItem = verItem && h?.plugin ? one('url', [{ text: h.plugin.url ?? PLUGIN_URL_DEFAULT, dim: true }]) : null
  const unreleasedItem = urlItem && h?.plugin?.unreleased ? one('unreleased', ...unreleasedVariants(h.plugin.unreleased)) : null
  section('RELEASE', [urlItem, verItem, unreleasedItem])
  return rows
}

/** One plain line for surfaces with no band (VS Code `$.ui.status`), 2,000 chars at most. */
export function compactLine(snap: Snapshot, cfg: HudConfig): string {
  return bandRows(snap, cfg, 200).map(joinText).join(SEP).slice(0, 2000)
}
