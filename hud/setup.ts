// ccxp-hud `/hud setup` and `/hud pane` logic. No `$`: the register module passes the
// few primitives in as `io`, so the unit tests can drive every branch with fakes.

import type { CiConfig } from '../types'
import { ciFromAnswers, isRewritable, withCi } from './config'

export const CANCEL = 'cancel'
export const NONE = 'none (hide CI)'
export const DEFAULT_BRANCH = 'repo default branch'
export const CURRENT_REPO = 'current repo'
export const SCOPE_USER = 'user file'
export const SCOPE_PROJECT = 'this project'
export const WRITE = 'write'

export type SetupIo = {
  /** The engine's question dialog: a chosen label, or free text typed under "Other". Rejects when dismissed. */
  ask: (question: string, options: { header: string; options: string[] }) => Promise<string>
  /** User-level and per-project config file paths (undefined when unknown). */
  paths: { user?: string; project?: string }
  read: (path: string) => Promise<string | undefined>
  write: (path: string, text: string) => Promise<void>
}

const NOTHING = 'ccxp-hud setup cancelled; nothing written.'

/**
 * `/hud setup`: workflow, branch, repo, scope, then a confirmation that shows the block.
 * Writes only the `ci` key, only after "write". Any cancel, dismissal or invalid answer writes nothing.
 */
export async function setupCi(io: SetupIo): Promise<string> {
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
      if (!res.ok) return `ccxp-hud setup: ${res.error}. Nothing written.`
      ci = res.ci
    }
    const scope = await io.ask('Where should it be saved?', { header: 'Scope', options: [SCOPE_USER, SCOPE_PROJECT, CANCEL] })
    if (scope === CANCEL) return NOTHING
    const file = scope === SCOPE_USER ? io.paths.user : scope === SCOPE_PROJECT ? io.paths.project : undefined
    if (!file) return 'ccxp-hud setup: no such place to save to. Nothing written.'
    const existing = await io.read(file)
    if (!isRewritable(existing)) return `ccxp-hud setup: ${file} is not a valid JSON object, so it was left alone. Fix or remove it, then run /hud setup again. Nothing written.`
    const ok = await io.ask(`Write "ci": ${JSON.stringify(ci)} to ${file}?`, { header: 'Confirm', options: [WRITE, CANCEL] })
    if (ok !== WRITE) return NOTHING
    await io.write(file, withCi(existing, ci))
    return `ccxp-hud: ci ${ci ? 'set' : 'hidden'} in ${file}. The first CI result can take a couple of minutes (results are cached).`
  } catch {
    // A dismissed dialog rejects; nothing has been written at that point.
    return NOTHING
  }
}

export type PaneIo = {
  isOpen: () => Promise<boolean>
  open: () => Promise<void>
  close: () => Promise<void>
}

/** `/hud pane` is a toggle: open when closed, close when open. */
export async function togglePane(io: PaneIo): Promise<string> {
  if (await io.isOpen()) {
    await io.close()
    return 'ccxp-hud pane closed.'
  }
  await io.open()
  return 'ccxp-hud pane opened. Run /hud pane again to close it.'
}
