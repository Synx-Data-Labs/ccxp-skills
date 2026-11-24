// ccxp-hud `/hud config` (no dialog): a read-only report of the effective configuration. Pure: the register module passes in
// the file texts and a few plain environment values, so the unit tests can drive every branch. Prints names, paths and
// switches only, never file contents beyond the known keys, never tokens.

import type { HudConfig } from '../types'
import { ALL_FIELDS, DEFAULTS, mergeConfig, parseConfigText } from './config'

/** The environment variables the report looks at (all plain switches, paths and intervals; none can hold a secret). */
export const ENV_NAMES = [
  'CLAUDE_CONFIG_DIR', 'HOME', 'NO_COLOR',
  'HUD_CACHE_DIR', 'HUD_CACHE_TTL', 'HUD_CI_STATE_DIR', 'HUD_NIGHTLY_STATE_DIR', 'HUD_NIGHTLY_OFF', 'HUD_NIGHTLY_REPO',
  'HUD_NIGHTLY_WORKFLOW', 'HUD_NIGHTLY_TTL', 'HUD_ISSUES_STATE_DIR', 'HUD_ISSUES_TTL', 'HUD_QUEUE_STATE_DIR', 'HUD_QUEUE_FETCH_TTL',
] as const

export type ShowInput = {
  paths: { user?: string; project?: string }
  /** File text, or undefined when the file is missing or unreadable. */
  userText?: string
  projectText?: string
  env: Partial<Record<(typeof ENV_NAMES)[number], string | undefined>>
}

type Raw = Record<string, unknown>
// Keys that are retired on purpose and silently ignored; not worth a warning.
const RETIRED = new Set(['fill', 'last'])
const KNOWN = new Set(['enabled', 'userMessage', 'band', 'userBorder', 'userColor', 'fields', 'pollSeconds', 'ctxWarn', 'ctxCrit', 'fillColor', 'version', 'ci', 'queue', 'issues'])

function fileState(path: string | undefined, text: string | undefined): { line: string; keys: string[] } {
  if (!path) return { line: '(path unknown)', keys: [] }
  if (text === undefined) return { line: `${path}  missing, so defaults apply`, keys: [] }
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return { line: `${path}  not valid JSON, ignored (defaults apply; fix it or remove it)`, keys: [] }
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return { line: `${path}  not a JSON object, ignored (defaults apply)`, keys: [] }
  return { line: `${path}  found`, keys: Object.keys(raw as Raw) }
}

const show = (v: unknown): string => (v === undefined ? 'unset' : typeof v === 'string' ? v : JSON.stringify(v))
const onOff = (b: boolean): string => (b ? 'on' : 'off')

