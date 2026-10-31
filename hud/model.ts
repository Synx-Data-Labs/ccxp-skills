// ccxp-hud model: pure snapshot + band layout. No `$`, so it is unit-testable.

import type { ApStats, Autopilot, Ci, CiState, Field, HelperData, HudConfig, Jobs, Ledger, PluginVersion, Queue, Snapshot } from '../types'

export type { Autopilot, Ci, HelperData, Jobs, Snapshot }

export const EMPTY: Snapshot = {
  helper: null,
  ctxLeft: null,
  rateUsed: null,
  costUsd: null,
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
  const [ca, pa] = a.split('-', 2)
  const [cb, pb] = b.split('-', 2)
  const na = ca.split('.').map(Number)
  const nb = cb.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (na[i] !== nb[i]) return na[i] > nb[i]
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
  return { has_history: o.has_history === true, merged_24h: num(o.merged_24h), cycles_24h: num(o.cycles_24h), avg_merged_24h: num(o.avg_merged_24h), trend }
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
      stats: parseStats(a.stats),
    }
  }
  const led = r.ledger
  let ledger: Ledger | null = null
  if (typeof led === 'object' && led !== null && !Array.isArray(led)) {
    const l = led as Record<string, unknown>
    ledger = {
      running: (Array.isArray(l.running) ? l.running : [])
        .filter((x): x is Record<string, unknown> => typeof x === 'object' && x !== null)
        .map(x => ({ job: num(x.job), title: str(x.title) })),
      lifetime_jobs: num(l.lifetime_jobs),
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
    queue = { total: n(q.total), ready: n(q.ready), blocked: n(q.blocked), decision: n(q.decision), external: n(q.external), epic: n(q.epic), claimed: n(q.claimed) }
  }
  const c = r.ci
  let ci: Ci | null = null
  if (typeof c === 'object' && c !== null && !Array.isArray(c)) {
    // Untrusted: only the four known states get through, nothing else is ever drawn.
    const state = str((c as Record<string, unknown>).state)
    if (CI_STATES.includes(state as CiState)) ci = { state: state as CiState, at: num((c as Record<string, unknown>).at) }
  }
  const pl = r.plugin
  let plugin: PluginVersion | null = null
  if (typeof pl === 'object' && pl !== null && !Array.isArray(pl)) {
    // Untrusted: only plain X.Y.Z (optional prerelease) strings get through, nothing else is ever drawn.
    const installed = str((pl as Record<string, unknown>).installed)
    const latest = str((pl as Record<string, unknown>).latest)
    const url = str((pl as Record<string, unknown>).url)
    if (VERSION_RE.test(installed)) plugin = { installed, latest: VERSION_RE.test(latest) ? latest : null, ...(PLUGIN_URL_RE.test(url) ? { url } : {}) }
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
    autopilot,
    ledger,
    queue,
    ci,
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

/** Jobs cell: green READY when nothing runs, yellow WORKING (N) otherwise; `withCount: false` is the narrow form. */
export function jobState(running: number, withCount = true): { text: string; color: Tone } {
  if (running <= 0) return { text: 'READY', color: 'success' }
  return { text: withCount ? `WORKING (${running})` : 'WORKING', color: 'warning' }
}

export function meter(left: number, width = 10): string {
  const filled = Math.max(0, Math.min(width, Math.round((left / 100) * width)))
  return '▓'.repeat(filled) + '░'.repeat(width - filled)
}

export type Seg = { text: string; color?: string; dim?: boolean; bold?: boolean }

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
  return parts.length ? parts[parts.length - 1] : ''
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

function ciVariants(ci: Ci): Variants {
  const look = CI_LOOK[ci.state]
  const date = ci.at > 0 ? ` ${shortDate(ci.at)}` : ''
  const mk = (text: string): Seg[] => [{ text: 'CI ', bold: true }, { text, color: look.color }]
  return [mk(`${look.glyph} ${look.word}${date}`), mk(`${look.glyph}${date}`), mk(look.glyph)]
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
 * The autopilot's progress cell, most to least detail (with history; without it only the average shows):
 * `24h 8 merged/26 loops ▲ avg 5.2/day`, `24h ✓8/26L ▲ avg 5.2/d`, `24h ✓8 ▲`. The marker compares the
 * last 24 h merged with the lifetime average per 24 h (▲ above, ▼ below, = equal).
 */
function apStatsVariants(ap: Autopilot): Variants | null {
  const st = ap.stats
  if (!st) return null
  const avg = st.avg_merged_24h.toFixed(1)
  const mark: Seg = st.trend === 'up' ? { text: '▲', color: 'success' } : st.trend === 'down' ? { text: '▼', color: 'warning' } : { text: '=', dim: true }
  if (!st.has_history) return [[{ text: `avg ${avg}/day`, dim: true }], [{ text: `avg ${avg}/d`, dim: true }]]
  const mk = (head: string, tail: string): Seg[] => [{ text: head }, mark, ...(tail ? [{ text: tail, dim: true }] : [])]
  return [
    mk(`24h ${st.merged_24h} merged/${st.cycles_24h} loops `, ` avg ${avg}/day`),
    mk(`24h ✓${st.merged_24h}/${st.cycles_24h}L `, ` avg ${avg}/d`),
    mk(`24h ✓${st.merged_24h} `, ''),
  ]
}

/**
 * The repo cell, most to least detail:
 * `[→ ]owner/name @ branch* (wt X) (account) (root: X)`. It follows the session cwd (the helper is
 * run for it). `→` leads for a couple of refreshes after the working repo changed; `(root: X)` shows
 * when a shell cd left the session root; a detached HEAD reads `detached <sha>`; `*` = changed
 * tracked files. Shrinking drops the worktree, then the account, then shortens the names, last the branch.
 */
function repoVariants(snap: Snapshot): Variants | null {
  const h = snap.helper
  const full = h?.repo_slug || h?.repo
  if (!h || !full) return null
  const root = snap.sessionRoot && h.cwd && !isWithin(h.cwd, snap.sessionRoot) ? baseName(snap.sessionRoot) : ''
  const dirty = h.dirty !== null && h.dirty > 0
  const where = h.branch || (h.head ? `detached ${h.head}` : '')
  const build = (o: { name: number; slug: boolean; branch: number; wt: boolean; acct: boolean; root: number }): Seg[] => {
    const segs: Seg[] = []
    if (snap.moved) segs.push({ text: '→ ', color: 'suggestion', bold: true })
    segs.push({ text: truncate(o.slug ? full : baseName(full) || full, o.name), bold: true })
    if (where && o.branch > 0) segs.push({ text: ` @ ${truncate(where, o.branch)}` })
    if (dirty) segs.push({ text: '*', color: 'warning' })
    if (o.wt && h.worktree) segs.push({ text: ` (wt ${truncate(h.worktree, 24)})`, dim: true })
    if (o.acct && h.gh_account) segs.push({ text: ` (${truncate(h.gh_account, 24)})`, dim: true })
    if (o.root > 0 && root) segs.push({ text: ` (root: ${truncate(root, o.root)})`, color: 'warning' })
    return segs
  }
  const all = [
    build({ name: 48, slug: true, branch: 40, wt: true, acct: true, root: 20 }),
    build({ name: 48, slug: true, branch: 40, wt: false, acct: true, root: 20 }),
    build({ name: 48, slug: true, branch: 40, wt: false, acct: false, root: 20 }),
    build({ name: 24, slug: false, branch: 24, wt: false, acct: false, root: 20 }),
    build({ name: 16, slug: false, branch: 14, wt: false, acct: false, root: 10 }),
    build({ name: 16, slug: false, branch: 0, wt: false, acct: false, root: 0 }),
  ]
  // Identical neighbours would waste a shrink step.
  const out: Variants = []
  for (const v of all) if (out.length === 0 || joinText(out[out.length - 1]) !== joinText(v)) out.push(v)
  return out
}

function itemFor(field: Field, snap: Snapshot, cfg: HudConfig): Item | null {
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
    case 'ci':
      return cfg.ci && h?.ci ? one(...ciVariants(h.ci)) : null
    case 'rate':
      return snap.rateUsed === null ? null : one([{ text: `5h ${Math.round(snap.rateUsed)}%` }])
    case 'cost':
      return snap.costUsd === null ? null : one([{ text: `$${snap.costUsd.toFixed(2)}` }])
    case 'lastat': {
      const at = h?.last_input_at
      return at ? one([{ text: `you ${formatStamp(at)}`, dim: true }], [{ text: formatStamp(at), dim: true }]) : null
    }
    case 'ver':
      // `ver0` (installed only, or `(latest)`) shrinks to `✓` then is dropped early; `ver` (an update is available) is kept almost to the end.
      return cfg.version && h?.plugin ? { field: versionState(h.plugin) === 'available' ? 'ver' : 'ver0', variants: versionVariants(h.plugin), at: 0 } : null
  }
}

/**
 * `queue 44 = 30 ready | 6 blocked | 3 decision | 2 external | 3 epic` (the labels in full, used by details),
 * shrinking to `queue 44 = 30r 6b 3d 2e 3x`, then `queue 30/44`. `claimed` (held by another session) shows only above 0.
 * `full` starts at the spelled-out form; the band starts at the compact one.
 */
export function queueVariants(q: Queue, full: boolean): Variants {
  const parts: Array<[string, string, number]> = [['ready', 'r', q.ready], ['blocked', 'b', q.blocked], ['decision', 'd', q.decision], ['external', 'e', q.external], ['epic', 'x', q.epic]]
  if (q.claimed > 0) parts.push(['claimed', 'c', q.claimed])
  const long: Seg[] = [{ text: `queue ${q.total} = ` }]
  parts.forEach(([word, , n], i) => {
    if (i > 0) long.push({ text: ' | ', dim: true })
    long.push({ text: `${n} ${word}`, dim: n === 0 && word !== 'ready', color: word === 'ready' && n > 0 ? 'success' : undefined })
  })
  const short: Seg[] = [{ text: `queue ${q.total} = ` }, ...parts.flatMap(([, ch, n], i): Seg[] => [...(i > 0 ? [{ text: ' ' }] : []), { text: `${n}${ch}`, dim: n === 0 && ch !== 'r', color: ch === 'r' && n > 0 ? 'success' : undefined }])]
  const tiny: Seg[] = [{ text: `queue ${q.ready}/${q.total}`, color: q.ready > 0 ? 'success' : undefined }]
  return full ? [long, short, tiny] : [short, tiny]
}

/** Band order per mode; `fields` in the config only switches members of the mode on or off. */
const ORDER = {
  off: ['repo', 'branch', 'task', 'jobs', 'queue', 'ci', 'rate', 'cost', 'lastat', 'ver'],
  on: ['ap', 'ctx', 'jobs', 'queue', 'ci', 'rate', 'cost', 'lastat', 'ver'],
} as const

/** Shrink and drop steps, applied one at a time until the row fits (see README). */
const STEPS = {
  off: ['drop:stale', 'drop:cost', 'drop:rate', 'drop:lastat', 'step:queue', 'step:ver0', 'drop:ver0', 'drop:queue', 'step:ver', 'step:ver', 'step:ci', 'step:ci', 'step:jobs', 'step:task', 'step:task', 'step:repo', 'step:repo', 'drop:task', 'step:repo', 'step:repo', 'step:repo', 'drop:ver'],
  on: ['drop:stale', 'drop:cost', 'drop:rate', 'drop:lastat', 'step:apstats', 'step:apstats', 'drop:apstats', 'step:queue', 'step:ver0', 'drop:ver0', 'drop:queue', 'step:ver', 'step:ver', 'step:ci', 'step:ci', 'step:jobs', 'step:ctx', 'step:ap', 'step:ap', 'drop:ctx', 'drop:ver'],
}

function render(items: Item[]): Seg[] {
  const out: Seg[] = []
  items.forEach((it, i) => {
    if (i > 0) out.push({ text: SEP, dim: true })
    out.push(...it.variants[it.at])
  })
  return out
}

/**
 * The band: ALWAYS one row (or none). Two modes: autopilot ON (AP, ctx, CI, last input)
 * and OFF (repo, branch, task, CI, last input). The tier only picks how abbreviated each
 * field starts; when the row is still too wide the steps in STEPS shrink or drop fields.
 * Returns [] when there is nothing to show (the caller then yields to the engine).
 */
export function bandRows(snap: Snapshot, cfg: HudConfig, columns: number): Seg[][] {
  const tier = tierOf(columns)
  const width = Math.max(20, columns - 2) // the band has one column of padding each side
  const mode = isApOn(snap) ? 'on' : 'off'
  const start = tier === 'wide' ? 0 : tier === 'compact' ? 1 : 2
  let items: Item[] = []
  for (const f of ORDER[mode]) {
    // The version segment is switched by its own `version` key, not by `fields`.
    if (f !== 'ver' && !cfg.fields.includes(f)) continue
    const it = itemFor(f, snap, cfg)
    // The tier sets how detailed the AP, ctx and CI cells start; the rest start full and shrink only to fit.
    if (it) items.push({ ...it, at: f === 'ap' || f === 'ctx' || f === 'ci' ? Math.min(start, it.variants.length - 1) : 0 })
    // The 24h progress cell rides with the AP cell (same switch) and is the first thing to shrink.
    if (f === 'ap' && it) {
      const sv = apStatsVariants(snap.helper!.autopilot!)
      if (sv) items.push({ field: 'apstats', variants: sv, at: Math.min(start, sv.length - 1) })
    }
  }
  // The repo cell already carries the branch (or `detached <sha>`): do not say it twice.
  if (items.some(it => it.field === 'repo')) items = items.filter(it => it.field !== 'branch')
  if (snap.stale) items.push({ field: 'stale', variants: [[{ text: 'stale', dim: true }]], at: 0 })
  if (items.length === 0) return []

  const row = fitRow(items, STEPS[mode], width)
  return row.length === 0 ? [] : [row]
}

/**
 * Applies the shrink and drop steps one at a time until the row fits `width`, then, as a last
 * resort on absurdly narrow terminals, cuts the text (never wraps). [] when nothing is left.
 */
function fitRow(all: Item[], steps: readonly string[], width: number): Seg[] {
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
    let over = widthOf(row) - width
    for (let i = row.length - 1; i >= 0 && over > 0; i--) {
      const cut = Math.min(over, row[i].text.length)
      row[i] = { ...row[i], text: row[i].text.slice(0, row[i].text.length - cut) }
      over -= cut
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

/** Detail lines, drop and shrink order per line (see README "Details"). */
const DETAIL_STEPS = {
  where: ['drop:stale', 'step:task', 'step:task', 'step:repo', 'step:repo', 'drop:task', 'step:repo', 'step:repo', 'step:repo'],
  usage: ['step:cost', 'step:rate', 'step:ctx', 'step:ctx', 'drop:cost', 'drop:rate', 'drop:ctx'],
  jobs: ['step:total', 'drop:total', 'drop:parked', 'drop:state'],
  queue: ['step:queue', 'step:queue'],
  ap: ['step:apstats', 'step:apstats', 'drop:apstats', 'step:wake', 'step:wake', 'step:ci', 'step:ci', 'step:ci', 'step:ap', 'step:ap', 'step:ap', 'drop:wake'],
  // The version label is never dropped here (the link goes first, then the stamp shrinks, then the label narrows to ✓/↑).
  you: ['drop:url', 'step:lastat', 'step:lastat', 'step:ver', 'step:ver', 'step:ver0'],
} as const

/**
 * `/hud details`: the one-row band expanded to up to six live lines, each cut to the terminal
 * width with the same variant shrinking as the band. Lines with nothing to say are left out.
 *   1 repo, branch, dirty mark, claimed task   2 context left, 5-hour limit used, API-equivalent cost
 *   3 jobs state, parked, total (ledger; the running jobs are not listed, the band's WORKING (N) has the count)
 *   4 queue breakdown (dev/TODO/queue.md; no queue, no line)
 *   5 autopilot, next loop time, and CI   6 last prompt (stamp and age), the ccxp version label and the plugin's GitHub URL
 * Labels are spelled out in full here; the one-row band keeps the short forms (ctx, 5h, $).
 * It ignores `fields`: the lines are the view. [] when there is no data at all.
 */
export function detailRows(snap: Snapshot, cfg: HudConfig, columns: number, nowMs: number = Date.now()): Seg[][] {
  const h = snap.helper
  const width = Math.max(20, columns - 2)
  const one = (field: string, ...v: Seg[][]): Item => ({ field, variants: v, at: 0 })
  const pick = (f: Field) => itemFor(f, snap, cfg)
  const lines: Seg[][] = []
  const add = (items: Array<Item | null>, steps: readonly string[]) => {
    const row = fitRow(items.filter((x): x is Item => x !== null), steps, width)
    if (row.length > 0) lines.push(row)
  }

  // 1. where you are
  add(
    [pick('repo'), pick('task'), snap.stale ? one('stale', [{ text: 'stale', dim: true }]) : null],
    DETAIL_STEPS.where,
  )

  // 2. context, rate limit and cost, spelled out. context is what is LEFT (the band's ctx), 5-hour limit is the
  // share of the subscription's rolling 5-hour window USED, cost is the engine's API-price estimate for this session.
  const usage: Array<Item | null> = []
  if (snap.ctxLeft !== null) {
    const left = Math.round(snap.ctxLeft)
    const color = ctxTone(left, cfg)
    usage.push(one('ctx', [{ text: `context ${left}% left ${meter(left)}`, color }], [{ text: `context ${left}% left`, color }], [{ text: `ctx ${left}%`, color }]))
  }
  if (snap.rateUsed !== null) {
    const used = Math.round(snap.rateUsed)
    usage.push(one('rate', [{ text: `5-hour limit ${used}% used` }], [{ text: `5h limit ${used}%` }]))
  }
  if (snap.costUsd !== null) {
    const usd = `$${snap.costUsd.toFixed(2)}`
    usage.push(one('cost', [{ text: `API-equivalent cost ${usd}` }], [{ text: `cost ${usd}` }]))
  }
  add(usage, DETAIL_STEPS.usage)

  // 3. jobs, from the ledger (no ledger: no line)
  const led = h?.ledger
  if (led) {
    const state = jobState(led.running.length)
    const parked = led.parked.length
    add(
      [
        one('state', [{ text: state.text, color: state.color }]),
        one('parked', [{ text: `parked ${parked}`, dim: parked === 0 }]),
        one('total', [{ text: `total jobs ${led.lifetime_jobs}`, dim: true }], [{ text: `total ${led.lifetime_jobs}`, dim: true }]),
      ],
      DETAIL_STEPS.jobs,
    )
  }

  // 4. the queue breakdown, labels in full
  if (h?.queue) add([one('queue', ...queueVariants(h.queue, true))], DETAIL_STEPS.queue)

  // 5. autopilot and CI
  const ap = h?.autopilot
  let apItem: Item | null = null
  if (ap) {
    const full = apVariants(ap)
    const withStatus: Seg[] = ap.prefix === '[p]' || !ap.status ? full[0] : [full[0][0], { text: `${truncate(ap.status, 14)} ` }, ...full[0].slice(1)]
    apItem = one('ap', withStatus, ...full)
  } else if (h) {
    apItem = one('ap', [{ text: 'AP ', bold: true }, { text: 'off', dim: true }])
  }
  let ciItem: Item | null = null
  if (cfg.ci && h?.ci) {
    const look = CI_LOOK[h.ci.state]
    const date = h.ci.at > 0 ? ` ${shortDate(h.ci.at)}` : ''
    const mk = (workflow: boolean, word: boolean): Seg[] => [
      { text: 'CI ', bold: true },
      ...(workflow ? [{ text: `(${truncate(cfg.ci!.workflow, 30)}) `, dim: true }] : []),
      { text: `${look.glyph}${word ? ` ${look.word}` : ''}${date}`, color: look.color },
      ...ageSegs(h.ci.at, nowMs),
    ]
    ciItem = one('ci', mk(true, true), mk(false, true), mk(false, false), ...ciVariants(h.ci).slice(2))
  }
  // The next loop: the clock time and the wait; paused says so (the stored time is stale then); nothing when unknown.
  let wakeItem: Item | null = null
  if (ap?.prefix === '[p]') {
    wakeItem = one('wake', [{ text: 'next loop paused', dim: true }])
  } else if (ap?.busy) {
    // A cycle is running: name its task rather than a due time that is stale until the cycle ends.
    wakeItem = one('wake', [{ text: ap.current_task ? `loop on ${ap.current_task}` : 'loop running' }])
  } else if (ap && ap.next_wake_at > 0) {
    const wait = formatIn(ap.next_wake_at, nowMs)
    const clock = formatStamp(ap.next_wake_at, nowMs)
    wakeItem =
      wait === 'now'
        ? one('wake', [{ text: 'next loop due', dim: true }])
        : one('wake', [{ text: `next loop ${clock} (${wait})` }], [{ text: `next loop ${wait}` }], [{ text: `next ${wait}` }])
  }
  const apStats = ap ? apStatsVariants(ap) : null
  add([apItem, apStats ? one('apstats', ...apStats) : null, wakeItem, ciItem], DETAIL_STEPS.ap)

  // 6. you: the last prompt, stamp and age
  const at = h?.last_input_at
  const verItem = pick('ver')
  // The plugin's GitHub location, as a bare URL (terminals make it cmd-clickable; no OSC 8, the renderer draws plain text).
  // From the manifest via the helper, the public URL otherwise. Shown with the version label, so only when that is.
  const urlItem = verItem && h?.plugin ? one('url', [{ text: h.plugin.url ?? PLUGIN_URL_DEFAULT, dim: true }]) : null
  if (at || verItem) {
    add(
      [at ? one('lastat', [{ text: `you ${formatStamp(at, nowMs)}`, dim: true }, ...ageSegs(at, nowMs)], [{ text: `you ${formatStamp(at, nowMs)}`, dim: true }], [{ text: formatStamp(at, nowMs), dim: true }]) : null, verItem, urlItem],
      DETAIL_STEPS.you,
    )
  }
  return lines
}

/** One plain line for surfaces with no band (VS Code `$.ui.status`), 2,000 chars at most. */
export function compactLine(snap: Snapshot, cfg: HudConfig): string {
  return bandRows(snap, cfg, 200).map(joinText).join(SEP).slice(0, 2000)
}
