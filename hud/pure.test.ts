import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, ciFromAnswer, cleanAnswer, configPaths, heartbeatPath, mergeConfig, parseCi, parseConfigText, withConfig, withEnabled } from './config'
import { FILL_BG, FILL_COLORS, charWidth, displayWidth, fillRow, fillStyleFor, fitSegs, stripAnsi, truncateDisplay } from './fill'
import { alertSegs, isAlertRow } from './render'
import { EMPTY, bandRows, baseName, compactLine, countJobs, ctxTone, detailRows, formatAge, formatIn, formatStamp, isApOn, isNewer, isWithin, jobState, meter, parseHelper, tierOf, truncateWords, versionState } from './model'

const NOW = Math.floor(Date.now() / 1000)
const RUN_AT = new Date(2026, 9, 26, 3, 0).getTime() / 1000
const AP = { status: 'on', prefix: '[r]', elapsed_hr: 2, requested_hr: 6, stuck: 0, cycle: 3, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 2, next_wake_at: 0, busy: false, current_task: '' }
const BASE = {
  repo: 'synxdb-build-pipeline',
  task_id: 'T20261021-354035',
  task_title: 'Decouple the nightly orchestrator',
  branch: 't20261021-354035-decouple',
  worktree: '',
  cwd: '/work/synxdb-build-pipeline',
  repo_slug: null as string | null,
  repo_root: '/work/synxdb-build-pipeline' as string | null,
  head: '',
  dirty: 0 as number | null,
  gh_account: null as string | null,
  autopilot: null as any,
  ledger: { running: [{ job: 230, title: 'fix hud' }], lifetime_jobs: 230, parked: [{ id: 'k1' }, { id: 'k2' }, { id: 'k3' }], next_job: 231, updated_at: '' },
  ci: { state: 'failing', at: RUN_AT },
  last_input_at: NOW,
}
const HELPER = JSON.stringify(BASE)
const HELPER_AP = JSON.stringify({ ...BASE, autopilot: AP })

const snap = (over = {}, helper = HELPER) => ({ ...EMPTY, helper: parseHelper(helper), ctxLeft: 64, ...over })
const snapAp = (over = {}) => snap(over, HELPER_AP)
const withHelper = (h: object, base = HELPER) => ({ ...EMPTY, ctxLeft: 64, helper: { ...parseHelper(base)!, ...h } })
const text = (rows: { text: string }[][]) => rows.map(r => r.map(s => s.text).join('')).join('\n')
const CI = { ...DEFAULTS, ci: { workflow: 'nightly.yml' } }
/** No `ci` configured: the band is the one main row. */
const NOCI = { ...DEFAULTS }

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

test('config: ci defaults to unset (no CI segment); jobs is the READY/WORKING cell again, `last` stays retired', async () => {
  expect(DEFAULTS.ci).toBeUndefined()
  expect(DEFAULTS.fields).toContain('jobs')
  expect(parseConfigText('{"fields": "ap,ctx,branch,task,jobs,last,lastat"}').fields).toEqual(['ap', 'ctx', 'branch', 'task', 'jobs', 'lastat'])
})

test('config: ctx thresholds default to 75 / 50 (context LEFT); custom values are kept and clamped', async () => {
  expect([DEFAULTS.ctxWarn, DEFAULTS.ctxCrit]).toEqual([75, 50])
  const c = mergeConfig(parseConfigText('{"ctxWarn": 40, "ctxCrit": 15}'), {})
  expect([c.ctxWarn, c.ctxCrit]).toEqual([40, 15])
})

test('config: ci block is validated; unconfigured and bad values mean no CI', async () => {
  expect(parseCi({ workflow: 'nightly-orchestrator.yml' })).toEqual({ workflow: 'nightly-orchestrator.yml' })
  expect(parseCi('nightly.yml')).toEqual({ workflow: 'nightly.yml' })
  expect(parseCi({ workflow: 'w.yml', branch: 'release/4.8', repo: 'acme/widgets' })).toEqual({ workflow: 'w.yml', branch: 'release/4.8', repo: 'acme/widgets' })
  expect(parseCi({ workflow: 'w.yml', branch: 'bad branch;x', repo: 'nope' })).toEqual({ workflow: 'w.yml' })
  for (const bad of [undefined, null, 5, [], {}, { workflow: '' }, { workflow: 'a b.yml' }, { workflow: 'x;y' }, { workflow: '$(id)' }, { workflow: 7 }, { workflow: '-f' }]) expect(parseCi(bad)).toBeUndefined()
  expect(mergeConfig(parseConfigText('{"ci": {"workflow": "a b"}}'), {}).ci).toBeUndefined()
})

test('config: project ci overrides user ci; a project ci of null switches it off', async () => {
  const user = parseConfigText('{"ci": {"workflow": "user.yml"}}')
  expect(mergeConfig(user, {}).ci).toEqual({ workflow: 'user.yml' })
  expect(mergeConfig(user, parseConfigText('{"ci": {"workflow": "proj.yml"}}')).ci).toEqual({ workflow: 'proj.yml' })
  expect(mergeConfig(user, parseConfigText('{"ci": null}')).ci).toBeUndefined()
  expect(mergeConfig(user, parseConfigText('{"band": true}')).ci).toEqual({ workflow: 'user.yml' })
})

test('config: a workflow URL gives repo + workflow (+ branch only when the URL carries one)', async () => {
  const base = 'https://github.com/acme/widgets'
  const ok = (a: string, ci: unknown) => expect(ciFromAnswer(a)).toEqual({ ok: true, ci })
  ok(`${base}/actions/workflows/nightly.yml`, { workflow: 'nightly.yml', repo: 'acme/widgets' })
  ok(`  ${base}/actions/workflows/nightly.yml  `, { workflow: 'nightly.yml', repo: 'acme/widgets' })
  ok(`${base}/actions/workflows/nightly.yml?query=branch%3Arelease%2F4.8`, { workflow: 'nightly.yml', repo: 'acme/widgets', branch: 'release/4.8' })
  ok(`${base}/actions/workflows/nightly.yml?query=is%3Asuccess+branch%3Amain`, { workflow: 'nightly.yml', repo: 'acme/widgets', branch: 'main' })
  ok(`${base}/actions/workflows/nightly.yml?query=event%3Apush`, { workflow: 'nightly.yml', repo: 'acme/widgets' })
  ok(`${base}/blob/release/4.8/.github/workflows/w.yml`, { workflow: 'w.yml', repo: 'acme/widgets', branch: 'release/4.8' })
  ok(`${base}/blob/main/.github/workflows/w.yml#L3`, { workflow: 'w.yml', repo: 'acme/widgets', branch: 'main' })
  ok(`https://www.github.com/acme/widgets/actions/workflows/12345`, { workflow: '12345', repo: 'acme/widgets' })
})

test('config: a bare workflow name keeps the current repo; blank, none, no and - hide CI', async () => {
  expect(ciFromAnswer(' nightly.yml ')).toEqual({ ok: true, ci: { workflow: 'nightly.yml' } })
  for (const a of ['', '  ', 'none', 'NONE', 'No', '-', 'none (hide CI)']) expect(ciFromAnswer(a)).toEqual({ ok: true, ci: null })
})

test('config: invalid CI answers are rejected with a reason naming the value', async () => {
  for (const bad of [
    'a b.yml',
    'w.yml; ls',
    '$(id)',
    'https://evil.example/acme/widgets/actions/workflows/w.yml',
    'https://github.com/acme',
    'https://github.com/acme/widgets',
    'https://github.com/acme/widgets/actions',
    'https://github.com/acme/widgets/actions/runs/123456',
    'https://github.com/-x/widgets/actions/workflows/w.yml',
    'https://github.com/acme/widgets/actions/workflows/a%20b.yml',
    'http://',
  ]) {
    const r = ciFromAnswer(bad)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.error.length > 0).toBe(true)
  }
  const r = ciFromAnswer('w.yml; ls')
  if (!r.ok) expect(r.error).toContain('w.yml; ls')
  // an invalid branch in the query is rejected, never silently dropped
  expect(ciFromAnswer('https://github.com/acme/widgets/actions/workflows/w.yml?query=branch%3A-x').ok).toBe(false)
})

test('config: withConfig leaves ci / fillColor alone when the patch omits them', async () => {
  expect(JSON.parse(withConfig('{"ci": {"workflow": "old.yml"}, "fillColor": "blue"}', {}))).toEqual({ ci: { workflow: 'old.yml' }, fillColor: 'blue' })
  expect(JSON.parse(withConfig('{"ci": {"workflow": "old.yml"}}', { fillColor: 'green' }))).toEqual({ ci: { workflow: 'old.yml' }, fillColor: 'green' })
  expect(JSON.parse(withConfig('{"ci": {"workflow": "old.yml"}}', { ci: null }))).toEqual({ ci: null })
})

test('config: withConfig writes only ci, fillColor and version, keeps every other key, stays valid JSON (even from garbage)', async () => {
  expect(JSON.parse(withConfig('{"band": false, "fields": "ctx", "userColor": "red"}', { ci: { workflow: 'w.yml' }, fillColor: 'gray', version: true }))).toEqual({ band: false, fields: 'ctx', userColor: 'red', ci: { workflow: 'w.yml' }, fillColor: 'gray', version: true })
  expect(JSON.parse(withConfig('{"ci": {"workflow": "old.yml"}, "enabled": false}', { ci: { workflow: 'new.yml' }, fillColor: 'blue', version: true }))).toEqual({ ci: { workflow: 'new.yml' }, enabled: false, fillColor: 'blue', version: true })
  expect(JSON.parse(withConfig('{"enabled": true}', { ci: null, fillColor: 'gray', version: true }))).toEqual({ enabled: true, ci: null, fillColor: 'gray', version: true })
  expect(JSON.parse(withConfig('garbage', { ci: { workflow: 'w.yml' }, fillColor: 'gray', version: true }))).toEqual({ ci: { workflow: 'w.yml' }, fillColor: 'gray', version: true })
  expect(JSON.parse(withConfig(undefined, { ci: null, fillColor: 'gray', version: true }))).toEqual({ ci: null, fillColor: 'gray', version: true })
})

test('parseHelper: accepts the helper object, rejects garbage and its failure answer', async () => {
  expect(parseHelper(HELPER_AP)?.autopilot?.prefix).toBe('[r]')
  expect(parseHelper('{}')).toBeNull()
  expect(parseHelper('nope')).toBeNull()
  expect(parseHelper('[]')).toBeNull()
  expect(parseHelper('')).toBeNull()
  expect(parseHelper('{"branch":"main","autopilot":null}')?.autopilot).toBeNull()
  expect(parseHelper('{"branch":"m","autopilot":{"status":"running"}}')?.autopilot?.merged).toBe(0)
})

