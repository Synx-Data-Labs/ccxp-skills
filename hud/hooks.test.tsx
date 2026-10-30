import { expect, test } from 'claude-code/testing'

import { USER_TEXT_COLOR } from './config'
import { FILL_BG, FILL_COLORS } from './fill'

const HELPER = JSON.stringify({
  repo: 'proj',
  task_id: 'T20261021-354035',
  task_title: 'Decouple',
  branch: 'main',
  worktree: '',
  autopilot: null,
  ledger: null,
  ci: { state: 'failing', at: 0 },
  last_input_at: 0,
})
const HELPER_AP = JSON.stringify({ ...JSON.parse(HELPER), autopilot: { status: 'running', prefix: '[r]', elapsed_hr: 1, requested_hr: 4, stuck: 0, cycle: 2, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 1, next_wake_at: 0 } })

type World = {
  cfg?: string
  projectCfg?: string
  helper?: { exitCode: number; stdout: string } | 'throw'
  writes: { path: string; text: string }[]
  runs: string[][]
  cwds: string[]
  now?: number
  cwd?: string
  root?: string
  helperByCwd?: Record<string, string>
  stdins: string[]
  statuses: (string | undefined)[]
  theme?: string
}

// Stands for the engine beneath the mod: every hook here answers `{ value }`.
function world($: any, on: any, w: World) {
  on('env.get', (_: any, e: any) => ({ value: e.name === 'HOME' ? '/home/u' : undefined }))
  on('session.root', () => ({ value: w.root ?? '/proj' }))
  on('session.cwd', () => ({ value: w.cwd ?? '/proj' }))
  on('session.id', () => ({ value: 'sess1' }))
  on('fs.read', (_: any, e: any) => {
    if (e.path === '/home/u/.claude/ccxp-hud.json' && w.cfg !== undefined) return { value: w.cfg }
    if (e.path === '/proj/.claude/ccxp-hud.json' && w.projectCfg !== undefined) return { value: w.projectCfg }
    throw new Error('ENOENT')
  })
  on('fs.write', (_: any, e: any) => {
    w.writes.push({ path: e.path, text: e.text })
    // Reads see what was written, as on a real disk.
    if (e.path.endsWith('ccxp-hud.json')) w.cfg = e.text
    return { value: undefined }
  })
  on('process.run', (_: any, e: any) => {
    w.runs.push([...e.argv])
    w.stdins.push(String(e.init?.stdin ?? e.stdin ?? ''))
    w.cwds.push(e.init?.cwd)
    if (w.helper === 'throw') throw new Error('boom')
    if (w.helperByCwd?.[e.init?.cwd]) return { value: { exitCode: 0, stdout: w.helperByCwd[e.init?.cwd], stderr: '' } }
    return { value: w.helper ?? { exitCode: 0, stdout: HELPER, stderr: '' } }
  })
  on('agent.list', () => ({ value: [{ status: 'running' }, { status: 'failed' }] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000, percent: 36 }, rateLimits: [] } }))
  on('clock.now', () => ({ value: w.now ?? 1_000_000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'hud' } }))
  on('ui.status', (_: any, e: any) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('config.list', () => ({ value: w.theme === undefined ? [] : [{ key: 'theme', value: w.theme }] }))
  // The engine's own drawing of every site the mod hooks.
  on('ui.render', ($: any, e: any) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
}

const fresh = (): World => ({ writes: [], runs: [], cwds: [], statuses: [], stdins: [] })

const START = { cwd: '/proj', surface: 'terminal', isInteractive: true } as const

const USER = (kind: string) =>
  ({
    plugin: 'ccxp-skills',
    component: 'UserMessage',
    surface: 'terminal',
    props: { text: 'fix the thing', origin: { kind }, isExpanded: false },
  }) as any

const BAND = (columns: number) =>
  ({
    plugin: 'ccxp-skills',
    component: 'AbovePrompt',
    surface: 'terminal',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: columns, scroll: { offset: 0, bodyRows: 10 } },
  }) as any

async function drawsEngine(ui: any) {
  return (await ui.find({ type: 'Text', text: /^engine$/ })) !== undefined && (await ui.find({ type: 'Box' })) === undefined
}

test('default (no config file): a composer row is wrapped, a task-notification row is passed through', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const mine = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(mine)).toBe(false)
  expect(await mine.find({ type: 'Text', text: /engine/ })).toBeDefined()
  expect(await mine.find({ type: 'Text', color: USER_TEXT_COLOR })).toBeDefined()
  await mine.unmount()
  const note = await $.ui.mount(USER('task-notification'))
  expect(await drawsEngine(note)).toBe(true)
  await note.unmount()
})

