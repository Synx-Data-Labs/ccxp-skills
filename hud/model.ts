// ccxp-hud model: pure snapshot + band layout. No `$`, so it is unit-testable.

import type { Autopilot, Field, HelperData, HudConfig, Jobs, Snapshot } from '../types'

export type { Autopilot, HelperData, Jobs, Snapshot }

export const EMPTY: Snapshot = {
  helper: null,
  ctxLeft: null,
  rateUsed: null,
  costUsd: null,
  jobs: { running: 0, waiting: 0, failed: 0 },
  stale: false,
}

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
    }
  }
  return {
    task_id: str(r.task_id),
    task_title: str(r.task_title),
    branch: str(r.branch),
    worktree: str(r.worktree),
    autopilot,
    last_input: str(r.last_input),
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

const AP_LOOK: Record<string, { glyph: string; word: string; color: string }> = {
  '[r]': { glyph: '●', word: 'run', color: 'success' },
  '[b]': { glyph: '◐', word: 'backoff', color: 'warning' },
  '[s]': { glyph: '○', word: 'stopped', color: 'inactive' },
  '[p]': { glyph: '⏸', word: 'paused', color: 'warning' },
}

export function truncate(text: string, max: number): string {
  if (max <= 0) return ''
  return text.length <= max ? text : text.slice(0, Math.max(1, max - 1)) + '…'
}

function segFor(field: Field, snap: Snapshot, cfg: HudConfig, room: number): Seg[] | null {
  const h = snap.helper
  switch (field) {
    case 'ap': {
      const ap = h?.autopilot
      if (!ap) return null
      const look = AP_LOOK[ap.prefix] ?? { glyph: '·', word: ap.status, color: 'inactive' }
      return [
        { text: 'AP ', bold: true },
        { text: `${look.glyph} ${look.word} `, color: look.color },
        { text: `${ap.elapsed_hr}/${ap.requested_hr}h  stuck ${ap.stuck}/${ap.cycle}` },
      ]
    }
    case 'ctx': {
      if (snap.ctxLeft === null) return null
      const left = Math.round(snap.ctxLeft)
      return [{ text: `ctx ${left}% ${meter(left)}`, color: ctxTone(left, cfg) }]
    }
    case 'branch': {
      const b = h?.branch
      if (!b) return null
      return [{ text: ` ${b}${h?.worktree ? ` (wt ${h.worktree})` : ''}` }]
    }
    case 'task': {
      if (!h) return null
      if (!h.task_id) return [{ text: 'no claimed task', dim: true }]
      return [{ text: truncate(`${h.task_id} ${h.task_title}`.trim(), room) }]
    }
    case 'jobs':
      return [
        {
          text: `jobs ${snap.jobs.running}▶ ${snap.jobs.waiting}⏸ ${snap.jobs.failed}✗`,
          color: snap.jobs.failed > 0 ? 'error' : undefined,
          dim: snap.jobs.running + snap.jobs.waiting + snap.jobs.failed === 0,
        },
      ]
    case 'rate':
      return snap.rateUsed === null ? null : [{ text: `5h ${Math.round(snap.rateUsed)}%` }]
    case 'cost':
      return snap.costUsd === null ? null : [{ text: `$${snap.costUsd.toFixed(2)}` }]
    case 'last': {
      const t = h?.last_input
      return t ? [{ text: truncate(`last: ${t}`, room), dim: true }] : null
    }
  }
}

/**
 * The band as rows of segments. One row from ~100 columns up, two below.
 * Empty when there is nothing to show (the caller then yields to the engine).
 */
export function bandRows(snap: Snapshot, cfg: HudConfig, columns: number): Seg[][] {
  const blocks: Seg[][] = []
  for (const f of cfg.fields) {
    const block = segFor(f, snap, cfg, Math.max(12, columns - 60))
    if (block) blocks.push(block)
  }
  if (blocks.length === 0) return []
  if (snap.stale) blocks.push([{ text: 'stale', dim: true }])

  const narrow = columns < 100
  const rows: Seg[][] = narrow ? [[], []] : [[]]
  const half = Math.ceil(blocks.length / 2)
  blocks.forEach((block, i) => {
    const row = narrow ? rows[i < half ? 0 : 1] : rows[0]
    if (row.length > 0) row.push({ text: ' │ ', dim: true })
    row.push(...block)
  })
  return rows.filter(r => r.length > 0)
}

/** One plain line for surfaces with no band (VS Code `$.ui.status`), 2,000 chars at most. */
export function compactLine(snap: Snapshot, cfg: HudConfig): string {
  const rows = bandRows(snap, cfg, 200)
  return rows.map(r => r.map(s => s.text).join('')).join(' ').slice(0, 2000)
}
