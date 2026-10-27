// ccxp-hud model: pure snapshot + band layout. No `$`, so it is unit-testable.

import type { Autopilot, Field, HelperData, HudConfig, Jobs, Ledger, Snapshot } from '../types'

export type { Autopilot, HelperData, Jobs, Snapshot }

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

function str(x: unknown): string {
  return typeof x === 'string' ? x : ''
}

function strOrNull(x: unknown): string | null {
  return typeof x === 'string' && x !== '' ? x : null
}

function num(x: unknown): number {
  return typeof x === 'number' && Number.isFinite(x) ? x : 0
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
      parked: num(l.parked),
      parked_ids: (Array.isArray(l.parked_ids) ? l.parked_ids : []).filter((x): x is string => typeof x === 'string'),
      next_job: num(l.next_job),
      updated_at: str(l.updated_at),
    }
  }
  return {
    task_id: str(r.task_id),
    task_title: str(r.task_title),
    branch: str(r.branch),
    worktree: str(r.worktree),
    cwd: str(r.cwd),
    repo: strOrNull(r.repo),
    repo_root: strOrNull(r.repo_root),
    head: str(r.head),
    dirty: typeof r.dirty === 'number' && Number.isFinite(r.dirty) ? r.dirty : null,
    gh_account: strOrNull(r.gh_account),
    autopilot,
    ledger,
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

/** Green above `ctxWarn`, yellow down to `ctxCrit`, red below. */
export function ctxTone(left: number, cfg: Pick<HudConfig, 'ctxWarn' | 'ctxCrit'>): Tone {
  if (left > cfg.ctxWarn) return 'success'
  if (left >= cfg.ctxCrit) return 'warning'
  return 'error'
}

export function meter(left: number, width = 10): string {
  const filled = Math.max(0, Math.min(width, Math.round((left / 100) * width)))
  return '▓'.repeat(filled) + '░'.repeat(width - filled)
}

export type Seg = { text: string; color?: string; dim?: boolean; bold?: boolean }

const AP_LOOK: Record<string, { glyph: string; word: string; short: string; color: string }> = {
  '[r]': { glyph: '●', word: 'running', short: 'run', color: 'success' },
  '[b]': { glyph: '●', word: 'running', short: 'run', color: 'success' }, // backing off is still running; ⚠ carries the stuck count
  '[s]': { glyph: '○', word: 'stopped', short: 'stop', color: 'inactive' },
  '[p]': { glyph: '⏸', word: 'paused', short: 'pause', color: 'warning' },
}

/** A stop reason that means something went wrong (not elapsed / queue-empty / user-requested). */
export function isFailureStop(reason: string): boolean {
  return /fail|error|crash|abort/i.test(reason)
}

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

const widthOf = (segs: Seg[]) => segs.reduce((n, s) => n + s.text.length, 0)

/** A band block: fixed segments plus an optional part that fills whatever room is left on its row. */
type Block = { segs: Seg[]; grow?: (room: number) => Seg[]; minRoom?: number }

function apBlock(snap: Snapshot, tier: Tier): Block | null {
  const ap = snap.helper?.autopilot
  if (!ap) return null
  const look = { ...(AP_LOOK[ap.prefix] ?? { glyph: '·', word: ap.status, short: ap.status.slice(0, 5), color: 'inactive' }) }
  if (ap.prefix === '[s]' && isFailureStop(ap.stop_reason)) look.color = 'error'
  const word = tier === 'wide' ? look.word : tier === 'compact' ? look.short : ''
  const segs: Seg[] = [
    { text: 'AP ', bold: true },
    { text: word ? `${look.glyph} ${word}` : look.glyph, color: look.color },
    // Elapsed over requested hours: the "h" stays so 13/24 can never read as cycles.
    { text: ` ${ap.elapsed_hr}/${ap.requested_hr}h` },
  ]
  if (ap.stuck > 0) segs.push({ text: ` ⚠${ap.stuck}`, color: 'error' })
  if (tier === 'wide') segs.push({ text: ` · cycle ${ap.cycle}` })
  else if (tier === 'compact') segs.push({ text: ` c${ap.cycle}` })
  const merged = tier === 'wide' ? `✓${ap.merged} merged` : `✓${ap.merged}`
  segs.push({ text: ' ' }, { text: merged, color: ap.merged > 0 ? 'success' : undefined, dim: ap.merged === 0 })
  return { segs }
}

function jobsBlock(snap: Snapshot, tier: Tier): Block | null {
  const l = snap.helper?.ledger
  if (!l) return null
  const run = l.running.length
  const segs: Seg[] = []
  const head = tier === 'wide' ? 1 : 0 // the "jobs " label is not a counter
  if (tier === 'wide') segs.push({ text: 'jobs ' })
  const dot = (): void => {
    if (segs.length > head) segs.push({ text: ' · ' })
  }
  if (run > 0) segs.push({ text: `run ${run}`, color: 'success' })
  if (l.parked > 0) {
    dot()
    segs.push({ text: `park ${l.parked}`, color: 'warning' })
  }
  if (tier !== 'tiny') {
    dot()
    segs.push({ text: `tot ${l.lifetime_jobs}`, dim: run + l.parked > 0 })
  } else if (segs.length === head) segs.push({ text: `tot ${l.lifetime_jobs}`, dim: true })
  if (run === 0 || tier === 'tiny') return { segs }
  // Short ids when narrow, ids with titles when wide; only whole items, then "+N".
  const grow = (room: number): Seg[] => {
    const items = l.running.map(j => {
      const id = `r${j.job}`
      return tier === 'wide' && j.title ? `${id} ${truncateWords(j.title, 28)}` : id
    })
    const sep = tier === 'wide' ? ', ' : ' '
    let out = ''
    let shown = 0
    for (const item of items) {
      const next = out ? out + sep + item : item
      const rest = items.length - shown - 1
      // Reserve room for the " +N" tail unless this is the last item.
      if (next.length + (rest > 0 ? ` +${rest}`.length : 0) > room - 4) break
      out = next
      shown += 1
    }
    if (shown === 0) return []
    const hidden = items.length - shown
    return [{ text: ` (${out}${hidden > 0 ? ` +${hidden}` : ''})`, dim: true }]
  }
  // Wide: a running list needs real room, so it takes its own row rather than a 7-column scrap.
  return { segs, grow, minRoom: tier === 'wide' ? 90 : 12 }
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

/**
 * Which repo the session is working in, following the session cwd:
 * `repo: owner/name @ branch* (wt X) (account)`, a leading `→` for a couple of
 * refreshes after the repo changed, and `(root: X)` when a shell cd left the
 * session root behind. Outside a git repo it is just the folder name.
 * The branch is part of this block, so the separate `branch` field steps aside (see bandRows).
 */
function repoBlock(snap: Snapshot, tier: Tier, width: number): Block | null {
  const h = snap.helper
  if (!h) return null
  // Most to least detail; the first one that fits the row wins (a long branch or account must not overflow).
  const attempts: { tier: Tier; wt: boolean; root: boolean; acct: boolean }[] = [
    { tier, wt: true, root: true, acct: true },
    { tier, wt: false, root: true, acct: true },
    { tier, wt: false, root: false, acct: true },
    { tier, wt: false, root: false, acct: false },
  ]
  if (tier !== 'tiny') attempts.push({ tier: 'tiny', wt: false, root: false, acct: false })
  let last: Block | null = null
  for (const a of attempts) {
    last = repoSegs(snap, a.tier, a.wt, a.root, a.acct)
    if (last === null || widthOf(last.segs) <= width) return last
  }
  return last
}

function repoSegs(snap: Snapshot, tier: Tier, wt: boolean, withRoot: boolean, acct: boolean): Block | null {
  const h = snap.helper!
  const segs: Seg[] = []
  if (snap.moved) segs.push({ text: '→ ', color: 'suggestion', bold: true })
  const root = withRoot && snap.sessionRoot && h.cwd && !isWithin(h.cwd, snap.sessionRoot) ? baseName(snap.sessionRoot) : ''
  const rootSeg: Seg[] = root && tier !== 'tiny' ? [{ text: ` (root: ${truncate(root, 20)})`, color: 'warning' }] : []
  if (!h.repo) {
    const dir = baseName(h.cwd)
    if (!dir) return null
    segs.push({ text: tier === 'wide' ? `dir: ${truncate(dir, 40)}` : truncate(dir, tier === 'tiny' ? 16 : 24), dim: true }, ...rootSeg)
    return { segs }
  }
  const dirty = h.dirty !== null && h.dirty > 0
  if (tier === 'tiny') {
    segs.push({ text: truncate(baseName(h.repo), 16), bold: true })
    if (dirty) segs.push({ text: '*', color: 'warning' })
    return { segs }
  }
  if (tier === 'wide') segs.push({ text: 'repo: ', dim: true })
  segs.push({ text: tier === 'wide' ? truncate(h.repo, 48) : truncate(baseName(h.repo), 24), bold: true })
  const where = h.branch ? (tier === 'wide' ? truncate(h.branch, 40) : truncate(h.branch, 24)) : h.head ? `detached ${h.head}` : ''
  if (where) segs.push({ text: ` @ ${where}` })
  if (dirty) segs.push({ text: '*', color: 'warning' })
  if (wt && tier === 'wide' && h.worktree) segs.push({ text: ` (wt ${truncate(h.worktree, 24)})`, dim: true })
  if (acct && h.gh_account) segs.push({ text: ` (${truncate(h.gh_account, 24)})`, dim: true })
  segs.push(...rootSeg)
  return { segs }
}

function blockFor(field: Field, snap: Snapshot, cfg: HudConfig, tier: Tier, width: number): Block | null {
  const h = snap.helper
  switch (field) {
    case 'repo':
      return repoBlock(snap, tier, width)
    case 'ap':
      return apBlock(snap, tier)
    case 'ctx': {
      if (snap.ctxLeft === null) return null
      const left = Math.round(snap.ctxLeft)
      return { segs: [{ text: tier === 'wide' ? `ctx ${left}% ${meter(left)}` : `ctx ${left}%`, color: ctxTone(left, cfg) }] }
    }
    case 'branch': {
      const b = h?.branch
      if (!b || tier === 'tiny') return null
      const wt = tier === 'wide' && h?.worktree ? ` (wt ${h.worktree})` : ''
      return { segs: [{ text: ` ${tier === 'wide' ? b : truncate(b, 24)}${wt}` }] }
    }
    case 'task': {
      // Unclaimed means nothing to show: no placeholder cell.
      if (!h?.task_id || tier === 'tiny') return null
      if (tier === 'compact') return { segs: [{ text: h.task_id }], grow: room => (h.task_title && room > 12 ? [{ text: ' ' + truncateWords(h.task_title, Math.min(room - 1, 32)) }] : []) }
      return { segs: [{ text: truncateWords(`${h.task_id} ${h.task_title}`.trim(), 70) }] }
    }
    case 'jobs':
      return jobsBlock(snap, tier)
    case 'rate':
      return snap.rateUsed === null ? null : { segs: [{ text: `5h ${Math.round(snap.rateUsed)}%` }] }
    case 'cost':
      return snap.costUsd === null ? null : { segs: [{ text: `$${snap.costUsd.toFixed(2)}` }] }
    case 'lastat': {
      const at = h?.last_input_at
      return at && tier !== 'tiny' ? { segs: [{ text: `you ${formatStamp(at)}`, dim: true }] } : null
    }
  }
}

const SEP = ' │ '

/** Greedy row packing; null when the blocks need more than `maxRows` rows. */
function pack(blocks: Block[], width: number, maxRows: number): Block[][] | null {
  const rows: Block[][] = []
  let used = 0
  for (const b of blocks) {
    const w = widthOf(b.segs)
    const row = rows[rows.length - 1]
    const fits = row && used + SEP.length + w <= width
    // A growing block (job ids) wants minRoom spare columns; else it starts a new row when it may.
    const cramped = b.minRoom !== undefined && fits && width - (used + SEP.length + w) < b.minRoom && rows.length < maxRows
    if (fits && !cramped) {
      row.push(b)
      used += SEP.length + w
    } else {
      rows.push([b])
      used = w
    }
    if (rows.length > maxRows) return null
  }
  return rows
}

/**
 * The band as rows of segments, laid out for the terminal width (tiny / compact / wide).
 * Sections with nothing to say are dropped, not padded. When the blocks do not fit the
 * rows allowed (one row when tiny, two when compact, three when wide) the least important ones are dropped.
 * Empty when there is nothing to show (the caller then yields to the engine).
 */
export function bandRows(snap: Snapshot, cfg: HudConfig, columns: number): Seg[][] {
  const tier = tierOf(columns)
  const width = Math.max(20, columns - 2) // the band has one column of padding each side
  const maxRows = tier === 'tiny' ? 1 : tier === 'compact' ? 2 : 3
  const entries: { field: string; block: Block }[] = []
  for (const f of cfg.fields) {
    const block = blockFor(f, snap, cfg, tier, width)
    if (block) entries.push({ field: f, block })
  }
  // The repo block already carries the branch: do not say it twice.
  if (entries.some(e => e.field === 'repo')) {
    const i = entries.findIndex(e => e.field === 'branch')
    if (i >= 0) entries.splice(i, 1)
  }
  if (snap.stale) entries.push({ field: 'stale', block: { segs: [{ text: 'stale', dim: true }] } })
  if (entries.length === 0) return []

  // Keep order as configured, but when space runs out drop in this order: lastat, cost, rate, branch, task.
  const droppable = ['lastat', 'cost', 'rate', 'branch', 'task', 'jobs']
  let kept = entries
  while (kept.length > 1 && pack(kept.map(e => e.block), width, maxRows) === null) {
    const victim = droppable.map(f => kept.findIndex(e => e.field === f)).find(i => i >= 0)
    kept = victim === undefined ? kept.slice(0, -1) : kept.filter((_, i) => i !== victim)
  }
  const rows = pack(kept.map(e => e.block), width, maxRows) ?? [kept.map(e => e.block).slice(0, 1)]

  return rows.map(row => {
    const used = widthOf(row.flatMap(b => b.segs)) + SEP.length * (row.length - 1)
    let room = width - used
    const out: Seg[] = []
    row.forEach((b, i) => {
      if (i > 0) out.push({ text: SEP, dim: true })
      out.push(...b.segs)
      if (b.grow && room > 0) {
        const extra = b.grow(room)
        out.push(...extra)
        room -= widthOf(extra)
      }
    })
    return out
  })
}

/** One plain line for surfaces with no band (VS Code `$.ui.status`), 2,000 chars at most. */
export function compactLine(snap: Snapshot, cfg: HudConfig): string {
  const rows = bandRows(snap, cfg, 200)
  return rows.map(r => r.map(s => s.text).join('')).join(SEP).slice(0, 2000)
}