test('desktop rows keep the engine drawing (its own frame)', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const ui = await $.ui.mount({ ...USER('composer'), surface: 'desktop' })
  expect(await drawsEngine(ui)).toBe(true)
  await ui.unmount()
})

test('enabled:false: every hook is a pass-through, no band, no process run, no "on" heartbeat', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"enabled": false}'
  world($, on, w)
  await $.session.start(START)
  const row = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(row)).toBe(true)
  await row.unmount()
  const band = await $.ui.mount(BAND(140))
  expect(await drawsEngine(band)).toBe(true)
  await band.unmount()
  expect(w.runs).toEqual([])
  const beats = w.writes.filter(x => x.path.includes('hud-active'))
  expect(beats.some(x => x.text === 'on\n')).toBe(false)
  // A heartbeat left "on" by an earlier instance is overwritten with "off".
  expect(beats.every(x => x.text === 'off\n')).toBe(true)
})

test('userMessage:false switches only the prompt styling off; the band still draws', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"userMessage": false}'
  world($, on, w)
  await $.session.start(START)
  const row = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(row)).toBe(true)
  await row.unmount()
  const band = await $.ui.mount(BAND(140))
  expect(await band.find({ type: 'Text', text: /proj/ })).toBeDefined()
  await band.unmount()
})

test('band:false switches only the band off; prompt styling stays', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"band": false}'
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(140))
  expect(await drawsEngine(band)).toBe(true)
  await band.unmount()
  const row = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(row)).toBe(false)
  await row.unmount()
})

for (const cfg of [undefined, '', '{broken', '[]']) {
  test(`config file ${JSON.stringify(cfg)} means defaults (on) and never throws`, async ($: any, on: any) => {
    const w = fresh()
    w.cfg = cfg
    world($, on, w)
    await $.session.start(START)
    const row = await $.ui.mount(USER('composer'))
    expect(await drawsEngine(row)).toBe(false)
    await row.unmount()
  })
}

test('project override beats the user file', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"enabled": false}'
  w.projectCfg = '{"enabled": true}'
  world($, on, w)
  await $.session.start(START)
  const row = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(row)).toBe(false)
  await row.unmount()
})

test('the band shows helper data once the session started, and the helper gets a fixed argv', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"ci": {"workflow": "nightly.yml"}}'
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(140))
  expect(await band.find({ type: 'Text', text: /T20261021-354035 Decouple/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /failing/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /AP / })).toBeUndefined()
  await band.unmount()
  // The configured ci block reaches the helper on stdin (not argv).
  expect(w.stdins.some(x => x.includes('nightly.yml'))).toBe(true)
  for (const argv of w.runs) expect(argv.join(' ')).not.toContain('nightly.yml')
  // The version switch reaches the helper on stdin too (default on).
  expect(w.stdins.some(x => JSON.parse(x).show_version === true)).toBe(true)
  expect(w.runs.length).toBeGreaterThan(0)
  for (const argv of w.runs) {
    expect(argv[0]).toBe('bash')
    expect(argv[1]).toMatch(/hud\/scripts\/hud-data\.sh$/)
    expect(argv.slice(2)).toEqual(['--json'])
  }
})

test('a heartbeat is written while the band is on, in the statusline-readable place', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(140))
  await band.unmount()
  await $.session.start(START)
  expect(w.writes.some(x => x.path === '/home/u/.claude/state/hud-active/sess1' && x.text === 'on\n')).toBe(true)
})

for (const helper of ['throw', { exitCode: 1, stdout: '' }, { exitCode: 0, stdout: 'garbage' }] as const) {
  test(`helper failure ${JSON.stringify(helper)}: no throw, the band shows the stale tag`, async ($: any, on: any) => {
    const w = fresh()
    w.helper = helper as any
    world($, on, w)
    await $.session.start(START)
    const band = await $.ui.mount(BAND(140))
    expect(await band.find({ type: 'Text', text: /stale/ })).toBeDefined()
    await band.unmount()
  })
}

test('/hud off writes enabled:false to the user file and draws nothing afterwards', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const out = await $.command.run({ command: 'hud', args: 'off' })
  expect(out.text).toMatch(/off/)
  const wrote = w.writes.find(x => x.path === '/home/u/.claude/ccxp-hud.json')
  expect(JSON.parse(wrote!.text).enabled).toBe(false)
  const row = await $.ui.mount(USER('composer'))
  expect(await drawsEngine(row)).toBe(true)
  await row.unmount()
})