test('parseHelper: ci accepts only the four states; anything else is no ci', async () => {
  expect(parseHelper(HELPER)?.ci).toEqual({ state: 'failing', at: RUN_AT })
  const mk = (ci: unknown) => parseHelper(JSON.stringify({ ...BASE, ci }))?.ci
  expect(mk(null)).toBeNull()
  expect(mk({ state: 'exploded', at: 1 })).toBeNull()
  expect(mk({ state: '<script>', at: 1 })).toBeNull()
  expect(mk('failing')).toBeNull()
  expect(mk({ state: 'passing' })).toEqual({ state: 'passing', at: 0 })
})

test('ctxTone (context LEFT): green above 75, yellow above 50 up to 75, red at 50 or less', async () => {
  const tones = [100, 76, 75, 51, 50, 0].map(n => ctxTone(n, DEFAULTS))
  expect(tones).toEqual(['success', 'success', 'warning', 'warning', 'error', 'error'])
  // Custom thresholds keep the same strict boundaries.
  const custom = { ctxWarn: 40, ctxCrit: 15 }
  expect([41, 40, 16, 15, 0].map(n => ctxTone(n, custom))).toEqual(['success', 'warning', 'warning', 'error', 'error'])
  expect(meter(50)).toBe('▓▓▓▓▓░░░░░')
})

test('band ctx cell carries the tone at every boundary, in the wide and the narrow form', async () => {
  const want: Record<number, string> = { 100: 'success', 76: 'success', 75: 'warning', 51: 'warning', 50: 'error', 0: 'error' }
  for (const [left, color] of Object.entries(want)) {
    for (const cols of [140, 60]) {
      const cell = bandRows(snapAp({ ctxLeft: Number(left) }), NOCI, cols)[0].find(s => s.text.startsWith('ctx '))
      expect(cell?.text).toContain(`ctx ${left}%`)
      expect(cell?.color).toBe(color)
    }
  }
  // The colour follows the percentage shown: 75.4 is displayed as 75, which is yellow.
  expect(bandRows(snapAp({ ctxLeft: 75.4 }), NOCI, 140)[0].find(s => s.text.startsWith('ctx '))?.color).toBe('warning')
})

test('jobState: READY green at 0, WORKING (N) yellow from 1; narrow form drops the count', async () => {
  expect([0, 1, 5].map(n => jobState(n))).toEqual([
    { text: 'READY', color: 'success' },
    { text: 'WORKING (1)', color: 'warning' },
    { text: 'WORKING (5)', color: 'warning' },
  ])
  expect(jobState(5, false)).toEqual({ text: 'WORKING', color: 'warning' })
  expect(jobState(0, false)).toEqual({ text: 'READY', color: 'success' })
})

test('countJobs groups agent statuses', async () => {
  expect(countJobs([{ status: 'running' }, { status: 'pending' }, { status: 'idle' }, { status: 'waiting' }, { status: 'failed' }, { status: 'completed' }])).toEqual({ running: 2, waiting: 2, failed: 1 })
})

test('mode: AP ON while working, backing off, idle or paused; OFF when off, absent or no data', async () => {
  const mk = (prefix: string) => withHelper({ autopilot: { ...AP, prefix } })
  expect([isApOn(mk('[r]')), isApOn(mk('[b]')), isApOn(mk('[i]')), isApOn(mk('[p]'))]).toEqual([true, true, true, true])
  expect([isApOn(mk('[s]')), isApOn(snap()), isApOn(EMPTY)]).toEqual([false, false, false])
})

test('AP OFF row: repo @ branch | task ID + slug | jobs | you HH:MM (CI is its own top row); no AP, no ctx', async () => {
  const both = bandRows(snap(), CI, 160)
  expect(both.length).toBe(2)
  expect(text(both.slice(0, 1))).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26 \(\d+[dh] ago\)$/)
  const rows = both.slice(1)
  expect(text(rows)).toMatch(/^synxdb-build-pipeline @ t20261021-354035-decouple │ T20261021-354035 Decouple the nightly orchestrator │ WORKING \(1\) │ you \d\d:\d\d$/)
  for (const gone of ['AP', 'ctx']) expect(text(rows)).not.toContain(gone)
  // The repo cell carries the branch, so there is no separate branch cell.
  expect(text(rows).split('t20261021-354035-decouple').length).toBe(2)
})

test('AP ON row: AP elapsed/duration loops n done | ctx % | jobs | you HH:MM (CI is its own top row); no repo, branch or task', async () => {
  const both = bandRows(snapAp(), CI, 160)
  expect(both.length).toBe(2)
  expect(text(both.slice(0, 1))).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26/)
  const rows = both.slice(1)
  expect(text(rows)).toMatch(/^AP 2\/6h 3 loops ✓2 merged │ ctx 64% ▓▓▓▓▓▓░░░░ │ WORKING \(1\) │ you \d\d:\d\d$/)
  for (const gone of ['synxdb', 't20261021', 'T20261021']) expect(text(rows)).not.toContain(gone)
})

test('AP ON: paused is marked and stuck shows; a stopped autopilot gets the OFF row', async () => {
  const paused = text(bandRows(withHelper({ autopilot: { ...AP, prefix: '[p]', status: 'paused', stuck: 2 } }), NOCI, 160))
  expect(paused).toContain('AP ⏸ paused 2/6h ⚠2 3 loops')
  const stopped = text(bandRows(withHelper({ autopilot: { ...AP, prefix: '[s]', status: 'stopped' } }), NOCI, 160))
  expect(stopped).not.toContain('AP')
  expect(stopped).toContain('synxdb-build-pipeline')
})

test('with `ci` the band is never more than TWO rows, CI always the first, every row fits the terminal', async () => {
  for (const s of [snap(), snapAp()]) {
    for (const cols of [10, 20, 30, 40, 50, 60, 69, 70, 80, 99, 100, 120, 160, 300]) {
      const rows = bandRows(s, CI, cols)
      expect(rows.length).toBe(2)
      expect(rows[0].some(x => x.text.startsWith('CI'))).toBe(true)
      expect(rows[1].some(x => x.text.startsWith('CI'))).toBe(false)
      for (const r of rows) expect(r.map(x => x.text).join('').length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    }
  }
})

test('with no `ci`: always ONE row at every width, in both modes, never wider than the terminal', async () => {
  for (const s of [snap(), snapAp()]) {
    for (const cols of [10, 20, 30, 40, 50, 60, 69, 70, 80, 99, 100, 120, 160, 300]) {
      const rows = bandRows(s, NOCI, cols)
      expect(rows.length).toBe(1)
      const line = rows[0].map(x => x.text).join('')
      expect(line.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
      expect(line).not.toContain('\n')
      expect(line).not.toMatch(/│\s*│/)
    }
  }
})

test('tiers only change abbreviation: wide full labels, compact short, tiny minimal', async () => {
  expect(text(bandRows(snapAp(), CI, 140))).toContain('CI (nightly.yml) ✗ failing 10-26')
  expect(text(bandRows(snapAp(), NOCI, 140))).toContain('✓2 merged')
  const compact = text(bandRows(snapAp(), NOCI, 80))
  expect(compact).toContain('AP 2/6h 3 loops ✓2')
  expect(compact).not.toContain('merged')
  expect(compact).not.toContain('▓')
  const tiny = text(bandRows(snapAp(), NOCI, 60))
  expect(tiny).toContain('AP 2/6h 3L ✓2')
  expect(tiny).toContain('ctx 64%')
})

test('CI states: symbol, word, colour; the date shows when known', async () => {
  const cell = (state: string, at = RUN_AT) => bandRows(withHelper({ ci: { state, at } }), { ...CI, fields: ['ci'] }, 140)[0]
  const state = (st: string, at = RUN_AT) => cell(st, at).find(x => x.text.includes(st === 'unknown' ? '?' : '✓') || x.text.length > 1 && /[✓✗◐?] /.test(x.text))!
  expect([state('passing').text, state('passing').color]).toEqual(['✓ passing', 'success'])
  expect([state('failing').text, state('failing').color]).toEqual(['✗ failing', 'error'])
  expect([state('running').text, state('running').color]).toEqual(['◐ running', 'warning'])
  expect([state('unknown').text, state('unknown').color]).toEqual(['? unknown', 'inactive'])
  expect(text([cell('passing')])).toMatch(/^CI \(nightly\.yml\) ✓ passing 10-26 \(\d+[dh] ago\)$/)
  expect(text([cell('passing', 0)])).toBe('CI (nightly.yml) ✓ passing')
})

test('CI layout: configured and answered -> two rows, CI alone on top; no `ci` -> exactly one row', async () => {
  for (const s of [snap(), snapAp()]) {
    const two = bandRows(s, CI, 140)
    expect(two.length).toBe(2)
    expect(text(two.slice(0, 1))).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26/)
    expect(text(two.slice(1))).not.toContain('CI')
    expect(text(two.slice(1))).not.toContain('failing')
    expect(bandRows(s, NOCI, 140).length).toBe(1)
    expect(bandRows(s, { ...CI, fields: ['repo', 'ap', 'ctx', 'jobs'] }, 140).length).toBe(1) // switched off in fields
  }
  expect(text(bandRows(withHelper({ ci: null }, HELPER_AP), CI, 160))).toBe(text(bandRows(snapAp(), NOCI, 160))) // no answer yet: one row
  expect(bandRows(withHelper({ ci: { state: 'failing', at: RUN_AT }, ledger: null, last_input_at: 0 }), { ...CI, fields: ['ci'] }, 140).length).toBe(1) // CI alone
})

test('CI row shrinks by width: workflow, then the state word, then the age, then the date; always fits', async () => {
  const at = (cols: number) => text(bandRows(snapAp(), { ...CI, fields: ['ci'] }, cols))
  expect(at(140)).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26 \(\d+[dh] ago\)$/)
  expect(at(40)).toMatch(/^CI ✗ failing 10-26 \(\d+[dh] ago\)$/)
  expect(at(24)).toMatch(/^CI ✗ 10-26 \(\d+[dh] ago\)$/)
  expect(at(20)).toMatch(/^CI ✗ 10-26( \(\d+[dh] ago\))?$/)
  for (let cols = 10; cols <= 160; cols++) expect(at(cols).length).toBeLessThanOrEqual(Math.max(20, cols - 2))
})

