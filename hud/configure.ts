// ccxp-hud `/hud config` logic. No `$`: the register module passes the
// few primitives in as `io`, so the unit tests can drive every branch with fakes.

import type { CiConfig } from '../types'
import { CI_URL_EXAMPLE, ciFromAnswer, isRewritable, withConfig } from './config'
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
/** Asks per question before it is skipped (left unchanged) and the dialog moves on. */
const TRIES = 2

/**
 * `/hud config`: CI workflow URL, fill colour, plugin version on/off, scope, then a confirmation that shows what is written.
 * Writes only the `ci`, `fillColor` and `version` keys, only after "write". An explicit cancel or a dismissed dialog writes nothing.
 * An invalid answer is re-asked once; after a second invalid answer that setting is left unchanged and the dialog continues.
 */
export async function configureHud(io: ConfigIo): Promise<string> {
  try {
    const notes: string[] = []
    let ci: CiConfig | null | undefined
    let ciQuestion = CI_QUESTION
    for (let i = 0; i < TRIES && ci === undefined; i++) {
      const answer = await io.ask(ciQuestion, { header: 'CI workflow URL', options: [NONE, CANCEL] })
      if (answer === CANCEL) return NOTHING
      const res = ciFromAnswer(answer)
      if (res.ok) ci = res.ci
      else if (i + 1 < TRIES) ciQuestion = `Could not use that: ${res.error}. Example: ${CI_URL_EXAMPLE}\n${CI_QUESTION}`
      else notes.push(`CI left unchanged (${res.error})`)
    }

    let fillColor: string | undefined
    const COLOR_QUESTION = 'Which colour for the always-on fill band? Pick one, or type a #rrggbb hex colour under Other (a custom hex is used on any theme; the named colours adapt to dark and light themes).'
    let colorQuestion = COLOR_QUESTION
    for (let i = 0; i < TRIES && fillColor === undefined; i++) {
      const answer = await io.ask(colorQuestion, {
        header: 'Fill colour',
        options: [COLOR_DEFAULT, ...FILL_COLOR_NAMES.filter(n => n !== FILL_DEFAULT), CANCEL],
      })
      if (answer === CANCEL) return NOTHING
      const parsed = answer === COLOR_DEFAULT ? FILL_DEFAULT : parseFillColor(answer)
      if (parsed) fillColor = parsed
      else if (i + 1 < TRIES) colorQuestion = `"${answer.slice(0, 40)}" is not a fill colour: use gray, blue, green, yellow, purple or a #rrggbb hex.\n${COLOR_QUESTION}`
      else notes.push('fill colour left unchanged')
    }

    let version: boolean | undefined
    const versionAnswer = await io.ask('Show the ccxp-skills version in the band (`ccxp 5.0.0`, plus `→ 5.1.0` when a newer release exists)?', {
      header: 'Plugin version',
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
  } catch {
    // A dismissed dialog rejects; nothing has been written at that point.
    return NOTHING
  }
}