test('/hud status reports on or off and the file path', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const out = await $.command.run({ command: 'hud', args: 'status' })
  expect(out.text).toMatch(/on/)
  expect(out.text).toMatch(/ccxp-hud\.json/)
})

test('bare /hud only prints the status line and usage; it never opens the config dialog or writes', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const before = w.writes.length
  for (const args of ['', '  ']) {
    const out = await $.command.run({ command: 'hud', args })
    expect(out.text).toMatch(/ccxp-hud is on/)
    expect(out.text).toMatch(/Usage:/)
    expect(out.text).not.toMatch(/cancelled/)
  }
  expect(w.writes.length).toBe(before)
})

test('an empty band (fields: []) never writes an "on" heartbeat', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"fields": []}'
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(140))
  expect(await drawsEngine(band)).toBe(true)
  await band.unmount()
  await $.session.start(START)
  expect(w.writes.some(x => x.path.includes('hud-active') && x.text === 'on\n')).toBe(false)
})

test('a partial session.measure updates context and keeps the other units', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"fields": ["ctx", "rate"]}'
  w.helper = { exitCode: 0, stdout: HELPER_AP }
  world($, on, w)
  on('session.measure', (_: any, e: any) => ({ changed: e.changed }))
  await $.session.start(START)
  await $.session.measure({ context: { window: 200000, percent: 90 }, rateLimits: [{ kind: 'five_hour', percentUsed: 42 }], changed: ['context', 'rateLimits'] })
  await $.session.measure({ context: { window: 200000, percent: 50 }, changed: ['context'] })
  const band = await $.ui.mount(BAND(140))
  expect(await band.find({ type: 'Text', text: /ctx 50%/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /5h 42%/ })).toBeDefined()
  await band.unmount()
})

const LEDGER = { running: [{ job: 70, title: 'Redo HUD repo field' }], lifetime_jobs: 82, parked: [{ id: 'k2' }], next_job: 83, updated_at: '' }
const HELPER_FULL = JSON.stringify({
  ...JSON.parse(HELPER_AP),
  ledger: LEDGER,
  repo_slug: 'acme/proj',
  repo_root: '/proj',
  cwd: '/proj',
  dirty: 2,
  last_input_at: Math.floor(Date.now() / 1000) - 180,
})

test('/hud details is a toggle: the first run expands the band to detail lines, the second collapses it, the third expands again', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"ci": {"workflow": "nightly.yml"}}'
  w.helper = { exitCode: 0, stdout: HELPER_FULL }
  world($, on, w)
  await $.session.start(START)
  // Only the expanded view has the lifetime job count.
  const expanded = async () => {
    const band = await $.ui.mount(BAND(140))
    const isExpanded = (await band.find({ type: 'Text', text: /^total jobs 82$/ })) !== undefined
    await band.unmount()
    return isExpanded
  }
  expect(await expanded()).toBe(false)
  const first = await $.command.run({ command: 'hud', args: 'details' })
  expect(first.text).toMatch(/details on/)
  expect(await expanded()).toBe(true)
  const second = await $.command.run({ command: 'hud', args: 'details' })
  expect(second.text).toMatch(/details off/)
  expect(await expanded()).toBe(false)
  const third = await $.command.run({ command: 'hud', args: 'details' })
  expect(third.text).toMatch(/details on/)
  expect(await expanded()).toBe(true)
})

test('/hud details: the five lines carry repo, ctx, jobs, autopilot with CI, and the last prompt, and follow new data live', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"ci": {"workflow": "nightly.yml"}}'
  w.helper = { exitCode: 0, stdout: HELPER_FULL }
  world($, on, w)
  on('session.measure', (_: any, e: any) => ({ changed: e.changed }))
  await $.session.start(START)
  await $.command.run({ command: 'hud', args: 'details' })
  const band = await $.ui.mount(BAND(140))
  expect(await band.find({ type: 'Text', text: /acme\/proj/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /context 64% left/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /^WORKING \(1\)$/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /Redo HUD repo field/ })).toBeUndefined() // running jobs are not listed in details
  expect(await band.find({ type: 'Text', text: /^parked 1$/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /running/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /failing/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /\(3m ago\)/ })).toBeDefined()
  await band.unmount()
  // A new measurement shows up in the expanded view without toggling again.
  await $.session.measure({ context: { window: 200000, percent: 90 }, changed: ['context'] })
  const again = await $.ui.mount(BAND(140))
  expect(await again.find({ type: 'Text', text: /context 10% left/ })).toBeDefined()
  await again.unmount()
})

