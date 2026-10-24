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
    autopilot,
    ledger,
    last_input_at: num(r.last_input_at),
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
  '[b]': { glyph: '●', word: 'run', color: 'success' }, // backing off is still running; ⚠ carries the stuck count
  '[s]': { glyph: '○', word: 'stopped', color: 'inactive' },
  '[p]': { glyph: '⏸', word: 'paused', color: 'warning' },
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

function segFor(field: Field, snap: Snapshot, cfg: HudConfig, room: number): Seg[] | null {
  const h = snap.helper
  switch (field) {
    case 'ap': {
      const ap = h?.autopilot
      if (!ap) return null
      const look = { ...(AP_LOOK[ap.prefix] ?? { glyph: '·', word: ap.status, color: 'inactive' }) }
      if (ap.prefix === '[s]' && isFailureStop(ap.stop_reason)) look.color = 'error'
      const segs: Seg[] = [
        { text: 'AP ', bold: true },
        { text: `${look.glyph} ${look.word} `, color: look.color },
        { text: `${ap.elapsed_hr}/${ap.requested_hr}h ` },
      ]
      if (ap.stuck > 0) segs.push({ text: `⚠${ap.stuck} `, color: 'error' })
      segs.push({ text: `loops ${ap.cycle} ` }, { text: `✓${ap.merged}`, color: ap.merged > 0 ? 'success' : undefined, dim: ap.merged === 0 })
      return segs
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
    case 'jobs': {
      const l = h?.ledger
      if (!l) return [{ text: 'jobs —', dim: true }]
      const run = l.running.length
      const segs: Seg[] = [
        { text: 'jobs run ' },
        { text: `${run}`, color: run > 0 ? 'success' : undefined },
        { text: ` · total ${l.lifetime_jobs} · parked ` },
        { text: `${l.parked}`, color: l.parked > 0 ? 'warning' : undefined },
      ]
      // Wide layout only (room is columns - 60): show what is running.
      if (run > 0 && room >= 40) {
        const names = l.running.map(j => `r${j.job}${j.title ? ' ' + j.title : ''}`).join(', ')
        segs.push({ text: ` (${truncate(names, room - 10)})`, dim: true })
      }
      return segs
    }
    case 'rate':
      return snap.rateUsed === null ? null : [{ text: `5h ${Math.round(snap.rateUsed)}%` }]
    case 'cost':
      return snap.costUsd === null ? null : [{ text: `$${snap.costUsd.toFixed(2)}` }]
    case 'lastat': {
      const at = h?.last_input_at
      return at ? [{ text: `you ${formatStamp(at)}`, dim: true }] : null
    }
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
