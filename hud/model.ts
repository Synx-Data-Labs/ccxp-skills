// ccxp-hud model: pure snapshot + band layout. No `$`, so it is unit-testable.

import type { Autopilot, Ci, CiState, Field, HelperData, HudConfig, Jobs, Ledger, Snapshot } from '../types'

export type { Autopilot, Ci, HelperData, Jobs, Snapshot }

export const EMPTY: Snapshot = {
  helper: null,
  ctxLeft: null,
  rateUsed: null,
  costUsd: null,
  jobs: { running: 0, waiting: 0, failed: 0 },
  stale: false,
}

const CI_STATES: readonly string[] = ['passing', 'failing', 'running', 'unknown']

function str(x: unknown): string {
  return typeof x === 'string' ? x : ''
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
  const c = r.ci
  let ci: Ci | null = null
  if (typeof c === 'object' && c !== null && !Array.isArray(c)) {
    // Untrusted: only the four known states get through, nothing else is ever drawn.
    const state = str((c as Record<string, unknown>).state)
    if (CI_STATES.includes(state as CiState)) ci = { state: state as CiState, at: num((c as Record<string, unknown>).at) }
  }
  return {
    repo: str(r.repo),
    task_id: str(r.task_id),
    task_title: str(r.task_title),
    branch: str(r.branch),
    worktree: str(r.worktree),
    autopilot,
    ledger,
    ci,
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

/** Autopilot counts as ON while running (backing off included) or paused; stopped or absent is OFF. */
export function isApOn(snap: Snapshot): boolean {
  const p = snap.helper?.autopilot?.prefix
  return p === '[r]' || p === '[b]' || p === '[p]'
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

function apVariants(ap: Autopilot): Variants {
  const paused = ap.prefix === '[p]'
  const mk = (merged: string, loops: string, pause: string): Seg[] => {
    const segs: Seg[] = [{ text: 'AP ', bold: true }]
    if (pause) segs.push({ text: pause, color: 'warning' }, { text: ' ' })
    segs.push({ text: `${ap.elapsed_hr}/${ap.requested_hr}h` })
    if (ap.stuck > 0) segs.push({ text: ` ⚠${ap.stuck}`, color: 'error' })
    segs.push({ text: ` ${loops} ` }, { text: merged, color: ap.merged > 0 ? 'success' : undefined, dim: ap.merged === 0 })
    return segs
  }
  return [
    mk(`✓${ap.merged} merged`, `loops ${ap.cycle}`, paused ? '⏸ paused' : ''),
    mk(`✓${ap.merged}`, `loops ${ap.cycle}`, paused ? '⏸' : ''),
    mk(`✓${ap.merged}`, `L${ap.cycle}`, paused ? '⏸' : ''),
  ]
}

function itemFor(field: Field, snap: Snapshot, cfg: HudConfig): Item | null {
  const h = snap.helper
  const one = (...v: Seg[][]): Item => ({ field, variants: v, at: 0 })
  switch (field) {
    case 'repo':
      return h?.repo ? one([{ text: h.repo, bold: true }], [{ text: truncate(h.repo, 14), bold: true }]) : null
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
  }
}

/** Band order per mode; `fields` in the config only switches members of the mode on or off. */
const ORDER = {
  off: ['repo', 'branch', 'task', 'ci', 'rate', 'cost', 'lastat'],
  on: ['ap', 'ctx', 'ci', 'rate', 'cost', 'lastat'],
} as const

/** Shrink and drop steps, applied one at a time until the row fits (see README). */
const STEPS = {
  off: ['drop:stale', 'drop:cost', 'drop:rate', 'drop:lastat', 'step:ci', 'step:ci', 'step:task', 'step:task', 'step:branch', 'step:branch', 'drop:branch', 'drop:task', 'step:repo'],
  on: ['drop:stale', 'drop:cost', 'drop:rate', 'drop:lastat', 'step:ci', 'step:ci', 'step:ctx', 'step:ap', 'step:ap', 'drop:ctx'],
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
    if (!cfg.fields.includes(f)) continue
    const it = itemFor(f, snap, cfg)
    // The tier sets how detailed the AP, ctx and CI cells start; the rest start full and shrink only to fit.
    if (it) items.push({ ...it, at: f === 'ap' || f === 'ctx' || f === 'ci' ? Math.min(start, it.variants.length - 1) : 0 })
  }
  if (snap.stale) items.push({ field: 'stale', variants: [[{ text: 'stale', dim: true }]], at: 0 })
  if (items.length === 0) return []

  const total = () => widthOf(render(items))
  for (const step of STEPS[mode]) {
    if (total() <= width) break
    const [op, field] = step.split(':')
    if (op === 'drop') items = items.filter(it => it.field !== field)
    else items = items.map(it => (it.field === field && it.at < it.variants.length - 1 ? { ...it, at: it.at + 1 } : it))
  }
  if (items.length === 0) return []
  const row = render(items)
  // Last resort on absurdly narrow terminals: cut the text, never wrap.
  if (widthOf(row) > width) {
    let over = widthOf(row) - width
    for (let i = row.length - 1; i >= 0 && over > 0; i--) {
      const cut = Math.min(over, row[i].text.length)
      row[i] = { ...row[i], text: row[i].text.slice(0, row[i].text.length - cut) }
      over -= cut
    }
  }
  return [row]
}

/** One plain line for surfaces with no band (VS Code `$.ui.status`), 2,000 chars at most. */
export function compactLine(snap: Snapshot, cfg: HudConfig): string {
  return bandRows(snap, cfg, 200).map(joinText).join(SEP).slice(0, 2000)
}
