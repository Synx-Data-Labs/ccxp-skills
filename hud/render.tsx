// ccxp-hud trees. The element constructors come from `$.ui.resolve(e)` and are
// passed in, so these stay free of `$` and the tests can drive them.

import type { HudConfig, Snapshot } from '../types'
import { USER_TEXT_COLOR, borderOf } from './config'
import { type FillStyle, fillRow } from './fill'
import { type Seg, bandRows, detailRows } from './model'

/** True when NO_COLOR (https://no-color.org) is set and non-empty. */
export const noColorValue = (v: unknown): boolean => typeof v === 'string' && v !== ''

/** A RED CI row (every segment flagged `alert` by the model). */
export const isAlertRow = (row: Seg[]): boolean => row.length > 0 && row.some(s => s.alert)

/** A row where EVERY segment is `alert` (the band's CI row): the whole bar, padding included, is red. A details row that only holds a red CI cell next to a label and other cells marks just that cell. */
const isWholeAlertRow = (row: Seg[]): boolean => row.length > 0 && row.every(s => s.alert)

/**
 * The red row's look: bold, red text in reverse video, so the whole row is a red bar (the terminal's
 * own colours, so it reads on any theme and ignores the fill colour). With colour off the reverse
 * video stays (it is not a colour) and the state word is shouted: `✗ FAILING`.
 */
export function alertSegs(row: Seg[], noColor: boolean): Seg[] {
  const whole = isWholeAlertRow(row)
  return row.map(s => (whole || s.alert ? { ...s, bold: true, dim: false, color: noColor ? undefined : 'error', text: noColor && s.marker ? s.text.toUpperCase() : s.text } : s))
}

/** The prompt row wrapped in the configured frame; `inner` is the engine's own drawing. */
export function userMessageTree(
  ui: { Box: any; Text: any },
  cfg: HudConfig,
  inner: unknown,
) {
  const { Box, Text } = ui
  const border = borderOf(cfg)
  return (
    <Box borderStyle={border} borderColor={cfg.userColor} paddingX={border ? 1 : 0}>
      <Text color={USER_TEXT_COLOR}>{inner}</Text>
    </Box>
  )
}

/**
 * The status band, or null when there is nothing to draw. `expanded` (`/hud details`) draws the labeled sections
 * (SESSION, CLONE, BUILD, ..., one row each, wrapped rows included) instead of the one row, capped at `maxRows` (a cut says so); with no detail data it falls back
 * to the one row. With a `fill` style (always passed by the register; null only in tests) and a known width of at least FILL_MIN_COLUMNS) every row is padded
 * to `columns` and drawn on a background (or reverse video); otherwise the plain row.
 */
export function bandTree(
  ui: { Box: any; Text: any },
  snap: Snapshot,
  cfg: HudConfig,
  columns: number,
  expanded = false,
  maxRows = 8,
  fill: FillStyle | null = null,
  noColor = false,
) {
  const { Box, Text } = ui
  const detailAll = expanded ? detailRows(snap, cfg, columns) : []
  const cap = Math.max(1, maxRows)
  // Rows past the engine's height cap are not dropped silently: the last visible row says how many are hidden.
  const detail: Seg[][] = detailAll.length <= cap ? detailAll : [...detailAll.slice(0, Math.max(0, cap - 1)), [{ text: `… ${detailAll.length - Math.max(0, cap - 1)} more rows hidden (not enough height)`, dim: true }]]
  const rawRows = detail.length > 0 ? detail : bandRows(snap, cfg, columns)
  if (rawRows.length === 0) return null
  const whole = rawRows.map(isWholeAlertRow)
  const mixed = rawRows.map((row, i) => isAlertRow(row) && !whole[i])
  const rows = rawRows.map((row, i) => (whole[i] || mixed[i] ? alertSegs(row, noColor) : row))
  const alert = whole
  const filled = fill ? rows.map(row => fillRow(row, columns)) : []
  if (fill && filled.every(r => r !== null)) {
    const style = fill.bg ? { backgroundColor: fill.bg } : { inverse: true }
    // Reverse video is a Text style; a Box has no such prop.
    const boxStyle = fill.bg ? style : {}
    return (
      <Box flexDirection="column" {...boxStyle}>
        {filled.map((row, i) =>
          alert[i] ? (
            // The red row: reverse video over the whole bar (padding included), whatever the fill colour.
            <Box flexDirection="row">
              {row!.map(seg => (
                <Text color={seg.color} bold inverse>
                  {seg.text}
                </Text>
              ))}
            </Box>
          ) : (
            <Box flexDirection="row" {...boxStyle}>
              {row!.map(seg => (
                <Text color={seg.color} dimColor={seg.dim} bold={seg.bold} {...(seg.alert ? { inverse: true } : style)}>
                  {seg.text}
                </Text>
              ))}
            </Box>
          ),
        )}
      </Box>
    )
  }
  return (
    <Box flexDirection="column" paddingX={1}>
      {rows.map((row, i) => (
        <Box flexDirection="row">
          {row.map(seg => (
            <Text color={seg.color} dimColor={seg.dim} bold={seg.bold} inverse={alert[i] || seg.alert || undefined}>
              {seg.text}
            </Text>
          ))}
        </Box>
      ))}
    </Box>
  )
}
