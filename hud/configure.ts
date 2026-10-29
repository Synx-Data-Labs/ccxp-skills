// ccxp-hud `/hud config` logic. No `$`: the register module passes the
// few primitives in as `io`, so the unit tests can drive every branch with fakes.

import type { CiConfig } from '../types'
import { ciFromAnswers, isRewritable, withConfig } from './config'
import { FILL_COLOR_NAMES, FILL_DEFAULT, parseFillColor } from './fill'

export const CANCEL = 'cancel'
export const NONE = 'none (hide CI)'
export const DEFAULT_BRANCH = 'repo default branch'
export const CURRENT_REPO = 'current repo'
export const SCOPE_USER = 'user file'
export const SCOPE_PROJECT = 'this project'
export const WRITE = 'write'
/** Option label of the default colour; the other palette names are offered as they are. */
export const COLOR_DEFAULT = `${FILL_DEFAULT} (default)`

export type ConfigIo = {
  /** The engine's question dialog: a chosen label, or free text typed under "Other". Rejects when dismissed. */
  ask: (question: string, options: { header: string; options: string[] }) => Promise<string>
  /** User-level and per-project config file paths (undefined when unknown). */
  paths: { user?: string; project?: string }
  read: (path: string) => Promise<string | undefined>
  write: (path: string, text: string) => Promise<void>
}

const NOTHING = 'ccxp-hud config cancelled; nothing written.'

/**
 * `/hud config`: workflow, branch, repo, fill colour, scope, then a confirmation that shows what is written.
 * Writes only the `ci` and `fillColor` keys, only after "write". Any cancel, dismissal or invalid answer writes nothing.
 */
export async function configureHud(io: ConfigIo): Promise<string> {
  try {
    const wf = await io.ask('Which CI workflow should the band show? Pick none, or type the workflow file name (for example nightly.yml) under Other.', {
      header: 'CI workflow',
      options: [NONE, CANCEL],
    })
    if (wf === CANCEL) return NOTHING
    let ci: CiConfig | null = null
    if (wf !== NONE) {
      const branch = await io.ask('Which branch? Pick the default, or type a branch name under Other.', { header: 'CI branch', options: [DEFAULT_BRANCH, CANCEL] })
      if (branch === CANCEL) return NOTHING
      const repo = await io.ask('Which repository? Pick the current one, or type owner/name under Other.', { header: 'CI repo', options: [CURRENT_REPO, CANCEL] })
      if (repo === CANCEL) return NOTHING
      const res = ciFromAnswers({ workflow: wf, branch: branch === DEFAULT_BRANCH ? '' : branch, repo: repo === CURRENT_REPO ? '' : repo })
      if (!res.ok) return `ccxp-hud config: ${res.error}. Nothing written.`
      ci = res.ci
    }
    const colorAnswer = await io.ask('Which colour for the always-on fill band? Pick one, or type a #rrggbb hex colour under Other (a custom hex is used on any theme; the named colours adapt to dark and light themes).', {
      header: 'Fill colour',
      options: [COLOR_DEFAULT, ...FILL_COLOR_NAMES.filter(n => n !== FILL_DEFAULT), CANCEL],
    })
    if (colorAnswer === CANCEL) return NOTHING
    const fillColor = colorAnswer === COLOR_DEFAULT ? FILL_DEFAULT : parseFillColor(colorAnswer)
    if (!fillColor) return 'ccxp-hud config: fill colour must be gray, blue, green, yellow, purple or a #rrggbb hex. Nothing written.'
    const scope = await io.ask('Where should it be saved?', { header: 'Scope', options: [SCOPE_USER, SCOPE_PROJECT, CANCEL] })
    if (scope === CANCEL) return NOTHING
    const file = scope === SCOPE_USER ? io.paths.user : scope === SCOPE_PROJECT ? io.paths.project : undefined
    if (!file) return 'ccxp-hud config: no such place to save to. Nothing written.'
    const existing = await io.read(file)
    if (!isRewritable(existing)) return `ccxp-hud config: ${file} is not a valid JSON object, so it was left alone. Fix or remove it, then run /hud config again. Nothing written.`
    const ok = await io.ask(`Write "ci": ${JSON.stringify(ci)} and "fillColor": "${fillColor}" to ${file}?`, { header: 'Confirm', options: [WRITE, CANCEL] })
    if (ok !== WRITE) return NOTHING
    await io.write(file, withConfig(existing, { ci, fillColor }))
    return `ccxp-hud: ci ${ci ? 'set' : 'hidden'}, fill colour ${fillColor}, in ${file}. The first CI result can take a couple of minutes (results are cached).`
  } catch {
    // A dismissed dialog rejects; nothing has been written at that point.
    return NOTHING
  }
}
