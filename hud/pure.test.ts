import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, configPaths, heartbeatPath, mergeConfig, parseConfigText, withEnabled } from './config'
import { EMPTY, baseName, bandRows, compactLine, countJobs, ctxTone, formatStamp, jobState, meter, isWithin, parseHelper, tierOf, truncateWords } from './model'

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

test('ctxTone: green above 75 left, yellow above 50, red at 50 and below (strict boundaries)', async () => {
  expect([DEFAULTS.ctxWarn, DEFAULTS.ctxCrit]).toEqual([75, 50])
  const tone = (n: number) => ctxTone(n, DEFAULTS)
  expect([100, 89, 76].map(tone)).toEqual(['success', 'success', 'success'])
  expect([75, 64, 51].map(tone)).toEqual(['warning', 'warning', 'warning'])
  expect([50, 49, 15, 0].map(tone)).toEqual(['error', 'error', 'error', 'error'])
  // Custom thresholds keep the same strict reading.
  const custom = { ctxWarn: 40, ctxCrit: 15 }
  expect([41, 40, 16, 15].map(n => ctxTone(n, custom))).toEqual(['success', 'warning', 'warning', 'error'])
  expect(meter(50)).toBe('▓▓▓▓▓░░░░░')
})

test('jobState: green READY with zero running jobs, yellow WORKING (N) from one up', async () => {
  expect(jobState(0)).toEqual({ text: 'READY', color: 'success' })
  expect(jobState(1)).toEqual({ text: 'WORKING (1)', color: 'warning' })
  expect(jobState(5)).toEqual({ text: 'WORKING (5)', color: 'warning' })
})

test('countJobs groups agent statuses', async () => {
  expect(countJobs([{ status: 'running' }, { status: 'pending' }, { status: 'idle' }, { status: 'waiting' }, { status: 'failed' }, { status: 'completed' }])).toEqual({ running: 2, waiting: 2, failed: 1 })
})

test('band: wide shows every default field in full; running jobs get a row with room for titles', async () => {
  const rows = bandRows(snap(), DEFAULTS, 140)
  expect(rows.length).toBeLessThanOrEqual(3)
  expect(text(rows.slice(-1))).toContain("jobs WORKING (1)")
  const t = text(rows)
  expect(t).toContain('AP ● running 2/6h · cycle 3 ✓2 merged')
  expect(t).toContain('ctx 64% ▓▓▓▓▓▓░░░░')
  expect(t).toContain('t20261021-354035-decouple')
  expect(t).toContain('T20261021-354035 Decouple the nightly orchestrator')
  expect(t).toContain('jobs WORKING (1) · park 3 · tot 230 (r230 fix hud)')
  expect(t).not.toContain('stuck')
})