test('CI colours: green passing, yellow running, grey unknown get no highlight; red (failing) flags every segment of the row', async () => {
  const row = (st: string) => bandRows(withHelper({ ci: { state: st, at: RUN_AT } }), { ...CI, fields: ['ci'] }, 140)[0]
  for (const st of ['passing', 'running', 'unknown']) expect(row(st).some(x => x.alert)).toBe(false)
  expect(row('failing').every(x => x.alert === true && x.bold === true)).toBe(true)
  expect(row('failing').some(x => x.marker && x.text === '✗ failing')).toBe(true)
  // the main row is never highlighted
  expect(bandRows(snapAp(), CI, 140)[1].some(x => x.alert)).toBe(false)
})

test('AP and queue share the second row, queue right after the AP and 24h cells, at wide and narrow widths', async () => {
  const q = { total: 44, ready: 30, blocked: 6, decision: 3, external: 2, epic: 3, claimed: 0 }
  const s = withHelper({ autopilot: { ...AP, stats: { has_history: true, merged_24h: 8, cycles_24h: 26, avg_merged_24h: 5.2, trend: 'up' } }, queue: q }, HELPER_AP)
  for (const cols of [200, 140]) {
    const rows = bandRows(s, CI, cols)
    expect(rows.length).toBe(2)
    expect(text(rows.slice(0, 1))).not.toContain('queue')
    expect(text(rows.slice(0, 1))).not.toContain('AP')
    const main = text(rows.slice(1))
    expect(main).toMatch(/^AP /)
    expect(main).toContain('queue')
    expect(main.indexOf('queue')).toBeGreaterThan(main.indexOf('24h'))
    expect(main.indexOf('queue')).toBeLessThan(main.indexOf('ctx'))
  }
  // narrow (no 24h cell): queue still right behind AP, still on the second row
  const plain = withHelper({ queue: q }, HELPER_AP)
  for (const cols of [100, 90, 80, 70]) {
    const rows = bandRows(plain, CI, cols)
    expect(rows.length).toBe(2)
    expect(text(rows.slice(0, 1))).not.toContain('queue')
    expect(text(rows.slice(1))).toMatch(/^AP [^│]*│ queue \d+/)
  }
  // AP off: queue still on the main row, never on the CI row
  const off = bandRows(withHelper({ queue: q }), CI, 140)
  expect(text(off.slice(0, 1))).not.toContain('queue')
  expect(text(off.slice(1))).toContain('queue ')
})

test('narrow drop order, AP OFF: last input first, then task slug, then task ID, then the repo cell loses its branch; repo and jobs stay longest', async () => {
  const at = (cols: number) => text(bandRows(snap(), NOCI, cols))
  const flags = (t: string): Record<string, boolean> => ({
    lastat: /you \d\d:\d\d/.test(t) || /│ \d\d:\d\d/.test(t),
    slug: t.includes('Decou'),
    branch: t.includes('t20261021-35'),
    taskId: t.includes('T20261021-354035'),
  })
  // Within each tier the tier fixes the starting abbreviation; below that fields only go, in this order.
  for (const [hi, lo] of [[200, 100], [99, 70], [69, 22]]) {
    const startFlags = flags(at(hi))
    const gone: Record<string, number> = {}
    for (let cols = hi; cols >= lo; cols--) {
      const f = flags(at(cols))
      for (const k of Object.keys(f)) if (startFlags[k] && !f[k] && gone[k] === undefined) gone[k] = cols
    }
    const order = ['lastat', 'slug', 'taskId', 'branch'].filter(k => gone[k] !== undefined)
    for (let i = 1; i < order.length; i++) expect(gone[order[i - 1]]).toBeGreaterThanOrEqual(gone[order[i]])
  }
  expect(flags(at(200)).lastat).toBe(true)
  expect(flags(at(130)).slug).toBe(true)
  expect(at(40)).toContain('WORKING')
  expect(at(40)).toContain('synxdb')
  expect(at(40)).not.toMatch(/you |\d\d:\d\d/)
})

test('narrow drop order, AP ON: last input first, ctx meter, then ctx; AP and jobs stay', async () => {
  const at = (cols: number) => text(bandRows(snapAp(), NOCI, cols))
  expect(at(100)).toContain('you ')
  const tight = at(30)
  expect(tight).toContain('AP')
  expect(tight).toContain('WORKING')
  expect(tight).not.toContain('you ')
  expect(tight).not.toContain('▓')
})

test('last input: you HH:MM today, date when older, hidden when absent', async () => {
  const f = { ...NOCI, fields: ['lastat' as const] }
  expect(text(bandRows(withHelper({ last_input_at: NOW }), f, 140))).toMatch(/^you \d\d:\d\d$/)
  expect(text(bandRows(withHelper({ last_input_at: RUN_AT }), f, 140))).toMatch(/^you Oct 26 03:00$/)
  expect(bandRows(withHelper({ last_input_at: 0 }), f, 140)).toEqual([])
  const at = new Date(2026, 9, 24, 9, 5).getTime() / 1000
  expect(formatStamp(at, new Date(2026, 9, 24, 23, 0).getTime())).toBe('09:05')
  expect(formatStamp(at, new Date(2026, 9, 25, 8, 0).getTime())).toBe('Oct 24 09:05')
})

test('band: empty when there is no data; the stale tag shows when the helper failed', async () => {
  expect(bandRows(EMPTY, DEFAULTS, 140)).toEqual([])
  expect(text(bandRows({ ...EMPTY, stale: true }, DEFAULTS, 140))).toBe('stale')
  expect(text(bandRows(snap({ stale: true }), NOCI, 160))).toContain('stale')
})

test('band: an unclaimed task or empty branch leaves no cell at all', async () => {
  const t = text(bandRows(withHelper({ task_id: '', task_title: '', branch: '' }), NOCI, 160))
  expect(t).toMatch(/^synxdb-build-pipeline │ WORKING \(1\) │ you /)
  expect(t).not.toContain('no claimed')
})

test('tier boundaries: tiny below 70, compact below 100, wide from 100', async () => {
  expect([tierOf(40), tierOf(69), tierOf(70), tierOf(99), tierOf(100), tierOf(200)]).toEqual(['tiny', 'tiny', 'compact', 'compact', 'wide', 'wide'])
})

test('truncateWords: whole words only, with an ellipsis; a single long word is hard-cut', async () => {
  expect(truncateWords('Silent drift in the nightly orchestrator', 28)).toBe('Silent drift in the nightly…')
  expect(truncateWords('short', 28)).toBe('short')
  expect(truncateWords('x'.repeat(40), 10)).toBe('xxxxxxxxx…')
  expect(truncateWords('anything', 0)).toBe('')
})

test('compactLine is one plain line within the 2,000 character limit', async () => {
  const line = compactLine(snap(), CI)
  expect(line).not.toContain('\n')
  expect(line.length).toBeLessThanOrEqual(2000)
  expect(line).toContain('synxdb-build-pipeline')
})

// --- repo cell: follows the session cwd (owner/name @ branch* (wt X) (account), arrow, root marker) ---

const repoCell = (h: object, extra = {}, cols = 200) => text(bandRows({ ...withHelper(h), ...extra }, { ...NOCI, fields: ['repo'] }, cols))

test('parseHelper: repo identity fields; main\'s `repo` string is untouched, missing fields are null', async () => {
  const h = parseHelper(JSON.stringify({ ...BASE, repo_slug: 'acme/widgets', repo_root: '/w/widgets', head: 'abc1234', dirty: 3, gh_account: 'work-user' }))!
  expect([h.repo, h.repo_slug, h.repo_root, h.head, h.dirty, h.gh_account, h.cwd]).toEqual(['synxdb-build-pipeline', 'acme/widgets', '/w/widgets', 'abc1234', 3, 'work-user', '/work/synxdb-build-pipeline'])
  const old = parseHelper('{"repo":"x","branch":"main"}')!
  expect([old.repo, old.repo_slug, old.repo_root, old.head, old.dirty, old.gh_account, old.cwd]).toEqual(['x', null, null, '', null, null, ''])
  expect(parseHelper(JSON.stringify({ ...BASE, dirty: 'many', gh_account: '', repo_slug: '' }))).toMatchObject({ dirty: null, gh_account: null, repo_slug: null })
})

test('repo cell: owner/name @ branch; the slug wins over the plain name, which is the fallback', async () => {
  expect(repoCell({ repo_slug: 'acme/widgets', branch: 'main' })).toBe('acme/widgets @ main')
  expect(repoCell({ repo_slug: null, repo: 'widgets', branch: 'main' })).toBe('widgets @ main')
})

test('repo cell: * marks a dirty tree (1 and 99 alike), a clean or unknown tree has none', async () => {
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', dirty: 1 })).toBe('a/b @ main*')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', dirty: 99 })).toBe('a/b @ main*')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', dirty: 0 })).toBe('a/b @ main')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', dirty: null })).toBe('a/b @ main')
  const star = bandRows(withHelper({ repo_slug: 'a/b', branch: 'main', dirty: 2 }), { ...NOCI, fields: ['repo'] }, 200)[0].find(s => s.text === '*')
  expect(star?.color).toBe('warning')
})

test('repo cell: detached HEAD, linked worktree and the gh account', async () => {
  expect(repoCell({ repo_slug: 'a/b', branch: '', head: 'abc1234' })).toBe('a/b @ detached abc1234')
  expect(repoCell({ repo_slug: 'a/b', branch: 'wt2', worktree: 'wt2-dir' })).toBe('a/b @ wt2 (wt wt2-dir)')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', gh_account: 'work-user' })).toBe('a/b @ main (work-user)')
  expect(repoCell({ repo_slug: 'a/b', branch: 'wt2', worktree: 'wt2-dir', dirty: 4, gh_account: 'work-user' })).toBe('a/b @ wt2* (wt wt2-dir) (work-user)')
  expect(repoCell({ repo_slug: 'a/b', branch: '', head: '' })).toBe('a/b')
})

test('repo cell: outside a git repo it is just the folder name, no branch, no marks', async () => {
  expect(repoCell({ repo: 'Downloads', repo_slug: null, repo_root: null, branch: '', dirty: null, gh_account: null, cwd: '/Users/u/Downloads' })).toBe('Downloads')
})

