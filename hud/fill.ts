// ccxp-hud fill mode: display-width helpers and the full-width row layout. Pure (no `$`).

import type { Seg } from './model'

/** Below this many columns the band stays the plain, unfilled row. */
export const FILL_MIN_COLUMNS = 40

/** Dark and light backgrounds; any other theme (auto, unknown, unreadable) falls back to reverse video. */
export const FILL_BG = { dark: '#2a2f3a', light: '#dfe3ec' } as const

export type FillStyle = { bg: string; inverse?: false } | { bg?: undefined; inverse: true }

const ANSI_RE = /\u001b\[[0-9;:?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g

export function stripAnsi(text: string): string {
  return text.replace(ANSI_RE, '')
}

const inRanges = (cp: number, ranges: ReadonlyArray<readonly [number, number]>) => ranges.some(([a, b]) => cp >= a && cp <= b)

const ZERO: ReadonlyArray<readonly [number, number]> = [
  [0x0300, 0x036f], [0x0483, 0x0489], [0x0591, 0x05bd], [0x0610, 0x061a], [0x064b, 0x065f],
  [0x200b, 0x200f], [0x202a, 0x202e], [0x2060, 0x2064], [0x20d0, 0x20ff],
  [0xfe00, 0xfe0f], [0xfe20, 0xfe2f], [0xe0100, 0xe01ef], [0x1f3fb, 0x1f3ff], [0xe0020, 0xe007f],
]
const WIDE: ReadonlyArray<readonly [number, number]> = [
  [0x1100, 0x115f], [0x2e80, 0x303e], [0x3041, 0x33ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff],
  [0xa000, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe30, 0xfe6f], [0xff00, 0xff60],
  [0xffe0, 0xffe6], [0x231a, 0x231b], [0x23e9, 0x23ec], [0x23f0, 0x23f0], [0x23f3, 0x23f3],
  [0x25fd, 0x25fe], [0x2614, 0x2615], [0x2648, 0x2653], [0x267f, 0x267f], [0x2693, 0x2693],
  [0x26a1, 0x26a1], [0x26aa, 0x26ab], [0x26bd, 0x26be], [0x26c4, 0x26c5], [0x26ce, 0x26ce],
  [0x26d4, 0x26d4], [0x26ea, 0x26ea], [0x26f2, 0x26f3], [0x26f5, 0x26f5], [0x26fa, 0x26fa],
  [0x26fd, 0x26fd], [0x2705, 0x2705], [0x270a, 0x270b], [0x2728, 0x2728], [0x274c, 0x274c],
  [0x274e, 0x274e], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797], [0x27b0, 0x27b0],
  [0x27bf, 0x27bf], [0x2b1b, 0x2b1c], [0x2b50, 0x2b50], [0x2b55, 0x2b55],
  [0x1f300, 0x1f64f], [0x1f680, 0x1f6ff], [0x1f900, 0x1f9ff], [0x1fa70, 0x1faff], [0x20000, 0x3fffd],
]

/** Terminal columns one code point takes: 0 (combining, joiner, selector), 2 (CJK, emoji, fullwidth) or 1. */
export function charWidth(cp: number): number {
  if (cp === 0) return 0
  if (cp < 0x20 || (cp >= 0x7f && cp < 0xa0)) return 0
  if (inRanges(cp, ZERO)) return 0
  return inRanges(cp, WIDE) ? 2 : 1
}

/** Display width of text in columns; ANSI escapes cost nothing. */
export function displayWidth(text: string): number {
  let n = 0
  for (const ch of stripAnsi(text)) n += charWidth(ch.codePointAt(0)!)
  return n
}

/** Cuts text to at most `max` columns, ending in "…" when it was cut; never splits a wide character. */
export function truncateDisplay(text: string, max: number): string {
  if (max <= 0) return ''
  if (displayWidth(text) <= max) return text
  let out = ''
  let used = 0
  for (const ch of stripAnsi(text)) {
    const w = charWidth(ch.codePointAt(0)!)
    if (used + w > max - 1) break
    out += ch
    used += w
  }
  return out + '…'
}

/** Cuts a row of segments to `max` columns (the last kept segment takes the ellipsis); same row when it fits. */
export function fitSegs(segs: Seg[], max: number): Seg[] {
  if (segs.reduce((n, s) => n + displayWidth(s.text), 0) <= max) return segs
  const out: Seg[] = []
  let left = Math.max(0, max - 1) // one column kept for the ellipsis
  for (const s of segs) {
    const w = displayWidth(s.text)
    if (w <= left) {
      out.push(s)
      left -= w
      continue
    }
    const cut = truncateDisplay(s.text, left + 1).replace(/…$/, '')
    if (cut) out.push({ ...s, text: cut })
    break
  }
  const last = out[out.length - 1]
  if (last) out[out.length - 1] = { ...last, text: last.text + '…' }
  else out.push({ text: '…' })
  return out
}

/**
 * The row as a full-width bar: one space of padding each side, the content cut to fit, trailing
 * spaces to exactly `columns`. null when the width is unknown or under FILL_MIN_COLUMNS (the caller
 * draws the plain row). The result's display width is always `columns`.
 */
export function fillRow(segs: Seg[], columns: number | undefined | null, min: number = FILL_MIN_COLUMNS): Seg[] | null {
  if (typeof columns !== 'number' || !Number.isFinite(columns) || columns < min) return null
  const width = Math.floor(columns)
  const body = fitSegs(segs, width - 2)
  const used = body.reduce((n, s) => n + displayWidth(s.text), 0)
  return [{ text: ' ' }, ...body, { text: ' '.repeat(width - 1 - used) }]
}

/** Background for the person's theme (`/config` theme value); reverse video when it cannot be told. */
export function fillStyleFor(theme: unknown): FillStyle {
  const t = typeof theme === 'string' ? theme.toLowerCase() : ''
  if (t.startsWith('dark')) return { bg: FILL_BG.dark }
  if (t.startsWith('light')) return { bg: FILL_BG.light }
  return { inverse: true }
}
