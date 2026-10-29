// ccxp-hud: a Claude Code mod shipped inside the ccxp-skills plugin (T20261022-345549).
//
//  - styles the user's own prompt rows (UserMessage render site)
//  - draws a status band above the prompt (AbovePrompt) fed by the bash helper
//    hud/scripts/hud-data.sh --json (claimant secret stays in bash)
//  - /hud on|off|status|details|config
//
// ON by default; `enabled: false` in ~/.claude/ccxp-hud.json (or a project
// override) makes every hook a pass-through. The file is re-read on every poll
// and by /hud, so toggling is live; no reload needed.
// Every hook is wrapped so a throw draws the engine's own row. No network, no
// model and no MCP calls: only fs, process (one fixed argv), clock, state.

import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { CiConfig, HudConfig, Snapshot } from '../types'
import { DEFAULTS, configPaths, heartbeatPath, mergeConfig, parseConfigText, withEnabled } from './config'
import { fillStyleFor } from './fill'
import { EMPTY, compactLine, countJobs, parseHelper } from './model'
import { bandTree, userMessageTree } from './render'
import { configureHud } from './configure'

const snapshotAtom = atom({ plugin: 'ccxp-skills', key: 'snapshot' } as const, EMPTY)
const configAtom = atom({ plugin: 'ccxp-skills', key: 'config' } as const, DEFAULTS)
// `/hud details`: true while the band is expanded to its five detail lines (this session only).
const detailsAtom = atom({ plugin: 'ccxp-skills', key: 'details' } as const, false)

// Module-level state: a hot reload starts it over, which is fine (the config and
// snapshot live in $.state; these are only throttles and flags).
const mem = {
  surface: null as string | null,
  bandSurface: null as string | null,
  lastHelperAt: 0,
  heartbeatIsOn: null as boolean | null,
  started: false,
  // Which working tree the last good helper run described, and how many more refreshes
  // the "moved" arrow stays up. A hot reload starting these over is harmless.
  lastRepoKey: null as string | null,
  movedLeft: 0,
  // cwd + root at the last refresh: a change refreshes at once instead of at the next poll.
  lastWhere: null as string | null,
}

/** Refreshes the arrow stays after the working repo changed. */
const MOVED_REFRESHES = 2

/**
 * Where the session is NOW: the cwd (read fresh every time, never cached) and the session root.
 * cwd falls back to the root when it cannot be read, so the helper always has a directory.
 */
async function readWhere($: any): Promise<{ cwd: string; root: string | null }> {
  let cwd = ''
  let root: string | null = null
  try {
    cwd = (await $.session.cwd()) || ''
  } catch {
    cwd = ''
  }
  try {
    root = (await $.session.root()) ?? null
  } catch {
    root = null
  }
  return { cwd: cwd || root || '', root }
}

async function envPaths($: any) {
  let configDir: string | undefined
  let home: string | undefined
  try {
    configDir = await $.env.get('CLAUDE_CONFIG_DIR')
    home = await $.env.get('HOME')
  } catch {
    /* no env: defaults below stay undefined, config then means defaults */
  }
  return { configDir, home }
}

/** The person's `/config` theme value, or undefined when it cannot be read (the fill then uses reverse video). */
async function themeOf($: any): Promise<unknown> {
  try {
    return (await $.config.list()).find((r: any) => r.key === 'theme')?.value
  } catch {
    return undefined
  }
}

async function readText($: any, path: string | undefined): Promise<string | undefined> {
  if (!path) return undefined
  try {
    return await $.fs.read(path)
  } catch {
    return undefined
  }
}

/** Loads project over user over defaults into the atom; never throws. */
async function loadConfig($: any): Promise<HudConfig> {
  let cfg = DEFAULTS
  try {
    const env = await envPaths($)
    let root: string | undefined
    try {
      root = await $.session.root()
    } catch {
      root = undefined
    }
    const paths = configPaths(env, root)
    cfg = mergeConfig(parseConfigText(await readText($, paths.user)), parseConfigText(await readText($, paths.project)))
  } catch {
    cfg = DEFAULTS
  }
  await update($, configAtom, () => cfg)
  return cfg
}

async function writeHeartbeat($: any, value: 'on' | 'off') {
  try {
    const id = await $.session.id()
    const path = heartbeatPath(await envPaths($), id)
    if (path) await $.fs.write(path, `${value}\n`)
  } catch {
    /* best effort: the classic statusline then just prints in full */
  }
}

