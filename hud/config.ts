// ccxp-hud config: pure functions only (no `$`), so the unit tests can pin them.
// Missing, empty or malformed input always means the defaults, which are ON.

import type { CiConfig, Field, HudConfig } from '../types'
import { FILL_DEFAULT, parseFillColor } from './fill'

export type { CiConfig, Field, HudConfig }

export const ALL_FIELDS: readonly Field[] = ['repo', 'branch', 'task', 'ap', 'ctx', 'jobs', 'queue', 'ci', 'rate', 'cost', 'lastat']
/** Text colour of the user's own prompt rows; the one place to change it. NO_COLOR is honoured by the renderer. */
export const USER_TEXT_COLOR = 'yellow'
export const BORDERS: readonly string[] = ['single', 'double', 'round', 'bold', 'singleDouble', 'doubleSingle', 'classic', 'quote']

export const DEFAULTS: HudConfig = {
  enabled: true,
  userMessage: true,
  band: true,
  userBorder: 'quote',
  userColor: 'suggestion',
  fields: ['repo', 'branch', 'task', 'ap', 'ctx', 'jobs', 'queue', 'ci', 'lastat'],
  pollSeconds: 15,
  ctxWarn: 75,
  ctxCrit: 50,
  fillColor: FILL_DEFAULT,
  version: true,
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
  for (const key of ['enabled', 'userMessage', 'band', 'version'] as const) {
    if (typeof raw[key] === 'boolean') out[key] = raw[key] as boolean
  }
  if (typeof raw.userBorder === 'string') out.userBorder = raw.userBorder
  if (typeof raw.userColor === 'string' && raw.userColor.trim() !== '') out.userColor = raw.userColor.trim()
  // An old `fill` key (the retired fill toggle) is ignored: the fill is always on.
  const fillColor = parseFillColor(raw.fillColor)
  if (fillColor) out.fillColor = fillColor
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
  return withFlag(text, 'enabled', enabled)
}

function withFlag(text: string | undefined | null, key: 'enabled', value: boolean): string {
  let raw: Raw = {}
  try {
    const parsed: unknown = text ? JSON.parse(text) : {}
    if (isRecord(parsed)) raw = parsed
  } catch {
    raw = {}
  }
  return JSON.stringify({ ...raw, [key]: value }, null, 2) + '\n'
}

/** Where the heartbeat for a session lives (the statusline reads the same path). */
export function heartbeatPath(env: { configDir?: string; home?: string }, sessionId: string): string | undefined {
  const base = env.configDir || (env.home ? `${env.home}/.claude` : undefined)
  if (!base || !sessionId || /[\\/]/.test(sessionId) || sessionId === '.' || sessionId === '..') return undefined
  return `${base}/state/hud-active/${sessionId}`
}

/** Example shown when a CI answer is rejected. */
export const CI_URL_EXAMPLE = 'https://github.com/acme/widgets/actions/workflows/nightly.yml'

const HIDE_CI = new Set(['', 'none', 'no', '-', 'none (hide ci)'])

function bad(error: string): { ok: false; error: string } {
  return { ok: false, error }
}

/** Wrapper pairs a pasted answer may sit in: quotes, backticks, angle brackets, smart quotes. */
const WRAPPERS: Record<string, string> = { '"': '"', "'": "'", '`': '`', '<': '>', '\u201c': '\u201d', '\u2018': '\u2019', '(': ')', '[': ']' }

/**
 * A dialog answer as one plain string: a non-string is coerced (an array is comma-joined, an object's
 * `answer`/`text`/`value`), surrounding whitespace/newlines and wrapping quotes, backticks or angle brackets are
 * removed, and a URL followed by more text keeps only the URL. Never throws.
 */