test('repo cell: the arrow shows while the repo just changed, and only then', async () => {
  const h = { repo_slug: 'a/b', branch: 'main' }
  expect(repoCell(h, { moved: true })).toBe('→ a/b @ main')
  expect(repoCell(h, { moved: false })).toBe('a/b @ main')
  const arrow = bandRows({ ...withHelper(h), moved: true }, { ...NOCI, fields: ['repo'] }, 200)[0][0]
  expect([arrow.text, arrow.bold]).toEqual(['→ ', true])
})

test('repo cell: (root: X) only when the cwd is outside the session root', async () => {
  const h = { repo_slug: 'a/b', branch: 'main', cwd: '/other/b' }
  expect(repoCell(h, { sessionRoot: '/proj/launch' })).toBe('a/b @ main (root: launch)')
  expect(repoCell({ ...h, cwd: '/proj/launch' }, { sessionRoot: '/proj/launch' })).toBe('a/b @ main')
  expect(repoCell({ ...h, cwd: '/proj/launch/sub/dir' }, { sessionRoot: '/proj/launch/' })).toBe('a/b @ main')
  expect(repoCell({ ...h, cwd: '/proj/launch-two' }, { sessionRoot: '/proj/launch' })).toBe('a/b @ main (root: launch)') // not a path-prefix match
  expect(repoCell(h, { sessionRoot: null })).toBe('a/b @ main')
  expect(repoCell({ ...h, cwd: '' }, { sessionRoot: '/proj/launch' })).toBe('a/b @ main')
  const root = bandRows({ ...withHelper(h), sessionRoot: '/proj/launch' }, { ...NOCI, fields: ['repo'] }, 200)[0].find(s => s.text.includes('root:'))
  expect(root?.color).toBe('warning')
  expect([baseName('/a/b/'), baseName(''), isWithin('/a/b', '/a/b'), isWithin('/a/bc', '/a/b')]).toEqual(['b', '', true, false])
})

test('repo cell shrinks by width: worktree, then account, then names; the marker survives longest and the row never overflows', async () => {
  const full = { repo_slug: 'synx-data-labs/ccxp-skills', branch: 'feat/a-rather-long-branch-name', dirty: 2, worktree: 'wt-one', gh_account: 'shine-work', cwd: '/other/ccxp-skills' }
  const at = (cols: number) => text(bandRows({ ...withHelper(full), moved: true, sessionRoot: '/proj/launch' }, { ...NOCI, fields: ['repo'] }, cols))
  expect(at(200)).toBe('→ synx-data-labs/ccxp-skills @ feat/a-rather-long-branch-name* (wt wt-one) (shine-work) (root: launch)')
  const seen: string[] = []
  for (let cols = 200; cols >= 22; cols--) {
    const t = at(cols)
    expect(t.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    seen.push(t)
  }
  expect(seen.some(t => !t.includes('(wt ') && t.includes('(shine-work)'))).toBe(true) // worktree goes first
  expect(seen.some(t => !t.includes('(shine-work)') && t.includes('synx-data-labs/ccxp-skills'))).toBe(true)
  expect(seen.some(t => t.includes('ccxp-skills @') && !t.includes('synx-data-labs'))).toBe(true) // then the owner
  expect(seen[seen.length - 1]).toContain('ccxp-skills')
})

test('repo cell with the other cells: a narrow row keeps repo and jobs, and the repo cell also fits the compact line', async () => {
  const s = withHelper({ repo_slug: 'acme/widgets', branch: 'main', dirty: 1 })
  expect(text(bandRows(s, NOCI, 160))).toMatch(/^acme\/widgets @ main\* │ T20261021-354035 Decouple the nightly orchestrator │ WORKING \(1\) │ you \d\d:\d\d$/)
  expect(compactLine(s, CI)).toContain('acme/widgets @ main*')
  expect(text(bandRows(s, NOCI, 45))).toMatch(/^widgets\*/)
  expect(text(bandRows(s, NOCI, 45))).toContain('WORKING')
})

test('branch cell: shown on its own when `repo` is not a field; the repo cell otherwise says it once', async () => {
  expect(text(bandRows(snap(), { ...NOCI, fields: ['branch'] }, 200))).toBe(' t20261021-354035-decouple')
  expect(text(bandRows(snap(), { ...NOCI, fields: ['repo', 'branch'] }, 200))).toBe('synxdb-build-pipeline @ t20261021-354035-decouple')
})

// --- jobs cell: green READY when no job runs, yellow WORKING (N) otherwise; hidden without a ledger ---

const ledgerOf = (n: number) => ({ ledger: { running: Array.from({ length: n }, (_, i) => ({ job: 230 + i, title: `job ${i}` })), lifetime_jobs: 230 + n, parked: [], next_job: 231 + n, updated_at: '' } })
const jobsCell = (n: number, base = HELPER, cols = 200) => bandRows(withHelper(ledgerOf(n), base), { ...NOCI, fields: ['jobs'] }, cols)[0]

test('jobs cell: READY green at 0, WORKING (N) yellow at 1 and 5', async () => {
  expect(jobsCell(0).map(s => [s.text, s.color])).toEqual([['READY', 'success']])
  expect(jobsCell(1).map(s => [s.text, s.color])).toEqual([['WORKING (1)', 'warning']])
  expect(jobsCell(5).map(s => [s.text, s.color])).toEqual([['WORKING (5)', 'warning']])
})

test('jobs cell: no ledger means no cell at all (no READY without a source)', async () => {
  expect(bandRows(withHelper({ ledger: null }), { ...NOCI, fields: ['jobs'] }, 200)).toEqual([])
  expect(text(bandRows(withHelper({ ledger: null }), NOCI, 160))).not.toMatch(/READY|WORKING/)
  expect(text(bandRows(withHelper({ ledger: null }, HELPER_AP), NOCI, 160))).not.toMatch(/READY|WORKING/)
})

test('jobs cell sits before the last-input cell in both orderings; `fields` can switch it off', async () => {
  const idle = { ...ledgerOf(0) }
  expect(text(bandRows(withHelper(idle), NOCI, 160))).toMatch(/ │ READY │ you /)
  expect(text(bandRows(withHelper(idle, HELPER_AP), NOCI, 160))).toMatch(/ctx 64% ▓▓▓▓▓▓░░░░ │ READY │ you /)
  expect(text(bandRows(withHelper(idle), { ...NOCI, fields: ['repo', 'ci'] }, 160))).not.toContain('READY')
})

test('jobs cell narrow: the count goes before the word, READY keeps its word; the row stays one line', async () => {
  const work = withHelper(ledgerOf(3), HELPER_AP)
  const idle = withHelper(ledgerOf(0), HELPER_AP)
  expect(text(bandRows(work, NOCI, 140))).toContain('WORKING (3)')
  let seenBare = false
  for (let cols = 140; cols >= 22; cols--) {
    const t = text(bandRows(work, NOCI, cols))
    if (t.includes('WORKING') && !t.includes('WORKING (3)')) seenBare = true
    expect(t.includes('WORKING (3)') && seenBare).toBe(false) // never back to the count once dropped
    expect(bandRows(work, NOCI, cols).length).toBe(1)
  }
  expect(seenBare).toBe(true)
  expect(text(bandRows(idle, NOCI, 60))).toContain('READY')
  expect(text(bandRows(withHelper(ledgerOf(2)), NOCI, 60))).toMatch(/WORKING/)
})

// --- /hud details: the band expanded to five live lines ---

const DETAIL_NOW = Math.floor(Date.now() / 1000) * 1000 // whole seconds, so 'in 12m' is exact
const detail = (s: object, cols = 140, cfg: typeof CI | typeof NOCI = NOCI) => detailRows(s as any, cfg, cols, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
const fullSnap = (over = {}) => ({
  ...withHelper({
    repo_slug: 'acme/widgets',
    dirty: 2,
    autopilot: { ...AP, next_wake_at: Math.floor(DETAIL_NOW / 1000) + 720 },
    ledger: { running: [{ job: 70, title: 'Redo HUD repo field' }, { job: 73, title: 'Autopilot cycle 2' }], lifetime_jobs: 82, parked: [{ id: 'k1' }, { id: 'k2' }], next_job: 83, updated_at: '' },
    ci: { state: 'passing', at: Math.floor(DETAIL_NOW / 1000) - 7200 },
    last_input_at: Math.floor(DETAIL_NOW / 1000) - 300,
  }),
  ...over,
})

test('formatAge: just now, minutes, hours, days; a future stamp is just now', async () => {
  const at = 1_000_000
  const age = (secs: number) => formatAge(at, (at + secs) * 1000)
  expect([age(0), age(59), age(60), age(3599), age(3600), age(86399), age(86400), age(259200)]).toEqual(['just now', 'just now', '1m ago', '59m ago', '1h ago', '23h ago', '1d ago', '3d ago'])
  expect(formatAge(at, (at - 50) * 1000)).toBe('just now')
})

test('AP ON (no duration): elapsed shows without a requested window; idle names its state', async () => {
  const on = text(bandRows(withHelper({ autopilot: { ...AP, status: 'on', requested_hr: 0 } }), NOCI, 160))
  expect(on).toContain('AP 2h 3 loops ✓2 merged')
  expect(on).not.toContain('/0h')
  const idle = text(bandRows(withHelper({ autopilot: { ...AP, status: 'on', prefix: '[i]', last_outcome: 'idle', requested_hr: 0 } }), NOCI, 160))
  expect(idle).toContain('AP idle 2h')
  const paused = text(bandRows(withHelper({ autopilot: { ...AP, status: 'paused', prefix: '[p]', requested_hr: 0 } }), NOCI, 160))
  expect(paused).toContain('AP ⏸ paused 2h')
})

test('details: five lines in order: where, usage, jobs, autopilot, last prompt (no `ci`: no CI line)', async () => {
  const lines = detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }))
  expect(lines.length).toBe(5)
  expect(lines[0]).toBe('acme/widgets @ t20261021-354035-decouple* │ T20261021-354035 Decouple the nightly orchestrator')
  expect(lines[1]).toBe('context 64% left ▓▓▓▓▓▓░░░░ │ 5-hour limit 42% used │ API-equivalent cost $1.50')
  expect(lines[2]).toBe('WORKING (2) │ parked 2 │ total jobs 82')
  expect(lines[3]).toMatch(/^AP on 2\/6h 3 loops ✓2 merged │ next loop (?:[A-Z][a-z]{2} \d+ )?\d\d:\d\d \(in 12m\)$/)
  expect(lines[4]).toMatch(/^you \d\d:\d\d \(5m ago\)$/)
})

