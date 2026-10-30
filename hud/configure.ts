// ccxp-hud `/hud config` logic. No `$`: the register module passes the
// few primitives in as `io`, so the unit tests can drive every branch with fakes.

import type { CiConfig } from '../types'
import { CI_URL_EXAMPLE, cleanAnswer, ciFromAnswer, isRewritable, withConfig } from './config'
import { FILL_COLOR_NAMES, FILL_DEFAULT, parseFillColor } from './fill'

export const CANCEL = 'cancel'
export const NONE = 'none (hide CI)'
export const SCOPE_USER = 'user file'
export const SCOPE_PROJECT = 'this project'
export const WRITE = 'write'
export const VERSION_SHOW = 'show (default)'
export const VERSION_HIDE = 'hide'
/** Option label of the default colour; the other palette names are offered as they are. */
export const COLOR_DEFAULT = `${FILL_DEFAULT} (default)`
/** The engine's `$.ui.ask` rejects more than this many options per question (the free-text "Other" is extra). */
export const MAX_OPTIONS = 4
export const CI_QUESTION = 'Paste a GitHub Actions workflow URL (repo and workflow are derived from it), or none to hide CI.'

export type ConfigIo = {
  /** The engine's question dialog: a chosen label, or free text typed under "Other". Rejects when dismissed. */
  ask: (question: string, options: { header: string; options: string[] }) => Promise<string>
  /** User-level and per-project config file paths (undefined when unknown). */
  paths: { user?: string; project?: string }
  read: (path: string) => Promise<string | undefined>
  write: (path: string, text: string) => Promise<void>
}

const NOTHING = 'ccxp-hud config cancelled; nothing written.'
/** The engine's dialog rejects a header over 12 characters, so keep each one short. */
export const MAX_HEADER = 12

/** Marks a rejection of the question dialog itself (dismissed or refused), as opposed to a bug in this module. */
class AskRejected extends Error {}

/** A short, single-line reason out of any thrown value. */
function reason(e: unknown): string {
  const m = e instanceof Error ? e.message : typeof e === 'string' ? e : ''
  return m.replace(/\s+/g, ' ').trim().slice(0, 120)
}
/** Asks per question before it is skipped (left unchanged) and the dialog moves on. */
const TRIES = 2

/**
 * `/hud config`: CI workflow URL, fill colour, plugin version on/off, scope, then a confirmation that shows what is written.
 * Writes only the `ci`, `fillColor` and `version` keys, only after "write". An explicit cancel or a dismissed dialog writes nothing.
 * An invalid answer is re-asked once; after a second invalid answer that setting is left unchanged and the dialog continues.
 */