/** The effective configuration as plain text; never throws. */
export function configReport(input: ShowInput): string {
  const user = parseConfigText(input.userText)
  const project = parseConfigText(input.projectText)
  const cfg: HudConfig = mergeConfig(user, project)
  const uf = fileState(input.paths.user, input.userText)
  const pf = fileState(input.paths.project, input.projectText)
  const src = (key: string): string => (key in project ? 'project file' : key in user ? 'user file' : 'default')
  const env = input.env
  const base = env.CLAUDE_CONFIG_DIR || (env.HOME ? `${env.HOME}/.claude` : undefined)
  const L: string[] = ['ccxp-hud configuration (read-only; change it with /hud config edit or by editing the file)', '']

  L.push('Files read (project over user over defaults):', `  user     ${uf.line}`, `  project  ${pf.line}`)
  const ignored = [...new Set([...uf.keys, ...pf.keys])].filter(k => !RETIRED.has(k))
  const unknown = ignored.filter(k => !KNOWN.has(k))
  const rejected = ignored.filter(k => KNOWN.has(k) && !(k in user) && !(k in project))
  if (unknown.length) L.push(`  unknown keys (ignored): ${unknown.join(', ').slice(0, 200)}`)
  if (rejected.length) L.push(`  keys with an invalid value (ignored, default used): ${rejected.join(', ')}`)
  L.push('')

  L.push('Settings (value; default; where it comes from):')
  const row = (key: string, value: unknown, def: unknown, note = '') => L.push(`  ${key.padEnd(12)} ${show(value)}; default ${show(def)}; ${src(key)}${note}`)
  row('enabled', cfg.enabled, DEFAULTS.enabled, cfg.enabled ? '' : ' (the whole HUD is off: run /hud on)')
  row('band', cfg.band, DEFAULTS.band)
  row('userMessage', cfg.userMessage, DEFAULTS.userMessage)
  row('userBorder', cfg.userBorder, DEFAULTS.userBorder)
  row('userColor', cfg.userColor, DEFAULTS.userColor)
  row('fillColor', cfg.fillColor, DEFAULTS.fillColor)
  row('pollSeconds', cfg.pollSeconds, DEFAULTS.pollSeconds, ' (refresh every this many seconds, minimum 5)')
  row('ctxWarn', cfg.ctxWarn, DEFAULTS.ctxWarn, ' (ctx turns yellow at or below this percent left)')
  row('ctxCrit', cfg.ctxCrit, DEFAULTS.ctxCrit, ' (ctx turns red at or below this percent left)')
  row('version', cfg.version, DEFAULTS.version, ` (version cell ${onOff(cfg.version)})`)
  row('ci', cfg.ci, 'unset (no CI row)')
  row('queue', cfg.queue ?? { source: 'default-branch' }, { source: 'default-branch' })
  row('issues', cfg.issues, 'unset (no issues cell)', cfg.issues?.ghConfigDir ? ' (gh config dir is a path, never read here)' : '')
  L.push('')

  const on = cfg.fields
  const off = ALL_FIELDS.filter(f => !on.includes(f))
  L.push(`Cells switched on (fields, ${src('fields')}): ${on.join(', ') || 'none'}`)
  L.push(`Cells switched off: ${off.join(', ') || 'none'}${off.some(f => f === 'rate' || f === 'cost') ? ' (rate and cost are opt-in extras)' : ''}`)
  const hint: string[] = []
  if (on.includes('issues') && !cfg.issues) hint.push('issues is listed but draws nothing until "issues": {"repo": "owner/name"} is set')
  if (on.includes('ci') && !cfg.ci) hint.push('ci is listed but there is no "ci" setting, so no CI row')
  for (const h of hint) L.push(`  note: ${h}`)
  L.push('')

  L.push('Watched repos:')
  L.push(`  ci workflow: ${cfg.ci ? `${cfg.ci.workflow}${cfg.ci.repo ? ` in ${cfg.ci.repo}` : ' in the session repo'}${cfg.ci.branch ? ` on ${cfg.ci.branch}` : ' on the default branch'}${cfg.ci.eta === false ? ', ETA off' : ''}` : 'none'}`)
  L.push(`  nightly: ${env.HUD_NIGHTLY_OFF === '1' ? 'off (HUD_NIGHTLY_OFF=1)' : `${env.HUD_NIGHTLY_WORKFLOW || 'Nightly Orchestrator'} in ${env.HUD_NIGHTLY_REPO || 'Synx-Data-Labs/synxdb-build-pipeline'}`}`)
  L.push(`  customer issues: ${cfg.issues ? cfg.issues.repo : 'none'}`)
  L.push(`  queue: dev/TODO/queue.md, read from ${(cfg.queue?.source ?? 'default-branch') === 'default-branch' ? 'the default branch on origin' : 'the working tree'} of the session repo`)
  L.push('')

  const ttl = (name: string, def: string): string => (env[name as keyof typeof env] ? `${env[name as keyof typeof env]}s (${name})` : def)
  L.push('Refresh intervals (fixed in the helper scripts; some can be overridden by the variable shown):')
  L.push(`  ci ${Math.max(120, cfg.pollSeconds)}s | nightly ${ttl('HUD_NIGHTLY_TTL', '1800s')} | issues ${ttl('HUD_ISSUES_TTL', '900s')} | version 6h | repo and gh account ${ttl('HUD_CACHE_TTL', '60s')} | queue fetch ${ttl('HUD_QUEUE_FETCH_TTL', 'default')}`)
  L.push('')

  L.push('Cache and state folders (the helper scripts write only here):')
  const dir = (sub: string, override?: string): string => override || (base ? `${base}/state/${sub}` : `(unknown: no config dir) state/${sub}`)
  L.push(`  ci            ${dir('hud-ci', env.HUD_CI_STATE_DIR)}`)
  L.push(`  nightly       ${dir('hud-nightly', env.HUD_NIGHTLY_STATE_DIR)}`)
  L.push(`  issues        ${dir('hud-issues', env.HUD_ISSUES_STATE_DIR)}`)
  L.push(`  version       ${dir('hud-version')}`)
  L.push(`  queue         ${dir('hud-queue', env.HUD_QUEUE_STATE_DIR)}`)
  L.push(`  repo/account  ${dir('hud-cache', env.HUD_CACHE_DIR)}`)
  L.push(`  heartbeat     ${dir('hud-active')}`)
  L.push('')
  L.push(`Environment: NO_COLOR ${env.NO_COLOR ? 'set (no colours)' : 'not set'}. Explain any cell: /hud help <topic>.`)
  return L.join('\n')
}