test('details: colours match the band (ctx tone, READY/WORKING) and the dirty mark is yellow', async () => {
  const rows = detailRows(fullSnap({ ctxLeft: 40 }) as any, NOCI, 140, DETAIL_NOW)
  expect(rows[1].find(s => s.text.startsWith('context '))?.color).toBe('error')
  expect(rows[2][0]).toEqual({ text: 'WORKING (2)', color: 'warning' })
  expect(rows[0].find(s => s.text === '*')?.color).toBe('warning')
  const idle = detailRows(withHelper({ ledger: { running: [], lifetime_jobs: 82, parked: [], next_job: 83, updated_at: '' } }) as any, NOCI, 140, DETAIL_NOW)
  expect(idle[2][0]).toEqual({ text: 'READY', color: 'success' })
})

test('details: lines with nothing to say are left out (no ledger, no CI config, no prompt time, no ctx)', async () => {
  const lines = detail({ ...withHelper({ ledger: null, last_input_at: 0 }), ctxLeft: null }, 140, DEFAULTS)
  expect(lines.length).toBe(2) // where, autopilot (off)
  expect(lines[1]).toBe('AP off')
  expect(lines.join('\n')).not.toMatch(/READY|WORKING|you |CI/)
})

test('details: parked shows the count only, never the parked ids', async () => {
  const ids = ['k5', 'k6', 'k7', 'k8', 'k9', 'k10', 'k11', 'k12', 'k13']
  const ledger = { running: [], lifetime_jobs: 82, parked: ids.map(id => ({ id })), next_job: 83, updated_at: '' }
  const lines = detail(withHelper({ ledger }) as any, 140)
  expect(lines[2]).toBe('READY │ parked 9 │ total jobs 82')
  expect(lines.join('\n')).not.toMatch(/k\d/)
})

test('details: every line fits the terminal at every width and the band row is untouched', async () => {
  for (let cols = 140; cols >= 22; cols--) {
    for (const s of [fullSnap(), fullSnap({ stale: true, rateUsed: 99, costUsd: 123.45 })]) {
      for (const line of detail(s, cols)) expect(line.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    }
  }
  expect(bandRows(fullSnap() as any, NOCI, 140).length).toBe(1)
})

test('details: a narrow terminal shortens the labels and ages before it cuts', async () => {
  const wide = detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }), 140)
  const narrow = detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }), 70)
  expect(narrow[1].length).toBeLessThan(wide[1].length)
  expect(detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }), 56)[1]).toBe('context 64% left │ 5h limit 42% │ cost $1.50')
  expect(detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }), 40)[1]).toBe('ctx 64% │ 5h limit 42% │ cost $1.50')
  expect(detail(fullSnap(), 30)[2]).toBe('WORKING (2) │ parked 2')
  const old = Math.floor(DETAIL_NOW / 1000) - 3 * 86400
  expect(detail(fullSnap({ helper: { ...fullSnap().helper, last_input_at: old } }), 140)[4]).toMatch(/^you \w{3} \d+ \d\d:\d\d \(3d ago\)$/)
  expect(detail(fullSnap({ helper: { ...fullSnap().helper, last_input_at: old } }), 22)[4]).toMatch(/^you \w{3} \d+ \d\d:\d\d$/)
})

test('details: the jobs line never lists the running jobs (the band already shows them); labels are spelled out', async () => {
  const lines = detail(fullSnap({ rateUsed: 4, costUsd: 693.75, ctxLeft: 88 }))
  expect(lines[1]).toBe('context 88% left ▓▓▓▓▓▓▓▓▓░ │ 5-hour limit 4% used │ API-equivalent cost $693.75')
  const all = lines.join('\n')
  expect(all).not.toMatch(/r70|r73|Redo HUD|Autopilot cycle|\btot\b|\bctx\b/)
  expect(lines[2]).toBe('WORKING (2) │ parked 2 │ total jobs 82')
  // ...but the one-row band keeps its short forms
  expect(text(bandRows(fullSnap({ rateUsed: 4, costUsd: 693.75 }) as any, { ...NOCI, fields: [...CI.fields, 'rate', 'cost'] }, 200))).toContain('ctx 64% ▓▓▓▓▓▓░░░░ │ WORKING (2)')
})

test('formatIn: under a minute, minutes, hours with minutes, days; due or past is now', async () => {
  const at = 1_000_000
  const inn = (secs: number) => formatIn(at, (at - secs) * 1000)
  expect([inn(30), inn(60), inn(720), inn(3599), inn(3600), inn(3900), inn(86400 * 2)]).toEqual(['in <1m', 'in 1m', 'in 12m', 'in 59m', 'in 1h', 'in 1h 5m', 'in 2d'])
  expect([inn(0), inn(-5)]).toEqual(['now', 'now'])
})

