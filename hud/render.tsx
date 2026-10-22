// ccxp-hud trees. The element constructors come from `$.ui.resolve(e)` and are
// passed in, so these stay free of `$` and the tests can drive them.

import type { HudConfig, Snapshot } from '../types'
import { borderOf } from './config'
import { bandRows } from './model'

/** The prompt row wrapped in the configured frame; `inner` is the engine's own drawing. */
export function userMessageTree(
  ui: { Box: any },
  cfg: HudConfig,
  inner: unknown,
) {
  const { Box } = ui
  const border = borderOf(cfg)
  return (
    <Box borderStyle={border} borderColor={cfg.userColor} paddingX={border ? 1 : 0}>
      {inner}
    </Box>
  )
}

/** The status band, or null when there is nothing to draw. */
export function bandTree(
  ui: { Box: any; Text: any },
  snap: Snapshot,
  cfg: HudConfig,
  columns: number,
) {
  const { Box, Text } = ui
  const rows = bandRows(snap, cfg, columns)
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

/** The `/hud pane` detail view. */
export function paneTree(ui: { Box: any; Text: any }, snap: Snapshot, cfg: HudConfig) {
  const { Box, Text } = ui
  const ap = snap.helper?.autopilot
  const lines: string[] = [
    `enabled: ${cfg.enabled}   band: ${cfg.band}   userMessage: ${cfg.userMessage}`,
    ap
      ? `autopilot ${ap.status} ${ap.prefix}  ${ap.elapsed_hr}/${ap.requested_hr}h  stuck ${ap.stuck}/${ap.cycle}`
      : 'autopilot: not running',
  ]
  if (ap?.last_task) lines.push(`last task: ${ap.last_task}`)
  if (ap?.stuck_reason) lines.push(`last stuck reason: ${ap.stuck_reason}`)
  if (ap?.stop_reason) lines.push(`stop reason: ${ap.stop_reason}`)
  lines.push(`jobs: ${snap.jobs.running} running, ${snap.jobs.waiting} waiting, ${snap.jobs.failed} failed`)
  if (snap.ctxLeft !== null) lines.push(`context left: ${Math.round(snap.ctxLeft)}%`)
  if (snap.stale) lines.push('data is stale (the helper failed or timed out)')
  return (
    <Box flexDirection="column">
      {lines.map(l => (
        <Text>{l}</Text>
      ))}
    </Box>
  )
}
