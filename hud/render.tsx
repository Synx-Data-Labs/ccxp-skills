// ccxp-hud trees. The element constructors come from `$.ui.resolve(e)` and are
// passed in, so these stay free of `$` and the tests can drive them.

import type { HudConfig, Snapshot } from '../types'
import { USER_TEXT_COLOR, borderOf } from './config'
import { bandRows, detailRows } from './model'

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
 * five detail lines instead of the one row, capped at `maxRows`; with no detail data it falls back
 * to the one row.
 */
export function bandTree(
  ui: { Box: any; Text: any },
  snap: Snapshot,
  cfg: HudConfig,
  columns: number,
  expanded = false,
  maxRows = 5,
) {
  const { Box, Text } = ui
  const detail = expanded ? detailRows(snap, cfg, columns).slice(0, Math.max(1, maxRows)) : []
  const rows = detail.length > 0 ? detail : bandRows(snap, cfg, columns)
  if (rows.length === 0) return null
  return (
    <Box flexDirection="column" paddingX={1}>
      {rows.map(row => (
        <Box flexDirection="row">
          {row.map(seg => (
            <Text color={seg.color} dimColor={seg.dim} bold={seg.bold}>
              {seg.text}
            </Text>
          ))}
        </Box>
      ))}
    </Box>
  )
}