test('details: AP line shows the next loop (clock and wait), independent of the time of day', async () => {
  // Local-time construction: the same clock reading in every timezone, never "yesterday".
  const now = new Date(2026, 9, 28, 12, 0, 0).getTime()
  const wake = Math.floor(now / 1000) + 12 * 60
  const apLine = (over: object, cols = 140) => detailRows(withHelper({ autopilot: { ...AP, ...over }, ci: null }) as any, DEFAULTS, cols, now).map(r => r.map(x => x.text).join('')).find(l => l.startsWith('AP'))!
  expect(apLine({ next_wake_at: wake })).toBe('AP on 2/6h 3 loops ✓2 merged │ next loop 12:12 (in 12m)')
  expect(apLine({ next_wake_at: wake })).toContain('next loop 12:12')
  // a different day carries the date, like the last-prompt stamp
  expect(apLine({ next_wake_at: wake + 86400 })).toMatch(/next loop \w{3} 29 12:12 \(in 1d\)$/)
  expect(apLine({ next_wake_at: Math.floor(now / 1000) - 5 })).toMatch(/next loop due$/)
  expect(apLine({ next_wake_at: 0 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apLine({ next_wake_at: wake, status: 'paused', prefix: '[p]' })).toBe('AP ⏸ paused 2/6h 3 loops ✓2 merged │ next loop paused')
  expect(apLine({ next_wake_at: wake })).not.toContain('next loop paused')
  // a running cycle names its ledger job (flag autopilot, highest number); no flagged row: plain `running`
  const led = (rows: object[]) => ({ ledger: { running: rows, lifetime_jobs: 600, parked: [], next_job: 700, updated_at: '' } })
  const apWith = (rows: object[], over: object) => detailRows(withHelper({ autopilot: { ...AP, ...over }, ci: null, ...led(rows) }) as any, DEFAULTS, 140, now).map(r => r.map(x => x.text).join('')).find(l => l.startsWith('AP'))!
  const busy = { next_wake_at: wake, busy: true, current_task: 'T20261028-151063' }
  const rows = [{ job: 590, title: 'other', flags: '' }, { job: 596, title: 'autopilot cycle', flags: 'autopilot' }, { job: 599, title: 'x', flags: 'detached' }]
  expect(apWith(rows, busy)).toBe('AP on 2/6h 3 loops ✓2 merged │ running r596')
  expect(apWith([...rows, { job: 598, title: 'older', flags: 'detached,autopilot' }], busy)).toMatch(/running r598$/)
  expect(apWith(rows, { ...busy, next_wake_at: Math.floor(now / 1000) - 5 })).toMatch(/running r596$/)
  expect(apWith(rows, { ...busy, current_task: '' })).toMatch(/running r596$/)
  expect(apWith([{ job: 599, title: 'x', flags: 'detached' }], busy)).toBe('AP on 2/6h 3 loops ✓2 merged │ running')
  expect(apWith([], busy)).toMatch(/│ running$/)
  expect(apWith(rows, { next_wake_at: wake })).toBe('AP on 2/6h 3 loops ✓2 merged │ next loop 12:12 (in 12m)')
  expect(apWith(rows, { next_wake_at: Math.floor(now / 1000) - 5 })).toMatch(/next loop due$/)
  // paused still wins over a busy mark
  expect(apLine({ next_wake_at: wake, busy: true, current_task: 'T20261028-151063', status: 'paused', prefix: '[p]' })).toMatch(/next loop paused$/)
  // AP off or no record: no schedule
  expect(detailRows(withHelper({ autopilot: null }) as any, DEFAULTS, 140, now).map(r => r.map(x => x.text).join('')).join('\n')).not.toContain('next')
  // narrow: the clock goes first, the wait stays, then the cell
  expect(apLine({ next_wake_at: wake }, 52)).toBe('AP on 2/6h 3 loops ✓2 merged │ next loop in 12m')
})

test('parseHelper: autopilot busy is a boolean and current_task a string, false and empty when missing', async () => {
  const ap = (o: object) => parseHelper(JSON.stringify({ ...JSON.parse(HELPER), autopilot: { status: 'on', prefix: '[r]', ...o } }))!.autopilot!
  expect([ap({ busy: true, current_task: 'T20261028-151063' }).busy, ap({ busy: true, current_task: 'T20261028-151063' }).current_task]).toEqual([true, 'T20261028-151063'])
  expect([ap({}).busy, ap({}).current_task, ap({ busy: 'yes' }).busy]).toEqual([false, '', false])
})

test('parseHelper: autopilot next_wake_at is a number, 0 when missing or not a number', async () => {
  const ap = (v: unknown) => parseHelper(JSON.stringify({ ...JSON.parse(HELPER), autopilot: { status: 'on', prefix: '[r]', next_wake_at: v } }))!.autopilot!.next_wake_at
  expect([ap(1790000000), ap('x'), ap(undefined)]).toEqual([1790000000, 0, 0])
})

test('details: an empty snapshot has no lines; a stale helper keeps its tag', async () => {
  expect(detailRows(EMPTY, DEFAULTS, 140, DETAIL_NOW)).toEqual([])
  expect(detail({ ...EMPTY, stale: true }, 140, DEFAULTS)).toEqual(['stale'])
})

const fillWidth = (segs: { text: string }[]) => segs.reduce((n, s) => n + displayWidth(s.text), 0)

test('fill: always on; fillColor defaults to gray, parses names and #rrggbb only, and an old fill key is ignored', async () => {
  expect(DEFAULTS.fillColor).toBe('gray')
  expect('fill' in DEFAULTS).toBe(false)
  expect(mergeConfig(parseConfigText('{"fillColor": "Blue"}'), {}).fillColor).toBe('blue')
  expect(mergeConfig(parseConfigText('{"fillColor": "#ABCDEF"}'), {}).fillColor).toBe('#abcdef')
  expect(mergeConfig(parseConfigText('{"fillColor": "constructor"}'), {}).fillColor).toBe('gray')
  for (const bad of ['{"fillColor": "chartreuse"}', '{"fillColor": 5}', '{"fillColor": "#abc"}', '{"fillColor": ""}']) expect(mergeConfig(parseConfigText(bad), {}).fillColor).toBe('gray')
  expect(mergeConfig(parseConfigText('{"fillColor": "green"}'), parseConfigText('{"fillColor": "purple"}')).fillColor).toBe('purple')
  expect(mergeConfig(parseConfigText('{"fill": false}'), {})).toEqual(DEFAULTS)
  expect(parseConfigText('{"fill": false}')).toEqual({})
})

test('fill: displayWidth counts ASCII 1, CJK and emoji 2, marks and joiners 0', async () => {
  expect(displayWidth('abc')).toBe(3)
  expect(displayWidth('')).toBe(0)
  expect(displayWidth('你好')).toBe(4)
  expect(displayWidth('ab你')).toBe(4)
  expect(displayWidth('🚀')).toBe(2)
  expect(displayWidth('⚠\ufe0f')).toBe(2)
  expect(displayWidth('✓ ok')).toBe(4)
  expect(displayWidth('e\u0301')).toBe(1)
  expect(displayWidth('a\u200db')).toBe(2)
  expect(charWidth(0x41)).toBe(1)
})

test('fill: ANSI codes are stripped before measuring', async () => {
  const colored = '\u001b[31mred\u001b[0m \u001b[1;38;5;196m你\u001b[0m'
  expect(stripAnsi(colored)).toBe('red 你')
  expect(displayWidth(colored)).toBe(6)
})

test('fill: truncateDisplay cuts to the width with an ellipsis and never splits a wide character', async () => {
  expect(truncateDisplay('hello', 10)).toBe('hello')
  expect(truncateDisplay('hello world', 6)).toBe('hello…')
  expect(truncateDisplay('你好世界', 5)).toBe('你好…')
  expect(displayWidth(truncateDisplay('你好世界', 4))).toBeLessThanOrEqual(4)
  expect(truncateDisplay('abc', 0)).toBe('')
})

test('fill: fillRow pads every row to exactly the width, ASCII, emoji and CJK alike', async () => {
  for (const text of ['hi', 'repo @ main 🚀', '任务 标题', '']) {
    const row = fillRow([{ text, color: 'success' }], 60)!
    expect(fillWidth(row)).toBe(60)
    expect(row[0].text).toBe(' ')
  }
})

test('fill: overflow is cut with an ellipsis before padding and never exceeds the width', async () => {
  const long = [{ text: 'owner/some-very-long-repo-name @ ', bold: true }, { text: 'a-very-long-branch-name-here-' }, { text: '任务标题'.repeat(10), color: 'error' }]
  for (const w of [40, 45, 61]) {
    const row = fillRow(long, w)!
    expect(fillWidth(row)).toBe(w)
    expect(row.map(s => s.text).join('')).toContain('…')
  }
  expect(fitSegs([{ text: 'abcdef' }], 4)).toEqual([{ text: 'abc…' }])
  const fits = [{ text: 'ok' }]
  expect(fitSegs(fits, 10)).toBe(fits)
  // A segment exactly one column over the room must still be cut (no max+1 row).
  const edge = fitSegs([{ text: 'ab' }, { text: 'cde' }, { text: 'x' }], 5)
  expect(fillWidth(edge)).toBeLessThanOrEqual(5)
  expect(edge.map(s => s.text).join('')).toBe('abcd…')
  for (let max = 1; max < 12; max++) expect(fillWidth(fitSegs([{ text: '任务a' }, { text: '标题🚀b' }, { text: 'xyz' }], max))).toBeLessThanOrEqual(max)
  expect(truncateDisplay('你好世界', 4)).toBe('你…')
  for (let max = 1; max < 12; max++) {
    expect(fillWidth(fitSegs([{ text: '⚠\ufe0f'.repeat(4) }], max))).toBeLessThanOrEqual(max)
    expect(displayWidth(truncateDisplay('⚠\ufe0fab⚠\ufe0f'.repeat(3), max))).toBeLessThanOrEqual(max)
  }
})

test('fill: unknown width or below the minimum falls back (null), never wraps', async () => {
  for (const bad of [undefined, null, NaN, Infinity, 0, -5, 39]) expect(fillRow([{ text: 'x' }], bad as any)).toBeNull()
  expect(fillRow([{ text: 'x' }], 40)).not.toBeNull()
  expect(fillRow([{ text: 'x' }], 20, 10)).not.toBeNull()
})

test('fill: a real band row fills to the width and keeps its colours', async () => {
  const [row] = bandRows(snap(), CI, 100)
  const filled = fillRow(row, 100)!
  expect(fillWidth(filled)).toBe(100)
  expect(filled.some(s => s.color === 'error')).toBe(true)
})

test('fill: style follows the theme; unknown theme means reverse video', async () => {
  expect(fillStyleFor('dark')).toEqual({ bg: FILL_BG.dark })
  expect(fillStyleFor('dark-ansi')).toEqual({ bg: FILL_BG.dark })
  expect(fillStyleFor('light-daltonized')).toEqual({ bg: FILL_BG.light })
  for (const t of ['auto', '', undefined, 5, null]) expect(fillStyleFor(t)).toEqual({ inverse: true })
})

test('fill: colour choice picks the palette; unset or invalid means gray; custom hex ignores the theme', async () => {
  expect(fillStyleFor('dark', undefined)).toEqual({ bg: FILL_COLORS.gray.dark })
  expect(fillStyleFor('dark', 'bogus')).toEqual({ bg: FILL_COLORS.gray.dark })
  for (const name of Object.keys(FILL_COLORS) as Array<keyof typeof FILL_COLORS>) {
    expect(fillStyleFor('dark', name)).toEqual({ bg: FILL_COLORS[name].dark })
    expect(fillStyleFor('light', name)).toEqual({ bg: FILL_COLORS[name].light })
    expect(fillStyleFor('auto', name)).toEqual({ inverse: true })
  }
  expect(fillStyleFor('auto', '#112233')).toEqual({ bg: '#112233' })
  expect(fillStyleFor('light', '#112233')).toEqual({ bg: '#112233' })
})

const PLUGIN_NEW = { installed: '5.0.0', latest: '5.1.0' }
const verSnap = (plugin: object | null, over = {}) => ({ ...withHelper({ plugin }), ...over })

test('version: config defaults to on, `version: false` turns it off, other types are ignored', async () => {
  expect(DEFAULTS.version).toBe(true)
  expect(mergeConfig(parseConfigText('{"version": false}'), {}).version).toBe(false)
  expect(mergeConfig(parseConfigText('{"version": "no"}'), {}).version).toBe(true)
  expect(mergeConfig(parseConfigText('{"version": false}'), parseConfigText('{"version": true}')).version).toBe(true)
})

test('version: isNewer is numeric semver, strict, and rejects junk', async () => {
  expect(isNewer('5.10.0', '5.9.0')).toBe(true)
  expect(isNewer('10.0.0', '9.9.9')).toBe(true)
  expect(isNewer('5.0.0', '5.0.0')).toBe(false)
  expect(isNewer('5.9.0', '5.10.0')).toBe(false)
  expect(isNewer('5.0.0', '5.0.0-rc.1')).toBe(true)
  expect(isNewer('5.0.0-rc.1', '5.0.0')).toBe(false)
  expect(isNewer('x', '5.0.0')).toBe(false)
  expect(isNewer('5.0.0', '')).toBe(false)
})

test('version: parseHelper keeps only valid versions (latest is kept whatever its relation to installed)', async () => {
  const h = (plugin: unknown) => parseHelper(JSON.stringify({ ...BASE, plugin }))?.plugin
  expect(h(PLUGIN_NEW)).toEqual(PLUGIN_NEW)
  expect(h({ installed: '5.0.0', latest: null })).toEqual({ installed: '5.0.0', latest: null })
  expect(h({ installed: '5.1.0', latest: '5.0.0' })).toEqual({ installed: '5.1.0', latest: '5.0.0' })
  expect(h({ installed: '5.0.0', latest: '5.0.0' })).toEqual({ installed: '5.0.0', latest: '5.0.0' })
  expect(h({ installed: '5.0.0', latest: '9.0.0; ls' })).toEqual({ installed: '5.0.0', latest: null })
  expect(h({ installed: 'junk', latest: '9.0.0' })).toBeNull()
  expect(h(null)).toBeNull()
  expect(h('5.0.0')).toBeNull()
  expect(parseHelper(HELPER)?.plugin).toBeNull()
})

test('version: the band shows `ccxp X (latest)`, `ccxp X (Y available)`, or `ccxp X` when latest is unknown, last in the row', async () => {
  const cfg = { ...DEFAULTS }
  const plain = text(bandRows(verSnap({ installed: '5.0.0', latest: null }), cfg, 160))
  expect(plain.endsWith('ccxp 5.0.0')).toBe(true)
  expect(plain).not.toContain('latest')
  const rows = bandRows(verSnap(PLUGIN_NEW), cfg, 160)
  expect(text(rows).endsWith('ccxp 5.0.0 (5.1.0 available)')).toBe(true)
  // The new number stands out (colour), the rest is dim.
  const seg = rows[0].find(s => s.text === '5.1.0')
  expect(seg?.color).toBe('suggestion')
  expect(rows[0].find(s => s.text.startsWith('ccxp 5.0.0'))?.dim).toBe(true)
  // Same version as the latest release: `(latest)` in the success colour.
  const cur = bandRows(verSnap({ installed: '5.1.0', latest: '5.1.0' }), cfg, 160)
  expect(text(cur).endsWith('ccxp 5.1.0 (latest)')).toBe(true)
  expect(cur[0].find(s => s.text === '(latest)')?.color).toBe('success')
  // Installed newer than latest (dev/prerelease): plain, never "latest".
  for (const p of [{ installed: '5.2.0', latest: '5.1.0' }, { installed: '5.1.0-rc.1', latest: '5.0.0' }]) {
    const t = text(bandRows(verSnap(p), cfg, 160))
    expect(t.endsWith(`ccxp ${p.installed}`)).toBe(true)
    expect(t).not.toContain('latest')
  }
})

test('version: versionState classifies latest / available / unknown', async () => {
  expect(versionState({ installed: '5.1.1', latest: '5.1.1' })).toBe('latest')
  expect(versionState({ installed: '5.1.1', latest: '5.2.0' })).toBe('available')
  expect(versionState({ installed: '5.1.1-rc.1', latest: '5.1.1' })).toBe('available')
  expect(versionState({ installed: '5.1.1', latest: null })).toBe('unknown')
  expect(versionState({ installed: '5.2.0', latest: '5.1.1' })).toBe('unknown')
})

test('version: narrow forms are `ccxp X ✓` for latest and `ccxp ↑Y`, `↑Y` for an update', async () => {
  const cur = { installed: '5.1.0', latest: '5.1.0' }
  const widths = (p: object) => {
    const out = new Set<string>()
    for (let c = 20; c <= 140; c++) {
      const t = text(bandRows(verSnap(p), { ...DEFAULTS, fields: ['jobs'] }, c))
      const m = t.match(/(ccxp [^ ]+ \(latest\)|ccxp 5\.1\.0 ✓|ccxp 5\.1\.0 \(5\.2\.0 available\)|ccxp ↑5\.2\.0|↑5\.2\.0)$/)
      if (m) out.add(m[1])
    }
    return out
  }
  const a = widths(cur)
  expect(a.has('ccxp 5.1.0 (latest)')).toBe(true)
  expect(a.has('ccxp 5.1.0 ✓')).toBe(true)
  const b = widths({ installed: '5.1.0', latest: '5.2.0' })
  expect(b.has('ccxp 5.1.0 (5.2.0 available)')).toBe(true)
  expect(b.has('ccxp ↑5.2.0')).toBe(true)
  expect(b.has('↑5.2.0')).toBe(true)
})

test('version: `version: false`, no plugin data, or no helper draws nothing', async () => {
  expect(text(bandRows(verSnap(PLUGIN_NEW), { ...DEFAULTS, version: false }, 140))).not.toContain('ccxp')
  expect(text(bandRows(verSnap(null), DEFAULTS, 140))).not.toContain('ccxp')
  expect(text(bandRows({ ...EMPTY, helper: null }, DEFAULTS, 140))).not.toContain('ccxp')
})

test('version: in AP mode it shows too; narrow rows shrink it, the update outlives the plain version, nothing exceeds the width', async () => {
  expect(text(bandRows({ ...snapAp(), helper: { ...parseHelper(HELPER_AP)!, plugin: PLUGIN_NEW } }, DEFAULTS, 160))).toContain('ccxp 5.0.0 (5.1.0 available)')
  for (const cols of [40, 60, 80, 100, 120]) {
    for (const plugin of [PLUGIN_NEW, { installed: '5.0.0', latest: null }, { installed: '5.0.0', latest: '5.0.0' }]) {
      const row = bandRows(verSnap(plugin), NOCI, cols)
      expect(text(row).length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    }
  }
  // Squeezed: the plain version is dropped before CI, the update arrow survives longer.
  const plainRow = text(bandRows(verSnap({ installed: '5.0.0', latest: null }), NOCI, 70))
  expect(plainRow).not.toContain('ccxp')
  const upd = text(bandRows(verSnap(PLUGIN_NEW), NOCI, 100))
  expect(upd).toMatch(/↑|available/)
})

test('version: /hud details shows it on the last line, with `you` when present', async () => {
  // 160 columns: at 120 the URL is already dropped for this snapshot (see the squeeze-order test below)
  const lines = detailRows(verSnap(PLUGIN_NEW), DEFAULTS, 160).map(r => r.map(s => s.text).join(''))
  expect(lines[lines.length - 1]).toContain('ccxp 5.0.0 (5.1.0 available)')
  expect(lines[lines.length - 1]).toContain('you ')
  const off = detailRows(verSnap(PLUGIN_NEW), { ...DEFAULTS, version: false }, 120).map(r => r.map(s => s.text).join(''))
  expect(off.join('\n')).not.toContain('ccxp')
})

const PLUGIN_LATEST = { installed: '5.2.0', latest: '5.2.0' }
const lastLine = (snap: object, cfg = DEFAULTS, cols = 160) => text(detailRows(snap as any, cfg, cols, DETAIL_NOW).slice(-1))

test('version: details show (latest) or (X available) and the GitHub URL, the manifest URL winning over the fallback', async () => {
  expect(lastLine(verSnap(PLUGIN_LATEST))).toMatch(/ccxp 5\.2\.0 \(latest\) │ https:\/\/github\.com\/Synx-Data-Labs\/ccxp-skills$/)
  expect(lastLine(verSnap({ installed: '5.2.0', latest: '5.2.1' }))).toContain('ccxp 5.2.0 (5.2.1 available) │ https://github.com/Synx-Data-Labs/ccxp-skills')
  expect(lastLine(verSnap({ ...PLUGIN_LATEST, url: 'https://github.com/Acme/fork' }))).toMatch(/\(latest\) │ https:\/\/github\.com\/Acme\/fork$/)
  // latest unknown: still the installed version and the link
  expect(lastLine(verSnap({ installed: '5.2.0', latest: null }))).toContain('ccxp 5.2.0 │ https://github.com/Synx-Data-Labs/ccxp-skills')
})

test('version: the link is plain text (no escape bytes) and the band stays compact (no URL)', async () => {
  const lines = text(detailRows(verSnap(PLUGIN_LATEST) as any, DEFAULTS, 160, DETAIL_NOW))
  expect(lines).not.toContain('\u001b')
  expect(text(bandRows(verSnap(PLUGIN_LATEST), DEFAULTS, 160))).not.toContain('github.com')
  expect(text(bandRows(verSnap(PLUGIN_LATEST), DEFAULTS, 160))).toContain('ccxp 5.2.0 (latest)')
})

test('version: narrow details drop the link first and keep the version label', async () => {
  for (const cols of [90, 70, 50, 40, 30]) {
    const last = lastLine(verSnap(PLUGIN_LATEST), DEFAULTS, cols)
    expect(last).not.toContain('github.com')
    expect(last).toContain('ccxp 5.2.0')
  }
  // with every line present the version line is still the last line
  const full = detailRows(fullSnap({ helper: { ...fullSnap().helper, plugin: PLUGIN_LATEST } }) as any, NOCI, 120, DETAIL_NOW)
  expect(full.length).toBe(5)
  expect(text(full.slice(-1))).toContain('(latest)')
})

test('version: squeeze order is URL, then the `you` stamp, then the label; the line always fits', async () => {
  const at = Math.floor(DETAIL_NOW / 1000) - 300
  const snapAt = verSnap(PLUGIN_LATEST, { helper: { ...verSnap(PLUGIN_LATEST).helper, last_input_at: at } })
  const row = (cols: number) => lastLine(snapAt, DEFAULTS, cols)
  const full = row(200)
  expect(full).toMatch(/^you .*\(5m ago\) │ ccxp 5\.2\.0 \(latest\) │ https:/)
  const noUrl = row(full.length - 2) // too narrow for the URL by a little
  expect(noUrl).not.toContain('github.com')
  expect(noUrl).toContain('(5m ago)')
  expect(noUrl).toContain('(latest)')
  const short = row(36) // the stamp's age goes before the label
  expect(short).not.toContain('(5m ago)')
  expect(short).toContain('ccxp 5.2.0')
  for (const cols of [200, 120, 80, 60, 40, 30, 22]) expect(row(cols).length).toBeLessThanOrEqual(Math.max(20, cols - 2))
})

test('version: details with `version: false` or no plugin data show neither label nor link', async () => {
  expect(text(detailRows(verSnap(PLUGIN_LATEST) as any, { ...DEFAULTS, version: false }, 160, DETAIL_NOW))).not.toContain('github.com')
  expect(text(detailRows(verSnap(null) as any, DEFAULTS, 160, DETAIL_NOW))).not.toContain('github.com')
})

test('version: parseHelper keeps only a plain github.com/<owner>/<repo> url', async () => {
  const h = (url: unknown) => parseHelper(JSON.stringify({ ...BASE, plugin: { installed: '5.2.0', latest: '5.2.0', url } }))?.plugin
  expect(h('https://github.com/Acme/w')?.url).toBe('https://github.com/Acme/w')
  for (const bad of ['http://github.com/a/b', 'https://evil.example/a/b', 'https://github.com/a/b/c', 'https://github.com/./..', 'https://github.com/a/b\u001b]8;;x', 'javascript:alert(1)', 42, null]) {
    expect(h(bad)).toEqual({ installed: '5.2.0', latest: '5.2.0' })
  }
})

const BLOB = 'https://github.com/Synx-Data-Labs/synxdb-build-pipeline/blob/main/.github/workflows/nightly-orchestrator.yml'
const ACTIONS = 'https://github.com/Synx-Data-Labs/synxdb-build-pipeline/actions/workflows/nightly-orchestrator.yml'
const REPO = 'Synx-Data-Labs/synxdb-build-pipeline'

test('ciFromAnswer: blob, tree, raw and actions URLs name the workflow; query branch is kept', () => {
  const wf = 'nightly-orchestrator.yml'
  expect(ciFromAnswer(BLOB)).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'main' } })
  expect(ciFromAnswer(BLOB.replace('/blob/', '/tree/'))).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'main' } })
  expect(ciFromAnswer(BLOB.replace('/blob/', '/raw/'))).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'main' } })
  expect(ciFromAnswer(BLOB.replace('/main/', '/release/4.8/') + '#L10')).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'release/4.8' } })
  expect(ciFromAnswer(ACTIONS)).toEqual({ ok: true, ci: { workflow: wf, repo: REPO } })
  expect(ciFromAnswer(ACTIONS + '?query=branch%3Amain')).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'main' } })
  expect(ciFromAnswer(ACTIONS + '?query=event%3Aschedule+branch%3Adev')).toEqual({ ok: true, ci: { workflow: wf, repo: REPO, branch: 'dev' } })
  expect(ciFromAnswer(ACTIONS.replace('https://', ''))).toEqual({ ok: true, ci: { workflow: wf, repo: REPO } })
})