test('/hud details with the band off says so and changes nothing', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"band": false}'
  world($, on, w)
  await $.session.start(START)
  const out = await $.command.run({ command: 'hud', args: 'details' })
  expect(out.text).toMatch(/band is off/)
})

test('the retired /hud pane is gone: it falls through to the usage line, which does not offer it', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const out = await $.command.run({ command: 'hud', args: 'pane' })
  expect(out.text).toMatch(/Usage:/)
  expect(out.text).toContain('details')
  expect(out.text).not.toContain('pane')
})

// --- fill mode ---

test('/hud fill is retired: it is not a subcommand, writes nothing, and the usage line offers config', async ($: any, on: any) => {
  const w = fresh()
  w.cfg = '{"band": true}'
  world($, on, w)
  await $.session.start(START)
  const before = w.writes.length
  const out = await $.command.run({ command: 'hud', args: 'fill on' })
  expect(out.text).toMatch(/Usage:/)
  expect(w.writes.length).toBe(before)
  const usage = (await $.command.run({ command: 'hud', args: 'bogus' })).text
  expect(usage).toContain('config')
  expect(usage).not.toContain('fill')
  expect(usage).not.toContain('setup')
  expect((await $.command.run({ command: 'hud', args: 'setup' })).text).toMatch(/Usage:/)
})

test('fill is always on by default (gray): the band carries the gray background', async ($: any, on: any) => {
  const w = fresh()
  w.theme = 'dark'
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(100))
  expect(await band.find({ type: 'Text', text: /proj/ })).toBeDefined()
  expect(await hasProps(band, { backgroundColor: FILL_BG.dark })).toBe(true)
  await band.unmount()
})

// find() does not filter on style props, so read them off the matched Texts.
async function hasProps(band: any, want: Record<string, unknown>) {
  const texts = await band.findAll({ type: 'Text' })
  return texts.some((t: any) => Object.entries(want).every(([k, v]) => t.props[k] === v))
}

async function fillBand($: any, on: any, theme: string, props: object, cfg = '{}') {
  const w = fresh()
  w.cfg = cfg
  w.theme = theme
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(100))
  const found = await hasProps(band, props)
  await band.unmount()
  return found
}

test('fill, dark theme: the dark background', async ($: any, on: any) => {
  expect(await fillBand($, on, 'dark', { backgroundColor: FILL_BG.dark })).toBe(true)
})

test('fill, light theme: the light background', async ($: any, on: any) => {
  expect(await fillBand($, on, 'light', { backgroundColor: FILL_BG.light })).toBe(true)
})

// One world per test: the engine refuses on() hooks registered after a test first called $.
test('fillColor in the config file is used: a named colour (blue, dark)', async ($: any, on: any) => {
  expect(await fillBand($, on, 'dark', { backgroundColor: FILL_COLORS.blue.dark }, '{"fillColor": "blue"}')).toBe(true)
})

test('fillColor in the config file is used: hex on any theme', async ($: any, on: any) => {
  expect(await fillBand($, on, 'auto', { backgroundColor: '#112233' }, '{"fillColor": "#112233"}')).toBe(true)
})

test('an old fill:false in the config file is ignored', async ($: any, on: any) => {
  expect(await fillBand($, on, 'dark', { backgroundColor: FILL_BG.dark }, '{"fill": false}')).toBe(true)
})

test('fill, unknown theme: reverse video', async ($: any, on: any) => {
  expect(await fillBand($, on, 'auto', { inverse: true })).toBe(true)
})

test('fill but a too-narrow terminal: the plain row, no background', async ($: any, on: any) => {
  const w = fresh()
  w.theme = 'dark'
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(30))
  expect(await hasProps(band, { backgroundColor: FILL_BG.dark })).toBe(false)
  await band.unmount()
})

// --- repo cell follows the session cwd ---

const IN_REPO = (slug: string, root: string, over: object = {}) =>
  JSON.stringify({ ...JSON.parse(HELPER), cwd: root, repo: slug.split('/')[1], repo_slug: slug, repo_root: root, branch: 'main', head: '', dirty: 0, gh_account: 'octo', ...over })

const REPOS = { '/w/a': IN_REPO('acme/alpha', '/w/a'), '/w/b': IN_REPO('acme/beta', '/w/b', { branch: 'dev', dirty: 3 }) }

test('the helper runs in the session cwd, and the band names that repo, branch, dirty mark and account', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = '/w/a'
  w.root = '/w/a'
  w.helperByCwd = REPOS
  world($, on, w)
  await $.session.start(START)
  expect(w.cwds.at(-1)).toBe('/w/a')
  const band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: 'acme/alpha' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: ' @ main' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: ' (octo)' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /→/ })).toBeUndefined()
  await band.unmount()
})