async function syncHeartbeat($: any, cfg: HudConfig) {
  // "on" only while a band is actually drawn (bandSurface is cleared when the
  // band hook had nothing to show), so the statusline never shrinks for nothing.
  const wantOn = cfg.enabled && cfg.band && mem.bandSurface !== null
  // First call after a (re)load always writes, so a heartbeat left "on" by a
  // previous module instance cannot outlive the mod being switched off.
  // "on" is rewritten every call: the statusline treats an old file as off.
  if (!wantOn && mem.heartbeatIsOn === false) return
  await writeHeartbeat($, wantOn ? 'on' : 'off')
  mem.heartbeatIsOn = wantOn
}

async function refresh($: any, cfg: HudConfig) {
  if (!cfg.enabled) return
  mem.lastHelperAt = await $.clock.now()
  let helper = null
  let isOk = false
  // The repo cell follows the session cwd, so /cd and a shell cd both move it; root() only feeds "(root: X)".
  const where = await readWhere($)
  mem.lastWhere = `${where.cwd}\n${where.root ?? ''}`
  try {
    const cwd: string = where.cwd
    const sessionId: string = await $.session.id()
    const argv = ['bash', `${$.plugin.root}/hud/scripts/hud-data.sh`, '--json']
    const res = await $.process.run(argv, {
      cwd,
      stdin: JSON.stringify({ cwd, session_id: sessionId, ci: cfg.ci ?? null, ci_ttl: cfg.pollSeconds, show_version: cfg.version }),
      timeoutMs: 5000,
    })
    helper = res.exitCode === 0 ? parseHelper(res.stdout) : null
    isOk = helper !== null
  } catch {
    isOk = false
  }
  let agents: ReadonlyArray<{ status: string }> = []
  try {
    agents = await $.agent.list()
  } catch {
    agents = []
  }
  const usage = await readUsage($)
  if (isOk && helper) {
    // A different working tree than last time (or a different folder outside any repo) is a move.
    const key = helper.repo_root ?? (helper.cwd || where.cwd)
    if (mem.lastRepoKey !== null && key !== mem.lastRepoKey) mem.movedLeft = MOVED_REFRESHES
    else if (mem.movedLeft > 0) mem.movedLeft -= 1
    mem.lastRepoKey = key
  }
  await update($, snapshotAtom, (prev: Snapshot) => ({
    ...prev,
    ...usage,
    moved: mem.movedLeft > 0,
    sessionRoot: where.root,
    helper: isOk ? helper : prev.helper,
    stale: !isOk,
    jobs: countJobs(agents),
  }))
}

async function readUsage($: any): Promise<Partial<Snapshot>> {
  try {
    const u = await $.session.usage()
    return usagePart(u)
  } catch {
    return {}
  }
}

function usagePart(u: any): Partial<Snapshot> {
  // Only the units present in `u` are returned, so a partial measurement
  // (say context alone) never wipes the others.
  const out: Partial<Snapshot> = {}
  if (u?.context) {
    const percent = u.context.percent
    out.ctxLeft = typeof percent === 'number' ? Math.max(0, 100 - percent) : null
  }
  if (Array.isArray(u?.rateLimits)) {
    const five = u.rateLimits.find((r: any) => r?.kind === 'five_hour')
    out.rateUsed = typeof five?.percentUsed === 'number' ? five.percentUsed : null
  }
  if (u?.cost) out.costUsd = typeof u.cost.usd === 'number' ? u.cost.usd : null
  return out
}

async function mirrorStatus($: any, cfg: HudConfig) {
  // VS Code draws no band: mirror a compact line there. Elsewhere clear it.
  try {
    if (cfg.enabled && cfg.band && mem.surface === 'vscode') {
      $.ui.status(compactLine(await read($, snapshotAtom), cfg))
    } else {
      $.ui.status(undefined)
    }
  } catch {
    /* ignore */
  }
}

async function tick($: any) {
  try {
    await tickOnce($)
  } catch {
    /* never throws: a failed tick leaves the previous state */
  }
}

async function tickOnce($: any) {
  const cfg = await loadConfig($)
  if (!cfg.enabled) {
    await syncHeartbeat($, cfg)
    await mirrorStatus($, cfg)
    return
  }
  const now = await $.clock.now()
  // Poll on the configured interval, or at once when the session moved (a /cd
  // changes cwd and root; both are cheap in-process reads on every 5 s tick).
  const where = await readWhere($)
  const moved = mem.lastWhere !== null && mem.lastWhere !== `${where.cwd}\n${where.root ?? ''}`
  if (moved || now - mem.lastHelperAt >= cfg.pollSeconds * 1000) await refresh($, cfg)
  await syncHeartbeat($, cfg)
  await mirrorStatus($, cfg)
}