export function cleanAnswer(answer: unknown): string {
  let t: string
  if (typeof answer === 'string') t = answer
  else if (answer == null) t = ''
  else if (Array.isArray(answer)) t = answer.map(a => cleanAnswer(a)).join(',')
  else if (typeof answer === 'object') {
    const o = answer as Record<string, unknown>
    const v = o.answer ?? o.text ?? o.value
    t = typeof v === 'string' ? v : ''
  } else t = String(answer)
  for (let i = 0; i < 4; i++) {
    t = t.trim()
    const close = WRAPPERS[t[0]]
    if (close && t.length >= 2 && t.endsWith(close)) t = t.slice(1, -1)
    else break
  }
  t = t.trim()
  if (/^(https?:\/\/|(www\.)?github\.com\/)/i.test(t)) t = t.split(/\s+/)[0].replace(/[)>"'`.,;]+$/, '')
  return t
}

/**
 * The one answer of the `/hud config` CI question, to a `ci` block: a GitHub Actions workflow URL
 * (`.../actions/workflows/<file>`, optionally `?query=branch%3A<b>`; or `.../blob|tree|raw/<branch>/.github/workflows/<file>`; a scheme-less `github.com/...` too),
 * or a bare workflow file name (repo = the current one). blank / none / no / - hide CI (`ci: null`).
 * The branch is only set when the URL carries one. Never throws.
 */
export function ciFromAnswer(answer: unknown): { ok: true; ci: CiConfig | null } | { ok: false; error: string } {
  let text = cleanAnswer(answer)
  if (HIDE_CI.has(text.toLowerCase())) return { ok: true, ci: null }
  if (/^(www\.)?github\.com\//i.test(text)) text = `https://${text}`
  if (!/^https?:\/\//i.test(text)) {
    if (WORKFLOW_RE.test(text)) return { ok: true, ci: { workflow: text } }
    return bad(`"${text.slice(0, 80)}" is neither a GitHub Actions workflow URL nor a plain workflow file name`)
  }
  let url: URL
  try {
    url = new URL(text)
  } catch {
    return bad(`"${text.slice(0, 80)}" is not a valid URL`)
  }
  if (!/^(www\.)?github\.com$/i.test(url.hostname)) return bad(`"${url.hostname}" is not github.com`)
  let seg: string[]
  try {
    seg = url.pathname.split('/').filter(Boolean).map(decodeURIComponent)
  } catch {
    return bad('the URL path is not valid')
  }
  if (seg.length < 2) return bad('the URL has no owner/repo')
  const repo = `${seg[0]}/${seg[1].replace(/\.git$/, '')}`
  if (!REPO_RE.test(repo)) return bad(`"${repo}" is not a valid owner/name`)
  let workflow: string | undefined
  let branch: string | undefined
  if (seg[2] === 'actions' && seg[3] === 'workflows' && seg[4]) {
    workflow = seg[4]
    const q = url.searchParams.get('query') ?? ''
    const m = /(?:^|\s)branch:(\S+)/.exec(q)
    if (m) branch = m[1]
  } else if ((seg[2] === 'blob' || seg[2] === 'tree' || seg[2] === 'raw') && seg.length > 6) {
    const i = seg.indexOf('.github', 4)
    if (i > 3 && seg[i + 1] === 'workflows' && seg[i + 2]) {
      workflow = seg[i + 2]
      branch = seg.slice(3, i).join('/')
    }
  } else if (seg[2] === 'actions' && seg[3] === 'runs') {
    return bad('a run URL does not name the workflow; open the workflow page (Actions, then the workflow on the left) and paste that URL')
  }
  if (!workflow) return bad('the URL does not point at a workflow file')
  if (!WORKFLOW_RE.test(workflow)) return bad(`"${workflow.slice(0, 80)}" is not a plain workflow file name`)
  const ci: CiConfig = { workflow, repo }
  if (branch) {
    if (!BRANCH_RE.test(branch)) return bad(`the branch "${branch.slice(0, 80)}" in the URL is not a plain git ref`)
    ci.branch = branch
  }
  return { ok: true, ci }
}

/** True when `/hud config` may rewrite this file text: empty, or a JSON object (never clobber an unparsable file). */
export function isRewritable(text: string | undefined | null): boolean {
  if (!text || !text.trim()) return true
  try {
    return isRecord(JSON.parse(text))
  } catch {
    return false
  }
}

/** Text of a config file after `/hud config`: `ci` (null hides CI), `fillColor` and `version` are set unless undefined (then left as they are); other keys are kept. */
export function withConfig(text: string | undefined | null, patch: { ci?: CiConfig | null; fillColor?: string; version?: boolean }): string {
  let raw: Raw = {}
  try {
    const parsed: unknown = text ? JSON.parse(text) : {}
    if (isRecord(parsed)) raw = parsed
  } catch {
    raw = {}
  }
  const next: Raw = { ...raw }
  if (patch.ci !== undefined) next.ci = patch.ci
  if (patch.fillColor !== undefined) next.fillColor = patch.fillColor
  if (patch.version !== undefined) next.version = patch.version
  return JSON.stringify(next, null, 2) + '\n'
}