test('the session root is the helper cwd when the session has no cwd of its own', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = ''
  w.root = '/w/a'
  w.helperByCwd = REPOS
  world($, on, w)
  await $.session.start(START)
  expect(w.cwds.at(-1)).toBe('/w/a')
})

test('after /cd the helper reruns at once in the new directory and the band shows the new repo with an arrow', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = '/w/a'
  w.root = '/w/a'
  w.helperByCwd = REPOS
  world($, on, w)
  on('command.run', (_: any, e: any) => ({ value: { text: `cd ${e.args}` } }))
  await $.session.start(START)
  const before = w.runs.length
  // The engine moves cwd and root, then the /cd command returns.
  w.cwd = '/w/b'
  w.root = '/w/b'
  await $.command.run({ command: 'cd', args: '/w/b' })
  expect(w.runs.length).toBeGreaterThan(before)
  expect(w.cwds.at(-1)).toBe('/w/b')
  const band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: 'acme/beta' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: / @ dev/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: '*', color: 'warning' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /→/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /root:/ })).toBeUndefined()
  await band.unmount()
})

test('without any /cd event the tick still notices a changed cwd (poll is the backstop)', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = '/w/a'
  w.root = '/w/a'
  w.helperByCwd = REPOS
  world($, on, w)
  await $.session.start(START)
  w.cwd = '/w/b'
  w.root = '/w/b'
  await $.session.start(START) // runs a tick; the clock has not advanced, so only the move can trigger a refresh
  expect(w.cwds.at(-1)).toBe('/w/b')
  const band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: 'acme/beta' })).toBeDefined()
  await band.unmount()
})

test('a shell cd (cwd moved, root did not) shows the root marker; the arrow settles after two refreshes', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = '/w/a'
  w.root = '/w/a'
  w.helperByCwd = REPOS
  world($, on, w)
  await $.session.start(START)
  w.cwd = '/w/b'
  await $.session.start(START)
  let band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: /\(root: a\)/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /→/ })).toBeDefined()
  await band.unmount()
  // Poll refreshes in the same repo: the arrow stays for two refreshes in all, then settles.
  for (const [i, arrow] of [true, false].entries()) {
    w.now = 1_000_000 + (i + 1) * 20_000
    await $.session.start(START)
    band = await $.ui.mount(BAND(160))
    expect(!!(await band.find({ type: 'Text', text: /→/ }))).toBe(arrow)
    await band.unmount()
  }
})

test('/cd to a folder that is not a repo shows only the folder name', async ($: any, on: any) => {
  const w = fresh()
  w.cwd = '/w/a'
  w.root = '/w/a'
  w.helperByCwd = {
    ...REPOS,
    '/home/u/notes': JSON.stringify({ ...JSON.parse(HELPER), cwd: '/home/u/notes', repo: 'notes', repo_slug: null, repo_root: null, branch: '', dirty: null, gh_account: null }),
  }
  world($, on, w)
  await $.session.start(START)
  w.cwd = '/home/u/notes'
  w.root = '/home/u/notes'
  await $.session.start(START)
  const band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: 'notes' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /acme|@/ })).toBeUndefined()
  await band.unmount()
})

// --- ctx colours and the jobs indicator, as drawn ---

const WITH_LEDGER = (n: number) =>
  JSON.stringify({ ...JSON.parse(HELPER_AP), ledger: { running: Array.from({ length: n }, (_, i) => ({ job: i + 1, title: 't' })), lifetime_jobs: n, parked: [], next_job: n + 1, updated_at: '' } })

test('band colours: ctx 64% left is yellow, one running job shows yellow WORKING (1), none shows green READY', async ($: any, on: any) => {
  const w = fresh()
  w.helper = { exitCode: 0, stdout: WITH_LEDGER(1) }
  world($, on, w)
  await $.session.start(START)
  let band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: /ctx 64%/, color: 'warning' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'WORKING (1)', color: 'warning' })).toBeDefined()
  await band.unmount()
  w.helper = { exitCode: 0, stdout: WITH_LEDGER(0) }
  w.now = 2_000_000
  await $.session.start(START)
  band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: 'READY', color: 'success' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /WORKING/ })).toBeUndefined()
  await band.unmount()
})

test('no ledger: the band has neither READY nor WORKING', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const band = await $.ui.mount(BAND(160))
  expect(await band.find({ type: 'Text', text: /READY|WORKING/ })).toBeUndefined()
  await band.unmount()
})
