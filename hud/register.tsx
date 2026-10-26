// ccxp-hud: a Claude Code mod shipped inside the ccxp-skills plugin (T20261022-345549).
//
//  - styles the user's own prompt rows (UserMessage render site)
//  - draws a status band above the prompt (AbovePrompt) fed by the bash helper
//    hud/scripts/hud-data.sh --json (claimant secret stays in bash)
//  - /hud on|off|status|pane
//
// ON by default; `enabled: false` in ~/.claude/ccxp-hud.json (or a project
// override) makes every hook a pass-through. The file is re-read on every poll
// and by /hud, so toggling is live; no reload needed.
// Every hook is wrapped so a throw draws the engine's own row. No network, no
// model and no MCP calls: only fs, process (one fixed argv), clock, state.

import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { HudConfig, Snapshot } from '../types'
import { DEFAULTS, configPaths, heartbeatPath, mergeConfig, parseConfigText, withEnabled } from './config'
import { EMPTY, compactLine, countJobs, parseHelper } from './model'
import { bandTree, paneTree, userMessageTree } from './render'

const PANE = 'ccxp-hud'
const snapshotAtom = atom({ plugin: 'ccxp-skills', key: 'snapshot' } as const, EMPTY)
const configAtom = atom({ plugin: 'ccxp-skills', key: 'config' } as const, DEFAULTS)

// Module-level state: a hot reload starts it over, which is fine (the config and
// snapshot live in $.state; these are only throttles and flags).
const mem = {
  surface: null as string | null,
  bandSurface: null as string | null,
  lastHelperAt: 0,
  heartbeatIsOn: null as boolean | null,
  started: false,
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
  try {
    const cwd: string = await $.session.cwd()
    const sessionId: string = await $.session.id()
    const argv = ['bash', `${$.plugin.root}/hud/scripts/hud-data.sh`, '--json']
    const res = await $.process.run(argv, {
      cwd,
      stdin: JSON.stringify({ cwd, session_id: sessionId }),
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
  await update($, snapshotAtom, (prev: Snapshot) => ({
    ...prev,
    ...usage,
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
  if (now - mem.lastHelperAt >= cfg.pollSeconds * 1000) await refresh($, cfg)
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
          await $.command.register({ name: 'hud', description: 'ccxp-hud: on | off | status | pane' })
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
      if (arg === 'pane') {
        await $.ui.open({ id: PANE, title: 'ccxp-hud' })
        return { text: 'ccxp-hud pane opened.' }
      }
      const cfg = await read($, configAtom)
      return { text: `ccxp-hud is ${cfg.enabled ? 'on' : 'off'}. Config: ${file ?? '(unknown)'}. Usage: /hud on | off | status | pane` }
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
    const tree = bandTree($.ui.resolve(e), await read($, snapshotAtom), cfg, e.props.bodyColumns)
    mem.bandSurface = tree ? e.surface : null
    return tree ?? next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const cfg = await read($, configAtom)
    return paneTree($.ui.resolve(e), await read($, snapshotAtom), cfg)
  }).catch(($, e, next) => next(e))
}
