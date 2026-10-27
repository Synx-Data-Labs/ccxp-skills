import { expect, test } from 'claude-code/testing'

import { USER_TEXT_COLOR } from './config'

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
const HELPER_AP = JSON.stringify({ ...JSON.parse(HELPER), autopilot: { status: 'running', prefix: '[r]', elapsed_hr: 1, requested_hr: 4, stuck: 0, cycle: 2, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 1 } })

type World = {
  cfg?: string
  projectCfg?: string
  helper?: { exitCode: number; stdout: string } | 'throw'
  writes: { path: string; text: string }[]
  runs: string[][]
  stdins: string[]
  panes: { id: string }[]
  closed: string[]
  statuses: (string | undefined)[]
}

// Stands for the engine beneath the mod: every hook here answers `{ value }`.
function world($: any, on: any, w: World) {
  on('env.get', (_: any, e: any) => ({ value: e.name === 'HOME' ? '/home/u' : undefined }))
  on('session.root', () => ({ value: '/proj' }))
  on('session.cwd', () => ({ value: '/proj' }))
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
    w.stdins.push(JSON.stringify(e))
    if (w.helper === 'throw') throw new Error('boom')
    return { value: w.helper ?? { exitCode: 0, stdout: HELPER, stderr: '' } }
  })
  on('agent.list', () => ({ value: [{ status: 'running' }, { status: 'failed' }] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000, percent: 36 }, rateLimits: [] } }))
  on('ui.panes', () => ({ value: w.panes }))
  on('ui.open', (_: any, e: any) => {
    w.panes.push({ id: e.id })
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_: any, e: any) => {
    w.closed.push(e.id)
    w.panes = w.panes.filter(p => p.id !== e.id)
    return { value: undefined }
  })
  on('clock.now', () => ({ value: 1_000_000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'hud' } }))
  on('ui.status', (_: any, e: any) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  // The engine's own drawing of every site the mod hooks.
  on('ui.render', ($: any, e: any) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
}

const fresh = (): World => ({ writes: [], runs: [], statuses: [], stdins: [], panes: [], closed: [] })

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

test('/hud pane is a toggle: the first run opens the pane, the second closes it, the third opens it again', async ($: any, on: any) => {
  const w = fresh()
  world($, on, w)
  await $.session.start(START)
  const first = await $.command.run({ command: 'hud', args: 'pane' })
  expect(first.text).toMatch(/opened/)
  expect(w.panes.map(p => p.id)).toEqual(['ccxp-hud'])
  const second = await $.command.run({ command: 'hud', args: 'pane' })
  expect(second.text).toMatch(/closed/)
  expect(w.closed).toEqual(['ccxp-hud'])
  expect(w.panes).toEqual([])
  const third = await $.command.run({ command: 'hud', args: 'pane' })
  expect(third.text).toMatch(/opened/)
})