test('ciFromAnswer: surrounding quotes, backticks, angle brackets, whitespace and newlines are tolerated', () => {
  for (const u of [BLOB, ACTIONS]) {
    const want = ciFromAnswer(u)
    expect(want.ok).toBe(true)
    for (const w of [`"${u}"`, `'${u}'`, `\`${u}\``, `<${u}>`, `  ${u}\n`, `\n"${u}"\n`, `\u201c${u}\u201d`, `"'${u}'"`, `${u} `, `${u}\nsomething else`, `(${u})`]) {
      expect(ciFromAnswer(w)).toEqual(want)
    }
  }
  expect(ciFromAnswer('"nightly.yml"')).toEqual({ ok: true, ci: { workflow: 'nightly.yml' } })
  expect(ciFromAnswer('"none"')).toEqual({ ok: true, ci: null })
})

test('ciFromAnswer / cleanAnswer: non-string answers are coerced, never thrown', () => {
  expect(ciFromAnswer(undefined)).toEqual({ ok: true, ci: null })
  expect(ciFromAnswer(null)).toEqual({ ok: true, ci: null })
  expect(ciFromAnswer({ answer: ACTIONS })).toEqual(ciFromAnswer(ACTIONS))
  expect(ciFromAnswer({ text: ` "${BLOB}" ` })).toEqual(ciFromAnswer(BLOB))
  expect(ciFromAnswer([ACTIONS])).toEqual(ciFromAnswer(ACTIONS))
  expect(ciFromAnswer({ weird: 1 })).toEqual({ ok: true, ci: null })
  expect(ciFromAnswer(42)).toEqual({ ok: true, ci: { workflow: '42' } })
  expect(cleanAnswer(`  "x"\n`)).toBe('x')
  expect(cleanAnswer(7)).toBe('7')
})

