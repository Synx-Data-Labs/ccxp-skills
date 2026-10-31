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

/**
 * The red row's look: bold, red text in reverse video, so the whole row is a red bar (the terminal's
 * own colours, so it reads on any theme and ignores the fill colour). With colour off the reverse
 * video stays (it is not a colour) and the state word is shouted: `✗ FAILING`.
 */
export function alertSegs(row: Seg[], noColor: boolean): Seg[] {
  return row.map(s => ({ ...s, bold: true, dim: false, color: noColor ? undefined : 'error', text: noColor && s.marker ? s.text.toUpperCase() : s.text }))
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
 * The status band, or null when there is nothing to draw. `expanded` (`/hud details`) draws up to
 * six detail lines instead of the one row, capped at `maxRows`; with no detail data it falls back
 * to the one row. With a `fill` style (always passed by the register; null only in tests) and a known width of at least FILL_MIN_COLUMNS) every row is padded
 * to `columns` and drawn on a background (or reverse video); otherwise the plain row.
 */
export function bandTree(
  ui: { Box: any; Text: any },
  snap: Snapshot,
  cfg: HudConfig,
  columns: number,
  expanded = false,
  maxRows = 6,
  fill: FillStyle | null = null,
  noColor = false,
) {
  const { Box, Text } = ui
  const detail = expanded ? detailRows(snap, cfg, columns).slice(0, Math.max(1, maxRows)) : []
  const rawRows = detail.length > 0 ? detail : bandRows(snap, cfg, columns)
  if (rawRows.length === 0) return null
  const alert = rawRows.map(isAlertRow)
  const rows = rawRows.map((row, i) => (alert[i] ? alertSegs(row, noColor) : row))
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
                <Text color={seg.color} dimColor={seg.dim} bold={seg.bold} {...style}>
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
            <Text color={seg.color} dimColor={seg.dim} bold={seg.bold} inverse={alert[i] || undefined}>
              {seg.text}
            </Text>
          ))}
        </Box>
      ))}
    </Box>
  )
}
