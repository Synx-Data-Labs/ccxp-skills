import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, configPaths, heartbeatPath, mergeConfig, parseConfigText, withEnabled } from './config'
import { EMPTY, bandRows, compactLine, countJobs, ctxTone, formatStamp, meter, parseHelper, tierOf, truncateWords } from './model'

const HELPER = JSON.stringify({
  task_id: 'T20261021-354035',
  task_title: 'Decouple the nightly orchestrator',
  branch: 't20261021-354035-decouple',
  worktree: '',
  autopilot: { status: 'running', prefix: '[r]', elapsed_hr: 2, requested_hr: 6, stuck: 0, cycle: 3, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 2 },
  ledger: { running: [{ job: 230, title: 'fix hud' }], lifetime_jobs: 230, parked: 3, parked_ids: ['k1', 'k2', 'k3'], next_job: 231, updated_at: '' },
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
  expect(parseConfigText('{"fields": ["ap", 3, "last"]}').fields).toEqual(['ap'])
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

test('band: wide shows every default field in full; running jobs take their own second row', async () => {
  const rows = bandRows(snap(), DEFAULTS, 140)
  expect(rows.length).toBe(2)
  expect(text(rows.slice(1))).toContain("jobs run 1")
  const t = text(rows)
  expect(t).toContain('AP ● running 2/6h · cycle 3 ✓2 merged')
  expect(t).toContain('ctx 64% ▓▓▓▓▓▓░░░░')
  expect(t).toContain('t20261021-354035-decouple')
  expect(t).toContain('T20261021-354035 Decouple the nightly orchestrator')
  expect(t).toContain('jobs run 1 · park 3 · tot 230 (r230 fix hud)')
  expect(t).not.toContain('stuck')
})

test('band: compact (70-99 cols) uses short labels, short ids, at most two rows', async () => {
  const rows = bandRows(snap(), DEFAULTS, 80)
  expect(rows.length).toBeLessThanOrEqual(2)
  const t = text(rows)
  expect(t).toContain('AP ● run 2/6h c3 ✓2')
  expect(t).toContain('ctx 64%')
  expect(t).not.toContain('▓')
  expect(t).toContain('run 1 · park 3 · tot 230 (r230)')
  expect(t).not.toContain('fix hud')
  for (const r of rows) expect(r.map(x => x.text).join('').length).toBeLessThanOrEqual(78)
})

test('tier boundaries: tiny below 70, compact below 100, wide from 100', async () => {
  expect([tierOf(40), tierOf(69), tierOf(70), tierOf(99), tierOf(100), tierOf(200)]).toEqual(['tiny', 'tiny', 'compact', 'compact', 'wide', 'wide'])
})

// The pasted half-screen example: stopped autopilot 13/24h, no claimed task, no branch, 89% context left, five running jobs.
const PASTED = snap({
  ctxLeft: 89,
  helper: {
    ...parseHelper(HELPER)!,
    task_id: '',
    task_title: '',
    branch: '',
    autopilot: { ...parseHelper(HELPER)!.autopilot!, status: 'stopped', prefix: '[s]', elapsed_hr: 13, requested_hr: 24, cycle: 6, merged: 2, stop_reason: 'elapsed' },
    ledger: {
      running: [
        { job: 230, title: 'Retention keep-set first PR' },
        { job: 231, title: 'iceberg-gopher 4.0.7 publish' },
        { job: 239, title: 'Silent drift in the nightly orchestrator' },
        { job: 240, title: 'Fix hud' },
        { job: 241, title: 'Docs sweep' },
      ],
      lifetime_jobs: 242,
      parked: 3,
      parked_ids: [],
      next_job: 243,
      updated_at: '',
    },
  },
})

test('band at 60/80/100/160 columns on the pasted example: fits, no blank cells, unambiguous labels', async () => {
  const cases: [number, string[], number][] = [
    [60, ['AP ○ 13/24h ✓2', 'ctx 89%', 'run 5 · park 3'], 1],
    [80, ['AP ○ stop 13/24h c6 ✓2', 'ctx 89%', 'run 5 · park 3 · tot 242 (r230 r231 +3)'], 1],
    [100, ['AP ○ stopped 13/24h · cycle 6 ✓2 merged', 'jobs run 5 · park 3 · tot 242 (r230 Retention keep-set first PR +4)'], 2],
    [160, ['jobs run 5 · park 3 · tot 242 (r230 Retention keep-set first PR, r231 iceberg-gopher 4.0.7 publish, r239 Silent drift in the nightly…, r240 Fix hud +1)'], 2],
  ]
  for (const [cols, expected, nrows] of cases) {
    const rows = bandRows(PASTED, DEFAULTS, cols)
    expect(rows.length).toBe(nrows)
    const t = text(rows)
    for (const e of expected) expect(t).toContain(e)
    for (const r of rows) {
      const line = r.map(x => x.text).join('')
      expect(line.length).toBeLessThanOrEqual(cols - 2)
      expect(line).not.toMatch(/│\s*│/) // no empty cell between separators
      expect(line).not.toMatch(/ {2,}/) // no padding runs
    }
    expect(t).not.toContain('no claimed')
    expect(t).not.toContain('jobs —')
  }
  // Tiny keeps one row and only what matters.
  expect(bandRows(PASTED, DEFAULTS, 60).length).toBe(1)
})

test('band: unclaimed task, empty branch and a missing ledger leave no cell at all', async () => {
  const h = parseHelper(HELPER)!
  const t = text(bandRows(snap({ helper: { ...h, task_id: '', branch: '', ledger: null } }), DEFAULTS, 140))
  expect(t).toBe('AP ● running 2/6h · cycle 3 ✓2 merged │ ctx 64% ▓▓▓▓▓▓░░░░')
})

test('band: jobs with nothing running or parked shows just the total; running ids vanish at tiny width', async () => {
  const h = parseHelper(HELPER)!
  const idle = { ...h.ledger!, running: [], parked: 0 }
  expect(text(bandRows(snap({ helper: { ...h, ledger: idle } }), { ...DEFAULTS, fields: ['jobs'] }, 140))).toBe('jobs tot 230')
  expect(text(bandRows(snap(), { ...DEFAULTS, fields: ['jobs'] }, 60))).toBe('run 1 · park 3')
})

test('band: when the row budget is short, low-priority fields (last input, branch, task) go first', async () => {
  const h = parseHelper(HELPER)!
  const t = text(bandRows(snap({ helper: { ...h, last_input_at: Date.now() / 1000 } }), DEFAULTS, 60))
  expect(t).toContain('AP ')
  expect(t).toContain('ctx 64%')
  expect(t).not.toContain('you ')
  expect(t).not.toContain('t20261021')
})

test('truncateWords: whole words only, with an ellipsis; a single long word is hard-cut', async () => {
  expect(truncateWords('Silent drift in the nightly orchestrator', 28)).toBe('Silent drift in the nightly…')
  expect(truncateWords('short', 28)).toBe('short')
  expect(truncateWords('x'.repeat(40), 10)).toBe('xxxxxxxxx…')
  expect(truncateWords('anything', 0)).toBe('')
})

test('band: empty when there is no data, and respects the fields list', async () => {
  expect(bandRows(EMPTY, { ...DEFAULTS, fields: ['ap', 'ctx', 'branch', 'task'] }, 140)).toEqual([])
  expect(text(bandRows(snap(), { ...DEFAULTS, fields: ['ctx'] }, 140))).toBe('ctx 64% ▓▓▓▓▓▓░░░░')
})

test('band: a stale snapshot carries the stale tag; the task title is cut at a word to the room', async () => {
  expect(text(bandRows(snap({ stale: true }), DEFAULTS, 140))).toContain('stale')
  const long = snap({ helper: { ...parseHelper(HELPER)!, task_title: 'word '.repeat(60) } })
  expect(text(bandRows(long, { ...DEFAULTS, fields: ['task'] }, 140)).length).toBeLessThanOrEqual(70)
  expect(text(bandRows(long, { ...DEFAULTS, fields: ['task'] }, 140))).toMatch(/word…$/)
})

test('band: autopilot looks per state; an unclaimed task shows nothing', async () => {
  const mk = (prefix: string, status: string) => snap({ helper: { ...parseHelper(HELPER)!, task_id: '', autopilot: { ...parseHelper(HELPER)!.autopilot!, prefix, status } } })
  expect(text(bandRows(mk('[b]', 'running'), DEFAULTS, 140))).toContain('running')
  expect(text(bandRows(mk('[s]', 'stopped'), DEFAULTS, 140))).toContain('stopped')
  expect(text(bandRows(mk('[p]', 'paused'), DEFAULTS, 140))).toContain('paused')
  expect(text(bandRows(mk('[p]', 'paused'), DEFAULTS, 80))).toContain('pause')
  expect(text(bandRows(mk('[r]', 'running'), DEFAULTS, 140))).not.toContain('no claimed')
})

test('band: AP colours and stuck marker, jobs colours; no ledger means no jobs cell', async () => {
  const h = parseHelper(HELPER)!
  expect(bandRows(snap({ helper: { ...h, ledger: null } }), { ...DEFAULTS, fields: ['jobs'] }, 140)).toEqual([])
  const wide = bandRows(snap(), { ...DEFAULTS, fields: ['jobs'] }, 140)
  expect(text(wide)).toContain('r230 fix hud')
  expect(wide[0].find(s => s.text === 'park 3')?.color).toBe('warning')
  expect(wide[0].find(s => s.text === 'run 1')?.color).toBe('success')
  const ap = (over: object) => bandRows(snap({ helper: { ...h, autopilot: { ...h.autopilot!, ...over } } }), { ...DEFAULTS, fields: ['ap'] }, 140)[0]
  expect(ap({ stuck: 2 }).find(s => s.text === ' ⚠2')?.color).toBe('error')
  expect(ap({}).some(s => s.text.includes('⚠'))).toBe(false)
  expect(ap({ prefix: '[p]', status: 'paused' }).find(s => s.text.includes('paused'))?.color).toBe('warning')
  expect(ap({ prefix: '[s]', status: 'stopped', stop_reason: 'elapsed' }).find(s => s.text.includes('stopped'))?.color).toBe('inactive')
  expect(ap({ prefix: '[s]', status: 'stopped', stop_reason: 'dispatch failed' }).find(s => s.text.includes('stopped'))?.color).toBe('error')
  expect(ap({ merged: 0 }).find(s => s.text === '✓0 merged')?.dim).toBe(true)
  expect(parseHelper('{"branch":"m","autopilot":{"status":"running"}}')?.autopilot?.merged).toBe(0)
})

test('formatStamp: HH:MM today, with the date otherwise; lastat field hidden when unknown', async () => {
  const at = new Date(2026, 9, 24, 9, 5).getTime() / 1000
  expect(formatStamp(at, new Date(2026, 9, 24, 23, 0).getTime())).toBe('09:05')
  expect(formatStamp(at, new Date(2026, 9, 25, 8, 0).getTime())).toBe('Oct 24 09:05')
  const h = parseHelper(HELPER)!
  const fields = { ...DEFAULTS, fields: ['lastat' as const] }
  expect(bandRows(snap({ helper: { ...h, last_input_at: Date.now() / 1000 } }), fields, 140)[0][0].text).toMatch(/^you \d\d:\d\d$/)
  expect(bandRows(snap({ helper: { ...h, last_input_at: 0 } }), fields, 140)).toEqual([])
})

test('compactLine is one plain line within the 2,000 character limit', async () => {
  const line = compactLine(snap(), DEFAULTS)
  expect(line).not.toContain('\n')
  expect(line.length).toBeLessThanOrEqual(2000)
})
