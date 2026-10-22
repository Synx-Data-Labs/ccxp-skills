import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, configPaths, heartbeatPath, mergeConfig, parseConfigText, withEnabled } from './config'
import { EMPTY, bandRows, compactLine, countJobs, ctxTone, meter, parseHelper } from './model'

const HELPER = JSON.stringify({
  task_id: 'T20261021-354035',
  task_title: 'Decouple the nightly orchestrator',
  branch: 't20261021-354035-decouple',
  worktree: '',
  autopilot: { status: 'running', prefix: '[r]', elapsed_hr: 2, requested_hr: 6, stuck: 0, cycle: 3, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '' },
  last_input: '',
})

const snap = (over = {}) => ({ ...EMPTY, helper: parseHelper(HELPER), ctxLeft: 64, ...over })
const text = (rows: { text: string }[][]) => rows.map(r => r.map(s => s.text).join('')).join('\n')

test('config: missing, empty, malformed or non-object input means the defaults (on)', async () => {
  for (const input of [undefined, null, '', '   ', '{not json', '[]', '"str"', '42', 'null']) {
    expect(mergeConfig(parseConfigText(input), {})).toEqual(DEFAULTS)
  }
  expect(DEFAULTS.enabled).toBe(true)
})

test('config: only enabled === false turns it off; wrong types are ignored', async () => {
  expect(mergeConfig(parseConfigText('{"enabled": false}'), {}).enabled).toBe(false)
  expect(mergeConfig(parseConfigText('{"enabled": "false"}'), {}).enabled).toBe(true)
  expect(mergeConfig(parseConfigText('{"enabled": 0}'), {}).enabled).toBe(true)
  expect(mergeConfig(parseConfigText('{"band": 1, "userMessage": null}'), {})).toEqual(DEFAULTS)
})

test('config: project overrides user overrides defaults, key by key', async () => {
  const cfg = mergeConfig(parseConfigText('{"enabled": false, "band": false}'), parseConfigText('{"enabled": true}'))
  expect(cfg.enabled).toBe(true)
  expect(cfg.band).toBe(false)
  expect(cfg.userMessage).toBe(true)
})

test('config: fields take a list or a comma string, drop unknown names', async () => {
  expect(parseConfigText('{"fields": "ctx, task,bogus,ctx"}').fields).toEqual(['ctx', 'task'])
  expect(parseConfigText('{"fields": ["ap", 3, "last"]}').fields).toEqual(['ap', 'last'])
})

test('config: numbers are clamped (poll minimum 5, crit never above warn)', async () => {
  expect(mergeConfig(parseConfigText('{"pollSeconds": 1}'), {}).pollSeconds).toBe(5)
  const c = mergeConfig(parseConfigText('{"ctxWarn": 30, "ctxCrit": 80}'), {})
  expect(c.ctxCrit).toBe(30)
})

test('config: an unknown border draws none; known ones pass through', async () => {
  expect(borderOf({ ...DEFAULTS, userBorder: 'zigzag' })).toBeUndefined()
  expect(borderOf(DEFAULTS)).toBe('quote')
})

test('config: paths honour CLAUDE_CONFIG_DIR, else HOME/.claude; withEnabled keeps other keys', async () => {
  expect(configPaths({ configDir: '/c', home: '/h' }, '/p')).toEqual({ user: '/c/ccxp-hud.json', project: '/p/.claude/ccxp-hud.json' })
  expect(configPaths({ home: '/h' }).user).toBe('/h/.claude/ccxp-hud.json')
  expect(configPaths({}).user).toBeUndefined()
  expect(JSON.parse(withEnabled('{"band": false}', false))).toEqual({ band: false, enabled: false })
  expect(JSON.parse(withEnabled('garbage', true))).toEqual({ enabled: true })
})

