// ccxp-hud config: pure functions only (no `$`), so the unit tests can pin them.
// Missing, empty or malformed input always means the defaults, which are ON.

import type { CiConfig, Field, HudConfig } from '../types'

export type { CiConfig, Field, HudConfig }

export const ALL_FIELDS: readonly Field[] = ['repo', 'branch', 'task', 'ap', 'ctx', 'jobs', 'ci', 'rate', 'cost', 'lastat']
/** Text colour of the user's own prompt rows; the one place to change it. NO_COLOR is honoured by the renderer. */
export const USER_TEXT_COLOR = 'yellow'
export const BORDERS: readonly string[] = ['single', 'double', 'round', 'bold', 'singleDouble', 'doubleSingle', 'classic', 'quote']

export const DEFAULTS: HudConfig = {
  enabled: true,
  userMessage: true,
  band: true,
  userBorder: 'quote',
  userColor: 'suggestion',
  fields: ['repo', 'branch', 'task', 'ap', 'ctx', 'jobs', 'ci', 'lastat'],
  pollSeconds: 15,
  ctxWarn: 75,
  ctxCrit: 50,
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

const WORKFLOW_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$/
const BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$/
const REPO_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/

/** `ci` as `{workflow, branch?, repo?}` (or a bare workflow string); anything invalid means no CI segment. */
export function parseCi(x: unknown): CiConfig | undefined {
  const raw: unknown = typeof x === 'string' ? { workflow: x } : x
  if (!isRecord(raw) || typeof raw.workflow !== 'string') return undefined
  const workflow = raw.workflow.trim()
  if (!WORKFLOW_RE.test(workflow)) return undefined
  const out: CiConfig = { workflow }
  if (typeof raw.branch === 'string' && BRANCH_RE.test(raw.branch.trim())) out.branch = raw.branch.trim()
  if (typeof raw.repo === 'string' && REPO_RE.test(raw.repo.trim())) out.repo = raw.repo.trim()
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
  if ('ci' in raw) out.ci = parseCi(raw.ci)
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

/** Answers of `/hud setup` to a `ci` block (a blank means "default"); `null` hides the segment. Never throws. */
export function ciFromAnswers(a: { workflow: string; branch: string; repo: string }): { ok: true; ci: CiConfig } | { ok: false; error: string } {
  const workflow = a.workflow.trim()
  if (!WORKFLOW_RE.test(workflow)) return { ok: false, error: 'workflow must be a plain file name or id (letters, digits, . _ -; no spaces or slashes)' }
  const branch = a.branch.trim()
  if (branch && !BRANCH_RE.test(branch)) return { ok: false, error: 'branch must look like a git ref (letters, digits, . _ - /)' }
  const repo = a.repo.trim()
  if (repo && !REPO_RE.test(repo)) return { ok: false, error: 'repo must be owner/name' }
  const ci: CiConfig = { workflow }
  if (branch) ci.branch = branch
  if (repo) ci.repo = repo
  return { ok: true, ci }
}

/** True when `/hud setup` may rewrite this file text: empty, or a JSON object (never clobber an unparsable file). */
export function isRewritable(text: string | undefined | null): boolean {
  if (!text || !text.trim()) return true
  try {
    return isRecord(JSON.parse(text))
  } catch {
    return false
  }
}

/** Text of a config file after `/hud setup`: only the `ci` key is set (null hides CI); other keys are kept. */
export function withCi(text: string | undefined | null, ci: CiConfig | null): string {
  let raw: Raw = {}
  try {
    const parsed: unknown = text ? JSON.parse(text) : {}
    if (isRecord(parsed)) raw = parsed
  } catch {
    raw = {}
  }
  return JSON.stringify({ ...raw, ci }, null, 2) + '\n'
}
