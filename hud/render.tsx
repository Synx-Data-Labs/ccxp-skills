// ccxp-hud trees. The element constructors come from `$.ui.resolve(e)` and are
// passed in, so these stay free of `$` and the tests can drive them.

import type { HudConfig, Snapshot } from '../types'
import { USER_TEXT_COLOR, borderOf } from './config'
import { bandRows } from './model'

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
  const h = snap.helper
  const lines: string[] = [
    h?.repo
      ? `repo: ${h.repo_slug || h.repo} @ ${h.branch || (h.head ? `detached ${h.head}` : '?')}${h.dirty ? ` (${h.dirty}${h.dirty >= 99 ? '+' : ''} changed)` : ''}${h.gh_account ? `  gh: ${h.gh_account}` : ''}  at ${h.repo_root ?? h.cwd}`
      : `dir: ${h?.cwd || '(unknown)'}`,
    `enabled: ${cfg.enabled}   band: ${cfg.band}   userMessage: ${cfg.userMessage}`,
    ap
      ? `autopilot ${ap.status} ${ap.prefix}  ${ap.elapsed_hr}/${ap.requested_hr}h  ${ap.stuck > 0 ? `⚠${ap.stuck} ` : ''}loops ${ap.cycle} ✓${ap.merged}`
      : 'autopilot: not running',
  ]
  if (ap?.last_task) lines.push(`last task: ${ap.last_task}`)
  if (ap?.stuck_reason) lines.push(`last stuck reason: ${ap.stuck_reason}`)
  if (ap?.stop_reason) lines.push(`stop reason: ${ap.stop_reason}`)
  const led = snap.helper?.ledger
  lines.push(led ? `jobs: run ${led.running.length} · total ${led.lifetime_jobs} · parked ${led.parked}${led.parked_ids.length ? ` (${led.parked_ids.join(' ')})` : ''}` : 'jobs: no ledger')
  const ci = snap.helper?.ci
  lines.push(cfg.ci ? `ci (${cfg.ci.workflow}): ${ci ? ci.state : 'no data'}` : 'ci: not configured (/hud setup)')
  lines.push(`agents: ${snap.jobs.running} running, ${snap.jobs.waiting} waiting, ${snap.jobs.failed} failed`)
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