test('band: compact (70-99 cols) uses short labels, short ids, at most two rows', async () => {
  const rows = bandRows(snap(), DEFAULTS, 80)
  expect(rows.length).toBeLessThanOrEqual(2)
  const t = text(rows)
  expect(t).toContain('AP ● run 2/6h c3 ✓2')
  expect(t).toContain('ctx 64%')
  expect(t).not.toContain('▓')
  expect(t).toContain('WORKING (1) · park 3 · tot 230 (r230)')
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
    [60, ['AP ○ 13/24h ✓2', 'ctx 89%', 'WORKING (5) · park 3'], 1],
    [80, ['AP ○ stop 13/24h c6 ✓2', 'ctx 89%', 'WORKING (5) · park 3 · tot 242 (r230 +4)'], 1],
    [100, ['AP ○ stopped 13/24h · cycle 6 ✓2 merged', 'jobs WORKING (5) · park 3 · tot 242 (r230 Retention keep-set first PR +4)'], 2],
    [160, ['jobs WORKING (5) · park 3 · tot 242 (r230 Retention keep-set first PR, r231 iceberg-gopher 4.0.7 publish, r239 Silent drift in the nightly…, r240 Fix hud +1)'], 2],
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

test('band: jobs with nothing running shows READY (green) and the total; running ids vanish at tiny width', async () => {
  const h = parseHelper(HELPER)!
  const idle = { ...h.ledger!, running: [], parked: 0 }
  expect(text(bandRows(snap({ helper: { ...h, ledger: idle } }), { ...DEFAULTS, fields: ['jobs'] }, 140))).toBe('jobs READY · tot 230')
  expect(text(bandRows(snap({ helper: { ...h, ledger: idle } }), { ...DEFAULTS, fields: ['jobs'] }, 60))).toBe('READY')
  expect(text(bandRows(snap({ helper: { ...h, ledger: { ...idle, parked: 3 } } }), { ...DEFAULTS, fields: ['jobs'] }, 80))).toBe('READY · park 3 · tot 230')
  expect(text(bandRows(snap(), { ...DEFAULTS, fields: ['jobs'] }, 60))).toBe('WORKING (1) · park 3')
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

test('band: ctx text is coloured by context left at the 75/50 boundaries', async () => {
  const colour = (n: number) => bandRows(snap({ ctxLeft: n }), { ...DEFAULTS, fields: ['ctx'] }, 140)[0][0].color
  expect([100, 76, 75, 51, 50, 0].map(colour)).toEqual(['success', 'success', 'warning', 'warning', 'error', 'error'])
})

test('band: AP colours and stuck marker, jobs colours; no ledger means no jobs cell', async () => {
  const h = parseHelper(HELPER)!
  expect(bandRows(snap({ helper: { ...h, ledger: null } }), { ...DEFAULTS, fields: ['jobs'] }, 140)).toEqual([])
  const wide = bandRows(snap(), { ...DEFAULTS, fields: ['jobs'] }, 140)
  expect(text(wide)).toContain('r230 fix hud')
  expect(wide[0].find(s => s.text === 'park 3')?.color).toBe('warning')
  expect(wide[0].find(s => s.text === 'WORKING (1)')?.color).toBe('warning')
  const idleLedger = { ...h.ledger!, running: [] }
  const idle = bandRows(snap({ helper: { ...h, ledger: idleLedger } }), { ...DEFAULTS, fields: ['jobs'] }, 140)
  expect(idle[0].find(s => s.text === 'READY')?.color).toBe('success')
  expect(idle[0].some(s => s.text.includes('WORKING'))).toBe(false)
  const three = { ...h.ledger!, running: [1, 2, 3].map(job => ({ job, title: 't' })) }
  expect(bandRows(snap({ helper: { ...h, ledger: three } }), { ...DEFAULTS, fields: ['jobs'] }, 140)[0].find(s => s.text === 'WORKING (3)')?.color).toBe('warning')
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

test('compactLine joins rows with the separator, never a bare space', async () => {
  expect(compactLine(snap(), DEFAULTS)).not.toMatch(/[^│] (?=jobs WORKING)/)
})

test('compactLine is one plain line within the 2,000 character limit', async () => {
  const line = compactLine(snap(), DEFAULTS)
  expect(line).not.toContain('\n')
  expect(line.length).toBeLessThanOrEqual(2000)
})

// --- repo field (multi-repo Phase 1) ---

const REPO_HELPER = (over: object = {}) => ({
  ...parseHelper(HELPER)!,
  cwd: '/w/acme/widgets',
  repo: 'acme/widgets',
  repo_root: '/w/acme/widgets',
  branch: 'main',
  head: '',
  dirty: 0,
  gh_account: 'octo',
  ...over,
})
const REPO_ONLY = { ...DEFAULTS, fields: ['repo' as const] }

test('parseHelper: repo fields default to unknown, and a helper without them still parses', async () => {
  const h = parseHelper(HELPER)!
  expect([h.cwd, h.repo, h.repo_root, h.head, h.dirty, h.gh_account]).toEqual(['', null, null, '', null, null])
  const r = parseHelper('{"branch":"m","cwd":"/a","repo":"o/r","repo_root":"/a","head":"abc1234","dirty":3,"gh_account":"octo"}')!
  expect([r.cwd, r.repo, r.repo_root, r.head, r.dirty, r.gh_account]).toEqual(['/a', 'o/r', '/a', 'abc1234', 3, 'octo'])
  expect(parseHelper('{"branch":"m","repo":"","dirty":"x","gh_account":""}')).toMatchObject({ repo: null, dirty: null, gh_account: null })
})

test('repo: wide shows slug, branch, dirty marker, worktree and account; the branch field steps aside', async () => {
  const wide = (over: object) => text(bandRows(snap({ helper: REPO_HELPER(over) }), REPO_ONLY, 140))
  expect(wide({})).toBe('repo: acme/widgets @ main (octo)')
  expect(wide({ dirty: 4 })).toBe('repo: acme/widgets @ main* (octo)')
  expect(wide({ worktree: 'widgets-wt' })).toBe('repo: acme/widgets @ main (wt widgets-wt) (octo)')
  expect(wide({ gh_account: null })).toBe('repo: acme/widgets @ main')
  expect(wide({ dirty: null })).toBe('repo: acme/widgets @ main (octo)')
  const both = text(bandRows(snap({ helper: REPO_HELPER() }), { ...DEFAULTS, fields: ['repo', 'branch'] }, 140))
  expect(both.match(/main/g)?.length).toBe(1)
  // Default fields: the repo comes first and the branch is not repeated.
  const all = text(bandRows(snap({ helper: REPO_HELPER({ branch: 't1-x' }) }), DEFAULTS, 140))
  expect(all.startsWith('repo: acme/widgets @ t1-x (octo) │ AP')).toBe(true)
  expect(all.match(/t1-x/g)?.length).toBe(1)
})

test('repo: detached HEAD shows the short id; the marker colours', async () => {
  expect(text(bandRows(snap({ helper: REPO_HELPER({ branch: '', head: 'abc1234' }) }), REPO_ONLY, 140))).toContain('@ detached abc1234')
  const row = bandRows(snap({ helper: REPO_HELPER({ dirty: 2 }) }), REPO_ONLY, 140)[0]
  expect(row.find(s => s.text === '*')?.color).toBe('warning')
  expect(row.find(s => s.text === 'acme/widgets')?.bold).toBe(true)
})

test('repo: compact uses the short name, tiny keeps name and dirty star only', async () => {
  expect(text(bandRows(snap({ helper: REPO_HELPER({ dirty: 1 }) }), REPO_ONLY, 80))).toBe('widgets @ main* (octo)')
  expect(text(bandRows(snap({ helper: REPO_HELPER({ dirty: 1 }) }), REPO_ONLY, 60))).toBe('widgets*')
  expect(text(bandRows(snap({ helper: REPO_HELPER() }), REPO_ONLY, 60))).toBe('widgets')
  const rows = bandRows(snap({ helper: REPO_HELPER() }), DEFAULTS, 60)
  expect(rows.length).toBe(1)
  expect(text(rows)).toContain('widgets')
  expect(text(rows)).toContain('AP ')
})

test('repo: outside a repo only the folder name shows; no cwd at all shows nothing', async () => {
  const none = { repo: null, repo_root: null, dirty: null, gh_account: null, branch: '', cwd: '/home/u/notes' }
  expect(text(bandRows(snap({ helper: REPO_HELPER(none) }), REPO_ONLY, 140))).toBe('dir: notes')
  expect(text(bandRows(snap({ helper: REPO_HELPER(none) }), REPO_ONLY, 80))).toBe('notes')
  expect(bandRows(snap({ helper: REPO_HELPER({ ...none, cwd: '' }) }), REPO_ONLY, 140)).toEqual([])
})

test('repo: the moved arrow leads the repo; the root marker shows only when the cwd left the session root', async () => {
  const moved = bandRows(snap({ helper: REPO_HELPER(), moved: true }), REPO_ONLY, 140)[0]
  expect(moved[0]).toMatchObject({ text: '→ ', bold: true })
  expect(text([moved])).toBe('→ repo: acme/widgets @ main (octo)')
  expect(text(bandRows(snap({ helper: REPO_HELPER() }), REPO_ONLY, 140))).not.toContain('→')
  // Same root as the cwd, or the cwd below the root: no marker.
  expect(text(bandRows(snap({ helper: REPO_HELPER(), sessionRoot: '/w/acme/widgets' }), REPO_ONLY, 140))).not.toContain('root')
  expect(text(bandRows(snap({ helper: REPO_HELPER({ cwd: '/w/acme/widgets/sub' }), sessionRoot: '/w/acme/widgets' }), REPO_ONLY, 140))).not.toContain('root')
  // A shell cd into another repo leaves the root behind.
  const half = text(bandRows(snap({ helper: REPO_HELPER(), sessionRoot: '/w/other/launch' }), REPO_ONLY, 140))
  expect(half).toBe('repo: acme/widgets @ main (octo) (root: launch)')
  expect(text(bandRows(snap({ helper: REPO_HELPER(), sessionRoot: '/w/other/launch' }), REPO_ONLY, 60))).not.toContain('root')
})

test('baseName and isWithin', async () => {
  expect([baseName('/a/b/'), baseName('/'), baseName('')]).toEqual(['b', '', ''])
  expect([isWithin('/a/b', '/a/b'), isWithin('/a/b/c', '/a/b/'), isWithin('/a/bc', '/a/b')]).toEqual([true, true, false])
})

test('repo: long names are cut and every row fits the width', async () => {
  const h = REPO_HELPER({ repo: 'some-long-organisation/a-really-quite-long-repository-name-here', branch: 'feature/' + 'x'.repeat(60) })
  for (const cols of [60, 80, 100, 140]) {
    for (const r of bandRows(snap({ helper: h }), DEFAULTS, cols)) {
      expect(r.map(x => x.text).join('').length).toBeLessThanOrEqual(cols - 2)
    }
  }
})