test('ciFromAnswer: non-workflow URLs are still refused with a reason', () => {
  expect(ciFromAnswer('https://github.com/a/b/actions/runs/9').ok).toBe(false)
  expect(ciFromAnswer('https://example.com/a/b/actions/workflows/x.yml').ok).toBe(false)
  expect(ciFromAnswer('https://github.com/a/b/blob/main/README.md').ok).toBe(false)
})

// --- queue breakdown (dev/TODO/queue.md) ---

const QUEUE = { total: 44, ready: 30, blocked: 6, decision: 3, external: 2, epic: 3, claimed: 0 }
// Short names: the queue cell is dropped early on a tight row (before repo/task shrink), so the long BASE names would crowd it out.
const SHORT = { repo: 'r', branch: 'b', task_id: 'T1', task_title: 't' }

test('queue: parseHelper clamps the counts and a missing or malformed queue is null', async () => {
  expect(parseHelper(HELPER)!.queue).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, queue: 'x' }))!.queue).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, queue: { total: 5, ready: -2, blocked: 1.9, decision: 'a' } }))!.queue).toEqual({ total: 5, ready: 0, blocked: 1, decision: 0, external: 0, epic: 0, claimed: 0 })
})

test('queue: the band shows the compact form, details spell the labels out, claimed only when above 0', async () => {
  const s = withHelper({ ...SHORT, queue: QUEUE })
  expect(text(bandRows(s as any, NOCI, 140))).toContain('queue 44 = 30r 6b 3d 2e 3x')
  expect(detail(s as any, 140).join('\n')).toContain('queue 44 = 30 ready | 6 blocked | 3 decision | 2 external | 3 epic')
  expect(detail(withHelper({ queue: { ...QUEUE, claimed: 2 } }) as any, 160).join('\n')).toContain('3 epic | 2 claimed')
  expect(text(bandRows(s as any, NOCI, 140))).not.toContain('claimed')
})

test('queue: no queue, no cell and no line; a tight band shrinks it to ready/total before dropping it', async () => {
  expect(text(bandRows(withHelper({ queue: null }) as any, NOCI, 140))).not.toContain('queue')
  expect(detail(withHelper({ queue: null }) as any, 140).join('\n')).not.toContain('queue')
  const tight = text(bandRows(withHelper({ ...SHORT, task_title: '', queue: QUEUE, ledger: null, ci: null }) as any, NOCI, 34))
  expect(tight).toMatch(/queue (30\/44|44 = 30r)/)
})

// --- autopilot 24h progress and lifetime average -------------------------------------------------
const STATS = { has_history: true, merged_24h: 8, cycles_24h: 26, avg_merged_24h: 5.2, trend: 'up' }
const apStats = (over = {}) => withHelper({ autopilot: { ...AP, stats: { ...STATS, ...over } } })

test('AP stats: parseHelper keeps a valid stats object; absent or malformed is null', async () => {
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: STATS } }))?.autopilot?.stats).toEqual(STATS)
  expect(parseHelper(HELPER_AP)?.autopilot?.stats).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: [1] } }))?.autopilot?.stats).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: { trend: 'sideways', merged_24h: 'x' } } }))?.autopilot?.stats).toEqual({ has_history: false, merged_24h: 0, cycles_24h: 0, avg_merged_24h: 0, trend: 'flat' })
})

test('AP stats: the wide band shows a labeled last-24h merged/loops, the marker and the spelled-out average', async () => {
  const wide = text(bandRows(apStats(), NOCI, 200))
  expect(wide).toContain('AP 2/6h 3 loops ✓2 merged │ last 24h: 8 merged / 26 loops ▲ average 5.2/day │ ctx')
  expect(text(bandRows(apStats({ trend: 'down', merged_24h: 3 }), NOCI, 200))).toContain('last 24h: 3 merged / 26 loops ▼ average 5.2/day')
  expect(text(bandRows(apStats({ trend: 'flat', merged_24h: 5 }), NOCI, 200))).toContain('last 24h: 5 merged / 26 loops = average 5.2/day')
})

test('AP stats: no history shows only the average, spelled out; no stats shows nothing extra', async () => {
  expect(text(bandRows(apStats({ has_history: false, merged_24h: 0, cycles_24h: 0, trend: 'down' }), NOCI, 200))).toContain('│ average 5.2/day │')
  expect(text(bandRows(withHelper({ autopilot: AP }), NOCI, 200))).not.toMatch(/24h|avg|average/)
})

test('AP stats: the 24h merged count and the average survive 100-140 columns; the ctx bar shrinks first', async () => {
  const at = (cols: number) => text(bandRows(apStats(), NOCI, cols))
  for (const cols of [100, 110, 120, 130, 140]) {
    expect(at(cols)).toMatch(/24h: 8 merged/)
    expect(at(cols)).toContain('average 5.2/day')
  }
  expect(at(120)).toContain('last 24h: 8 merged / 26 loops ▲ average 5.2/day')
  expect(at(110)).not.toContain('▓')
  expect(at(100)).toContain('│ last 24h: 8 merged / 26 loops ▲ average 5.2/day │')
  expect(at(90)).toContain('│ 24h: 8 merged/26 loops ▲ average 5.2/day │')
})

test('AP stats: narrow rows shrink the stats late and keep `avg` only in the narrowest forms; the row always fits', async () => {
  const at = (cols: number) => text(bandRows(apStats(), NOCI, cols))
  expect(at(80)).toContain('24h: ✓8/26L ▲ average 5.2/d')
  expect(at(60)).toContain('24h ✓8/26L ▲ avg 5.2/d')
  expect(at(60)).not.toContain('average')
  for (const cols of [30, 50, 70, 90, 110, 140, 200]) expect(at(cols).length).toBeLessThanOrEqual(cols)
  expect(at(48)).toContain('AP')
  expect(at(48)).toContain('24h ✓8 ▲')
  expect(text(bandRows(apStats(), { ...NOCI, fields: ['ap'] }, 69))).toContain('24h ✓8/26L ▲ avg 5.2/d')
})

test('AP stats: `ap` switched off hides the stats too; details show them on the AP line', async () => {
  expect(text(bandRows(apStats(), { ...NOCI, fields: ['ci'] }, 200))).not.toContain('24h')
  const line = detailRows(apStats() as any, DEFAULTS, 200).map(r => r.map(x => x.text).join('')).find(l => l.startsWith('AP '))
  expect(line).toContain('last 24h: 8 merged / 26 loops ▲ average 5.2/day')
})

// --- CI top row: detail view, highlight, NO_COLOR ---

test('details: CI first and alone, then where/usage/jobs, AP with queue on ONE line, last prompt', async () => {
  const q = { total: 44, ready: 30, blocked: 6, decision: 3, external: 2, epic: 3, claimed: 0 }
  const lines = detail(withHelper({ ...fullSnap().helper, queue: q }), 200, CI)
  expect(lines.length).toBe(6)
  expect(lines[0]).toMatch(/^CI \(nightly\.yml\) ✓ passing \d\d-\d\d \(2h ago\)$/)
  expect(lines[1]).toContain('acme/widgets')
  const ap = lines.find(l => l.startsWith('AP '))!
  expect(ap).toContain('queue 44 = 30 ready | 6 blocked | 3 decision | 2 external | 3 epic')
  expect(ap.indexOf('queue')).toBeGreaterThan(ap.indexOf('merged'))
  expect(ap.indexOf('queue')).toBeLessThan(ap.indexOf('next loop'))
  expect(lines.filter(l => l.includes('queue')).length).toBe(1)
  expect(lines.filter(l => l.includes('CI')).length).toBe(1)
  for (let cols = 200; cols >= 22; cols--) for (const l of detail(withHelper({ ...fullSnap().helper, queue: q }), cols, CI)) expect(l.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
})

test('details: a red CI line is flagged for highlight; a green one is not; no `ci` means no CI line', async () => {
  const red = detailRows(withHelper({ ...fullSnap().helper, ci: { state: 'failing', at: RUN_AT } }) as any, CI, 140, DETAIL_NOW)
  expect(red[0].every(x => x.alert)).toBe(true)
  expect(red.slice(1).some(r => r.some(x => x.alert))).toBe(false)
  expect(detailRows(fullSnap() as any, CI, 140, DETAIL_NOW)[0].some(x => x.alert)).toBe(false)
  expect(detail(fullSnap(), 140, NOCI).join('\n')).not.toContain('CI')
})

test('alertSegs: red row is bold, red, undimmed; NO_COLOR drops the colour and shouts ✗ FAILING', async () => {
  const row = bandRows(withHelper({ ci: { state: 'failing', at: RUN_AT } }), { ...CI, fields: ['ci'] }, 140)[0]
  expect(isAlertRow(row)).toBe(true)
  const color = alertSegs(row, false)
  expect(color.every(x => x.bold === true && x.color === 'error' && !x.dim)).toBe(true)
  expect(text([color])).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26/)
  const plain = alertSegs(row, true)
  expect(plain.every(x => x.bold === true && x.color === undefined)).toBe(true)
  expect(text([plain])).toMatch(/^CI \(nightly\.yml\) ✗ FAILING 10-26 \(\d+[dh] ago\)$/)
  const green = bandRows(withHelper({ ci: { state: 'passing', at: RUN_AT } }), { ...CI, fields: ['ci'] }, 140)[0]
  expect(isAlertRow(green)).toBe(false)
})
