// ccxp-hud config: pure functions only (no `$`), so the unit tests can pin them.
// Missing, empty or malformed input always means the defaults, which are ON.

import type { Field, HudConfig } from '../types'

export type { Field, HudConfig }

export const ALL_FIELDS: readonly Field[] = ['ap', 'ctx', 'branch', 'task', 'jobs', 'rate', 'cost', 'last']
export const BORDERS: readonly string[] = ['single', 'double', 'round', 'bold', 'singleDouble', 'doubleSingle', 'classic', 'quote']

export const DEFAULTS: HudConfig = {
  enabled: true,
  userMessage: true,
  band: true,
  userBorder: 'quote',
  userColor: 'suggestion',
  fields: ['ap', 'ctx', 'branch', 'task', 'jobs'],
  pollSeconds: 15,
  ctxWarn: 40,
  ctxCrit: 15,
}

type Raw = Record<string, unknown>

function isRecord(x: unknown): x is Raw {
  return typeof x === 'object' && x !== null && !Array.isArray(x)
}

function parseFields(x: unknown): Field[] | undefined {
  const items = typeof x === 'string' ? x.split(',') : Array.isArray(x) ? x : undefined
  if (!items) return undefined
  const out: Field[] = []
  for (const item of items) {
    const name = String(item).trim() as Field
    if (ALL_FIELDS.includes(name) && !out.includes(name)) out.push(name)
  }
  return out
}

/** Parses one config file's text into the keys that are valid; never throws. */
export function parseConfigText(text: string | undefined | null): Partial<HudConfig> {
  if (!text) return {}
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return {}
  }
  if (!isRecord(raw)) return {}
  const out: Partial<HudConfig> = {}
  for (const key of ['enabled', 'userMessage', 'band'] as const) {
    if (typeof raw[key] === 'boolean') out[key] = raw[key] as boolean
  }
  if (typeof raw.userBorder === 'string') out.userBorder = raw.userBorder
  if (typeof raw.userColor === 'string' && raw.userColor.trim() !== '') out.userColor = raw.userColor.trim()
  const fields = parseFields(raw.fields)
  if (fields) out.fields = fields
  for (const key of ['pollSeconds', 'ctxWarn', 'ctxCrit'] as const) {
    if (typeof raw[key] === 'number' && Number.isFinite(raw[key])) out[key] = raw[key] as number
  }
  return out
}

/** Project over user over defaults, with the numeric keys clamped. */
export function mergeConfig(user: Partial<HudConfig>, project: Partial<HudConfig>): HudConfig {
  const cfg: HudConfig = { ...DEFAULTS, ...user, ...project }
  cfg.pollSeconds = Math.max(5, Math.round(cfg.pollSeconds))
  cfg.ctxWarn = Math.min(100, Math.max(0, cfg.ctxWarn))
  cfg.ctxCrit = Math.min(cfg.ctxWarn, Math.max(0, cfg.ctxCrit))
  return cfg
}

/** The border to draw, or undefined for none (an unknown name draws no border). */
export function borderOf(cfg: HudConfig): string | undefined {
  return BORDERS.includes(cfg.userBorder) ? cfg.userBorder : undefined
}

/** The user-level file path and the optional per-project override. */
export function configPaths(env: { configDir?: string; home?: string }, projectRoot?: string) {
  const base = env.configDir || (env.home ? `${env.home}/.claude` : undefined)
  return {
    user: base ? `${base}/ccxp-hud.json` : undefined,
    project: projectRoot ? `${projectRoot}/.claude/ccxp-hud.json` : undefined,
  }
}

/** Text of the user file after `/hud on|off`: other keys kept, `enabled` set. */
export function withEnabled(text: string | undefined | null, enabled: boolean): string {
  let raw: Raw = {}
  try {
    const parsed: unknown = text ? JSON.parse(text) : {}
    if (isRecord(parsed)) raw = parsed
  } catch {
    raw = {}
  }
  return JSON.stringify({ ...raw, enabled }, null, 2) + '\n'
}

/** Where the heartbeat for a session lives (the statusline reads the same path). */
export function heartbeatPath(env: { configDir?: string; home?: string }, sessionId: string): string | undefined {
  const base = env.configDir || (env.home ? `${env.home}/.claude` : undefined)
  if (!base || !sessionId || /[\\/]/.test(sessionId) || sessionId === '.' || sessionId === '..') return undefined
  return `${base}/state/hud-active/${sessionId}`
}