test('heartbeat path refuses a session id that could escape the directory', async () => {
  expect(heartbeatPath({ home: '/h' }, 's1')).toBe('/h/.claude/state/hud-active/s1')
  for (const bad of ['', '..', '.', '../x', 'a/b', 'a\\b']) expect(heartbeatPath({ home: '/h' }, bad)).toBeUndefined()
})

test('parseHelper: accepts the helper object, rejects garbage and its failure answer', async () => {
  expect(parseHelper(HELPER)?.autopilot?.prefix).toBe('[r]')
  expect(parseHelper('{}')).toBeNull()
  expect(parseHelper('nope')).toBeNull()
  expect(parseHelper('[]')).toBeNull()
  expect(parseHelper('')).toBeNull()
  expect(parseHelper('{"branch":"main","autopilot":null}')?.autopilot).toBeNull()
})

test('ctxTone: green above warn, yellow to crit, red below', async () => {
  expect(ctxTone(64, DEFAULTS)).toBe('success')
  expect(ctxTone(40, DEFAULTS)).toBe('warning')
  expect(ctxTone(15, DEFAULTS)).toBe('warning')
  expect(ctxTone(14, DEFAULTS)).toBe('error')
  expect(meter(50)).toBe('▓▓▓▓▓░░░░░')
})

test('countJobs groups agent statuses', async () => {
  expect(countJobs([{ status: 'running' }, { status: 'pending' }, { status: 'idle' }, { status: 'waiting' }, { status: 'failed' }, { status: 'completed' }])).toEqual({ running: 2, waiting: 2, failed: 1 })
})

test('band: one row at 140 columns, two at 80, with every default field', async () => {
  const wide = bandRows(snap(), DEFAULTS, 140)
  const narrow = bandRows(snap(), DEFAULTS, 80)
  expect(wide.length).toBe(1)
  expect(narrow.length).toBe(2)
  for (const t of [text(wide), text(narrow)]) {
    expect(t).toContain('AP ')
    expect(t).toContain('ctx 64%')
    expect(t).toContain('t20261021-354035-decouple')
    expect(t).toContain('T20261021-354035')
    expect(t).toContain('jobs 0▶')
  }
})

test('band: empty when there is no data, and respects the fields list', async () => {
  expect(bandRows(EMPTY, { ...DEFAULTS, fields: ['ap', 'ctx', 'branch', 'task'] }, 140)).toEqual([])
  expect(text(bandRows(snap(), { ...DEFAULTS, fields: ['ctx'] }, 140))).toBe('ctx 64% ▓▓▓▓▓▓░░░░')
})

test('band: a stale snapshot carries the stale tag; the task title is truncated to the room', async () => {
  expect(text(bandRows(snap({ stale: true }), DEFAULTS, 140))).toContain('stale')
  const long = snap({ helper: { ...parseHelper(HELPER)!, task_title: 'x'.repeat(300) } })
  expect(text(bandRows(long, { ...DEFAULTS, fields: ['task'] }, 60)).length).toBeLessThan(60)
})

test('band: autopilot looks per state; unclaimed shows "no claimed task"', async () => {
  const mk = (prefix: string, status: string) => snap({ helper: { ...parseHelper(HELPER)!, task_id: '', autopilot: { ...parseHelper(HELPER)!.autopilot!, prefix, status } } })
  expect(text(bandRows(mk('[b]', 'running'), DEFAULTS, 140))).toContain('backoff')
  expect(text(bandRows(mk('[s]', 'stopped'), DEFAULTS, 140))).toContain('stopped')
  expect(text(bandRows(mk('[p]', 'paused'), DEFAULTS, 140))).toContain('paused')
  expect(text(bandRows(mk('[r]', 'running'), DEFAULTS, 140))).toContain('no claimed task')
})

test('compactLine is one plain line within the 2,000 character limit', async () => {
  const line = compactLine(snap(), DEFAULTS)
  expect(line).not.toContain('\n')
  expect(line.length).toBeLessThanOrEqual(2000)
})