export async function configureHud(rawIo: ConfigIo, preset: { ci?: string } = {}): Promise<string> {
  // Every answer comes back as a clean string (quotes, backticks, whitespace stripped; a non-string coerced).
  const io: ConfigIo = {
    ...rawIo,
    ask: async (q, o) => {
      let a: unknown
      if (o.options.length > MAX_OPTIONS) throw new Error(`ask: ${o.options.length} options, at most ${MAX_OPTIONS}`) // a programming error, not a dismissal
      try {
        a = await rawIo.ask(q, o)
      } catch (e) {
        throw new AskRejected(reason(e))
      }
      return cleanAnswer(a)
    },
  }
  try {
    const notes: string[] = []
    let ci: CiConfig | null | undefined
    let ciQuestion = CI_QUESTION
    for (let i = 0; i < TRIES && ci === undefined; i++) {
      // `/hud config <url>` supplies the first CI answer, so the CI question is only asked when it is unusable.
      const typed = i === 0 && preset.ci ? cleanAnswer(preset.ci) : undefined
      const answer = typed ?? (await io.ask(ciQuestion, { header: 'CI workflow', options: [NONE, CANCEL] }))
      if (answer === CANCEL) return NOTHING
      const res = ciFromAnswer(answer)
      if (res.ok) ci = res.ci
      else if (i + 1 < TRIES) ciQuestion = `Could not use that: ${res.error}. Example: ${CI_URL_EXAMPLE}\n${CI_QUESTION}`
      else notes.push(`CI left unchanged (${res.error})`)
    }

    let fillColor: string | undefined
    const COLOR_QUESTION = 'Which colour for the always-on fill band? Pick one, or type a #rrggbb hex colour under Other (a custom hex is used on any theme; the named colours adapt to dark and light themes). yellow, purple or a hex go under Other.'
    let colorQuestion = COLOR_QUESTION
    for (let i = 0; i < TRIES && fillColor === undefined; i++) {
      const answer = await io.ask(colorQuestion, {
        header: 'Fill colour',
        // At most MAX_OPTIONS: yellow, purple and hex are typed under Other (parseFillColor takes the names).
        options: [COLOR_DEFAULT, 'blue', 'green', CANCEL],
      })
      if (answer === CANCEL) return NOTHING
      const parsed = answer === COLOR_DEFAULT ? FILL_DEFAULT : parseFillColor(answer)
      if (parsed) fillColor = parsed
      else if (i + 1 < TRIES) colorQuestion = `"${answer.slice(0, 40)}" is not a fill colour: use gray, blue, green, yellow, purple or a #rrggbb hex.\n${COLOR_QUESTION}`
      else notes.push('fill colour left unchanged')
    }

    let version: boolean | undefined
    const versionAnswer = await io.ask('Show the ccxp-skills version in the band (`ccxp 5.0.0`, plus `→ 5.1.0` when a newer release exists)?', {
      header: 'Version',
      options: [VERSION_SHOW, VERSION_HIDE, CANCEL],
    })
    if (versionAnswer === CANCEL) return NOTHING
    if (versionAnswer === VERSION_SHOW) version = true
    else if (versionAnswer === VERSION_HIDE) version = false
    else notes.push('plugin version left unchanged (answer must be show or hide)')

    if (ci === undefined && fillColor === undefined && version === undefined) return `ccxp-hud config: nothing to change (${notes.join('; ')}). Nothing written.`

    const scope = await io.ask('Where should it be saved?', { header: 'Scope', options: [SCOPE_USER, SCOPE_PROJECT, CANCEL] })
    if (scope === CANCEL) return NOTHING
    const file = scope === SCOPE_USER ? io.paths.user : scope === SCOPE_PROJECT ? io.paths.project : undefined
    if (!file) return 'ccxp-hud config: no such place to save to. Nothing written.'
    const existing = await io.read(file)
    if (!isRewritable(existing)) return `ccxp-hud config: ${file} is not a valid JSON object, so it was left alone. Fix or remove it, then run /hud config again. Nothing written.`
    const parts = [
      ci === undefined ? '"ci" unchanged' : `"ci": ${JSON.stringify(ci)}`,
      fillColor === undefined ? '"fillColor" unchanged' : `"fillColor": "${fillColor}"`,
      version === undefined ? '"version" unchanged' : `"version": ${version}`,
    ]
    const ok = await io.ask(`Write ${parts.join(' and ')} to ${file}?`, { header: 'Confirm', options: [WRITE, CANCEL] })
    if (ok !== WRITE) return NOTHING
    await io.write(file, withConfig(existing, { ci, fillColor, version }))
    const what = [ci === undefined ? undefined : `ci ${ci ? 'set' : 'hidden'}`, fillColor === undefined ? undefined : `fill colour ${fillColor}`, version === undefined ? undefined : `version segment ${version ? 'shown' : 'hidden'}`].filter(Boolean).join(', ') || 'nothing changed'
    return `ccxp-hud: ${what}, in ${file}.${notes.length ? ` Skipped: ${notes.join('; ')}.` : ''} The first CI result can take a couple of minutes (results are cached).`
  } catch (e) {
    // A dismissed or refused dialog rejects; nothing has been written at that point. Any other exception is a failure: say why.
    if (e instanceof AskRejected) return e.message ? `ccxp-hud config cancelled (dialog closed: ${e.message}); nothing written.` : NOTHING
    return `ccxp-hud config failed: ${reason(e) || 'unexpected error'}; nothing written.`
  }
}