export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      mem.surface = e.surface ?? null
      if (!mem.started) {
        mem.started = true
        try {
          await $.command.register({ name: 'hud', description: 'ccxp-hud: on | off | status | details | config' })
        } catch {
          /* the command is optional */
        }
        // The timer ticks at the minimum poll; each tick gates on the configured poll.
        $.clock.every(5000, () => {
          void tick($)
        })
      }
      await tick($)
    } catch {
      /* the module stays inert; the session is never broken by the hud */
    }
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    try {
      const cfg = await read($, configAtom)
      if (cfg.enabled) await update($, snapshotAtom, (prev: Snapshot) => ({ ...prev, ...usagePart(e) }))
    } catch {
      /* ignore */
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    try {
      const cfg = await read($, configAtom)
      if (cfg.enabled) await refresh($, cfg)
    } catch {
      /* ignore */
    }
    return next(e)
  })

  // /cd moves the session to another directory. Refresh once it has run so the band
  // names the new repo now, not at the next tick. UNVERIFIED that this fires for the
  // built-in /cd; the 5 s tick above covers it either way.
  on('command.run', { command: 'cd' }, async ($, e, next) => {
    const out = await next(e)
    try {
      const cfg = await read($, configAtom)
      if (cfg.enabled) await refresh($, cfg)
    } catch {
      /* ignore */
    }
    return out
  })

  on('command.run', { command: 'hud' }, async ($, e) => {
    const arg = String((e as any).args ?? '').trim().toLowerCase()
    try {
      const env = await envPaths($)
      const file = configPaths(env).user
      if (arg === 'on' || arg === 'off') {
        if (!file) return { text: 'ccxp-hud: cannot find the config dir. Edit ccxp-hud.json by hand: {"enabled": ' + (arg === 'on') + '}' }
        try {
          await $.fs.write(file, withEnabled(await readText($, file), arg === 'on'))
        } catch {
          return { text: `ccxp-hud: could not write ${file}. Set "enabled": ${arg === 'on'} in it by hand.` }
        }
        const cfg = await loadConfig($)
        if (cfg.enabled) await refresh($, cfg)
        await syncHeartbeat($, cfg)
        await mirrorStatus($, cfg)
        return { text: `ccxp-hud ${cfg.enabled ? 'on' : 'off'} (${file}). Takes effect now.` }
      }
      if (arg === 'details') {
        // Toggle: the expanded view is a live part of the band, so the flag lives in an atom the band reads.
        const cfg = await read($, configAtom)
        if (!cfg.enabled || !cfg.band) return { text: 'ccxp-hud: the band is off, so there are no details to show. Run /hud on first.' }
        const isOn = !(await read($, detailsAtom))
        await update($, detailsAtom, () => isOn)
        if (isOn) await refresh($, cfg) // fresh numbers in the first draw
        return {
          text: isOn
            ? 'ccxp-hud details on: the band is expanded and updates live. Run /hud details again to collapse it.'
            : 'ccxp-hud details off: back to the one-line band.',
        }
      }
      if (arg === 'config') {
        let root: string | undefined
        try {
          root = await $.session.root()
        } catch {
          root = undefined
        }
        const text = await configureHud({
          ask: (question, options) => $.ui.ask(question, options),
          paths: configPaths(env, root),
          read: path => readText($, path),
          write: (path, body) => $.fs.write(path, body),
        })
        await loadConfig($)
        return { text }
      }
      const cfg = await read($, configAtom)
      return { text: `ccxp-hud is ${cfg.enabled ? 'on' : 'off'}. Config: ${file ?? '(unknown)'}. Usage: /hud on | off | status | details | config` }
    } catch {
      return { text: 'ccxp-hud: something went wrong; the session is unaffected.' }
    }
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const cfg = await read($, configAtom)
    if (!cfg.enabled || !cfg.userMessage) return next(e)
    // Only the person's own composer rows; notifications and peers keep the engine's drawing.
    if (e.props?.origin?.kind !== 'composer') return next(e)
    // Desktop and VS Code draw their own frames: leave those rows alone.
    if (e.surface !== 'terminal') return next(e)
    const inner = await next(e)
    return userMessageTree($.ui.resolve(e), cfg, inner)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const cfg = await read($, configAtom)
    if (!cfg.enabled || !cfg.band || e.props.hasSurvey) return next(e)
    const expanded = await read($, detailsAtom)
    const fill = fillStyleFor(await themeOf($), cfg.fillColor)
    const tree = bandTree($.ui.resolve(e), await read($, snapshotAtom), cfg, e.props.bodyColumns, expanded, e.props.maxRows, fill)
    mem.bandSurface = tree ? e.surface : null
    return tree ?? next(e)
  }).catch(($, e, next) => next(e))
}
