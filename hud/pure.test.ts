import { expect, test } from 'claude-code/testing'

import { ALL_FIELDS, DEFAULTS, borderOf, ciFromAnswer, cleanAnswer, configPaths, heartbeatPath, mergeConfig, parseCi, parseConfigText, parseIssues, withConfig, withEnabled } from './config'
import { FILL_BG, FILL_COLORS, charWidth, displayWidth, fillRow, fillStyleFor, fitSegs, stripAnsi, truncateDisplay } from './fill'
import { findTopic, helpText, parseHelp } from './help'
import { configReport } from './show'
import { alertSegs, isAlertRow } from './render'
import { type Seg, EMPTY, ciEta, formatResetClock, formatRunout, gapTone, rateRunoutHours, rateRunoutSec, firstToRunOut, rateWindows, resetEpochSec, STALL_GRACE_SEC, bandRows, baseName, compactLine, countJobs, ctxTone, busVariants, detailRows, issuesVariants, formatAge, formatIn, formatSpan, formatStamp, isApOn, isNewer, isWithin, jobState, meter, parseHelper, stalledFor, tierOf, truncateWords, versionState } from './model'

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
  // `cost` was retired by the owner on 2026-11-24: an old fields list that names it keeps working, the cell just is not there
  expect(parseConfigText('{"fields": "ctx,rate,cost,lastat"}').fields).toEqual(['ctx', 'rate', 'lastat'])
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
  const q = { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 }
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

test('repo cell: commits behind and ahead the remote sit right after the branch, only when there are some', async () => {
  const b = (behind: number, ahead: number) => ({ behind, ahead, base: 'upstream' as const })
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', behind: b(134, 0) })).toBe('a/b @ main ↓134')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', behind: b(0, 2) })).toBe('a/b @ main ↑2')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', behind: b(134, 2) })).toBe('a/b @ main ↑2 ↓134')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', dirty: 1, behind: b(3, 0) })).toBe('a/b @ main ↓3*')
  expect(repoCell({ repo_slug: 'a/b', branch: 'main', behind: null })).toBe('a/b @ main')
  expect(repoCell({ repo_slug: 'a/b', branch: '', head: 'abc1234', behind: b(5, 0) })).toBe('a/b @ detached abc1234')
})

test('repo cell: behind is neutral under the threshold and warning from it; ahead is always neutral', async () => {
  const seg = (behind: number, text: string) => bandRows(withHelper({ repo_slug: 'a/b', branch: 'main', behind: { behind, ahead: 1, base: 'upstream' } }), { ...NOCI, fields: ['repo'] }, 200)[0].find(x => x.text === text)
  expect(seg(19, ' ↓19')?.color).toBeUndefined()
  expect(seg(20, ' ↓20')?.color).toBe('warning')
  expect(seg(20, ' ↑1')?.color).toBeUndefined()
})

test('parseHelper: behind is read as whole counts, 0/0 or junk means none', async () => {
  const p = (behind: unknown) => parseHelper(JSON.stringify({ ...BASE, behind }))?.behind
  expect(p({ behind: 3, ahead: 1, base: 'origin' })).toEqual({ behind: 3, ahead: 1, base: 'origin' })
  expect(p({ behind: 3, ahead: 'x', base: 'weird' })).toEqual({ behind: 3, ahead: 0, base: 'upstream' })
  expect(p({ behind: 0, ahead: 0, base: 'upstream' })).toBeNull()
  expect(p({ behind: -4 })).toBeNull()
  expect(p('x')).toBeNull()
  expect(p(undefined)).toBeNull()
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

// --- /hud details: the band expanded to live lines (seven at most, eight with a CI row) ---

const DETAIL_NOW = Math.floor(Date.now() / 1000) * 1000 // whole seconds, so 'in 12m' is exact
const detail = (s: object, cols = 140, cfg: typeof CI | typeof NOCI = NOCI) => detailRows(s as any, cfg, cols, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
/** The sections of a details render: label -> its lines (label column stripped, continuation lines included). */
const DETAIL_LABELS = ['SESSION', 'CLONE', 'BUILD', 'SUPPORT', 'AUTOPILOT', 'WORK', 'QUEUE', 'RELEASE']
const sections = (lines: string[]): Record<string, string[]> => {
  const out: Record<string, string[]> = {}
  let cur = ''
  for (const l of lines) {
    const lab = DETAIL_LABELS.find(x => l.startsWith(x + ' '))
    if (lab) { cur = lab; out[cur] = [l.slice(10)] } else if (cur && l.startsWith(' '.repeat(10))) out[cur]!.push(l.slice(10))
    else throw new Error(`line outside any section: ${JSON.stringify(l)}`)
  }
  return out
}
/** One section as a single string (wide terminals: no wrapping). */
const sect = (lines: string[], label: string): string => (sections(lines)[label] ?? []).join(' ')
/** The AUTOPILOT section: the autopilot's cells only. */
const apPart = (lines: string[]): string => sect(lines, 'AUTOPILOT')
const fullSnap = (over = {}) => ({
  ...withHelper({
    repo_slug: 'acme/widgets',
    dirty: 2,
    autopilot: { ...AP, next_wake_at: Math.floor(DETAIL_NOW / 1000) + 720 },
    ledger: { running: [{ job: 70, title: 'Redo HUD repo field' }, { job: 73, title: 'Autopilot cycle 2' }], lifetime_jobs: 82, stats: { approx: false, avg_approx: false, jobs_24h: 8, avg_jobs_day: 5.2, trend: 'up' }, parked: [{ id: 'k1' }, { id: 'k2' }], next_job: 83, updated_at: '' },
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

test('details: sections in order: SESSION, CLONE, AUTOPILOT, WORK (no queue data, no `ci`: no QUEUE or BUILD row)', async () => {
  const lines = detail(fullSnap({ rateUsed: 42 }))
  expect(lines.map(l => l.slice(0, 9).trim())).toEqual(['SESSION', 'CLONE', 'AUTOPILOT', 'WORK'])
  expect(lines[0]).toMatch(/^SESSION {3}context 64% left ▓▓▓▓▓▓░░░░ │ 58% left │ you \d\d:\d\d \(5m ago\)$/)
  expect(lines[1]).toBe('CLONE     acme/widgets @ t20261021-354035-decouple* │ T20261021-354035 Decouple the nightly orchestrator')
  expect(lines[2]).toMatch(/^AUTOPILOT AP on 2\/6h 3 loops ✓2 merged$/)
  expect(lines[3]).toBe('WORK      WORKING (2) │ parked 2 │ last 24h: jobs 8 ▲ / average 5.2/day')
})

test('details: the section order is SESSION, CLONE, BUILD, SUPPORT, AUTOPILOT, WORK, QUEUE, RELEASE, one labeled row each', async () => {
  const snap = fullSnap({ rateUsed: 42 }) as any
  snap.helper = { ...snap.helper, queue: { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 }, nightly: { red: 14, green: 16, strip: '+-++.-+' }, issues: { open: 12, undelivered: 7 }, plugin: { installed: '5.2.0', latest: '5.2.0' } }
  const lines = detail(snap, 400, CI)
  expect(lines.map(l => l.slice(0, 9).trim())).toEqual(DETAIL_LABELS)
  expect(sect(lines, 'BUILD')).toMatch(/^CI \(nightly\.yml\) ✓ passing .* │ nightly \+-\+\+\.-\+ \(last 7 days\)/)
  expect(sect(lines, 'SUPPORT')).toBe('issues 12 open | 7 not delivered')
  expect(sect(lines, 'QUEUE')).toBe('queue 44 = 30 ready | 6 blocked | 3 epics')
})

test('details: colours match the band (ctx tone, READY/WORKING) and the dirty mark is yellow', async () => {
  const rows = detailRows(fullSnap({ ctxLeft: 40 }) as any, NOCI, 140, DETAIL_NOW)
  expect(rows[0].find(s => s.text.startsWith('context '))?.color).toBe('error')
  expect(rows.flat().find(s => s.text.startsWith('WORKING'))).toEqual({ text: 'WORKING (2)', color: 'warning' })
  expect(rows[1].find(s => s.text === '*')?.color).toBe('warning')
  const idle = detailRows(withHelper({ ledger: { running: [], lifetime_jobs: 82, parked: [], next_job: 83, updated_at: '' } }) as any, NOCI, 140, DETAIL_NOW)
  expect(idle.flat().find(s => s.text === 'READY')).toEqual({ text: 'READY', color: 'success' })
})

test('details: the nightly strip (seven one-character pieces) is never split across lines', async () => {
  const snap = fullSnap() as any
  snap.helper = { ...snap.helper, nightly: { red: 14, green: 16, strip: '+-++.-+' } }
  for (let cols = 60; cols >= 22; cols--) {
    const build = sections(detail(snap, cols, CI)).BUILD!
    expect(build.join('\n'), `at ${cols}`).toContain('+-++.-+')
  }
})

test('details: sections with nothing to say are left out (no ledger, no CI config, no prompt time, no ctx)', async () => {
  const lines = detail({ ...withHelper({ ledger: null, last_input_at: 0 }), ctxLeft: null }, 140, DEFAULTS)
  expect(lines.length).toBe(2) // CLONE, AUTOPILOT (no ledger: no WORK section)
  expect(lines[1]).toBe('AUTOPILOT AP off')
  expect(lines.join('\n')).not.toMatch(/READY|WORKING|you |CI/)
})

// --- AUTOPILOT / WORK split: AUTOPILOT carries only the autopilot, WORK every ledger row without the autopilot flag ---
const apRun = (job: number, flags: string) => ({ job, title: 't' + job, flags })
const splitLines = (helper: object) => detail(withHelper({ ci: null, ...helper }) as any, 400)

test('details split: autopilot cycles (flag autopilot) do not count as WORK; housekeeping jobs without the flag do', async () => {
  const led = (running: object[]) => ({ ledger: { running, lifetime_jobs: 9, parked: [], next_job: 10, updated_at: '' } })
  // only autopilot cycles running: WORK is READY, the cycles are named in AUTOPILOT
  const onlyAp = splitLines({ autopilot: { ...AP, busy: true, busy_slots: 2 }, ...led([apRun(5, 'autopilot'), apRun(6, 'autopilot,x')]) })
  expect(sect(onlyAp, 'WORK')).toMatch(/^READY/)
  expect(sect(onlyAp, 'AUTOPILOT')).toContain('2 cycles running')
  // a non-cycle job the autopilot started (no flag) is WORK
  const mixed = splitLines({ autopilot: { ...AP, busy: true, busy_slots: 1 }, ...led([apRun(5, 'autopilot'), apRun(7, '')]) })
  expect(sect(mixed, 'WORK')).toMatch(/^WORKING \(1\)/)
  expect(sect(mixed, 'AUTOPILOT')).not.toMatch(/WORKING|READY|parked/)
  expect(sect(mixed, 'AUTOPILOT')).toContain('running')
  expect(sect(mixed, 'AUTOPILOT')).not.toContain('r7')
})

test('details split: AUTOPILOT carries status, max_dop use, holds count, 24h merged and next wake; WORK none of them', async () => {
  const lines = splitLines({ autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, ap_config: { max_dop: 6, reserved_slots: null, source: 'override', file: true }, queue: { ...AP_Q, apholds: 2 } })
  const ap = sections(lines)['AUTOPILOT']!
  expect(ap[0]).toMatch(/^AP on 2\/6h 3 loops ✓2 merged │ max_dop 6 · 0 running$/)
  expect(ap[1]).toBe('last 24h: 8 merged ▲ / 26 loops · average 5.2/day │ 2 held by autopilot')
  expect(sect(lines, 'WORK')).toMatch(/^WORKING \(1\) │ parked 3/)
  expect(sect(lines, 'WORK')).not.toMatch(/AP |held|max_dop|merged|next loop|stalled/)
  // no holds: no holds cell
  expect(sect(splitLines({ autopilot: { ...AP, next_wake_at: WAKE }, queue: AP_Q }), 'AUTOPILOT')).not.toContain('held')
})

test('details split: a paused autopilot still shows its holds', async () => {
  const lines = splitLines({ autopilot: { ...AP, prefix: '[p]', status: 'paused' }, queue: { ...AP_Q, apholds: 2 } })
  expect(sections(lines)['AUTOPILOT']).toEqual(['AP ⏸ paused 2/6h 3 loops ✓2 merged', '2 held by autopilot'])
})

test('details split: autopilot off leaves AUTOPILOT as `AP off` only (no running, holds, wake or 24h cells) and WORK keeps every job', async () => {
  const lines = splitLines({ autopilot: null, queue: { ...AP_Q, apholds: 3 } })
  expect(sect(lines, 'AUTOPILOT')).toBe('AP off')
  expect(sect(lines, 'WORK')).toMatch(/^WORKING \(1\) │ parked 3/)
})

// --- AUTOPILOT on two lines: status, then progress ---
test('details AUTOPILOT: two lines, status then progress (on with holds, paused, off, overdue, running)', async () => {
  const cfg = { max_dop: 6, reserved_slots: null, source: 'override', file: true }
  const lines = (helper: object, cols = 400) => sections(detail(withHelper({ ci: null, ...helper }) as any, cols))['AUTOPILOT']!
  const q = { ...AP_Q, apholds: 2 }
  const progress = 'last 24h: 8 merged ▲ / 26 loops · average 5.2/day │ 2 held by autopilot'
  // on, with holds: line 1 = state, slots, next loop; line 2 = 24h, average, holds
  const on = lines({ autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, ap_config: cfg, queue: q })
  expect(on.length).toBe(2)
  expect(on[0]).toMatch(/^AP on 2\/6h 3 loops ✓2 merged │ max_dop 6 · 0 running$/)
  expect(on[1]).toBe(progress)
  // paused
  const paused = lines({ autopilot: { ...AP, prefix: '[p]', status: 'paused', stats: STATS }, ap_config: cfg, queue: q })
  expect(paused).toEqual(['AP ⏸ paused 2/6h 3 loops ✓2 merged │ max_dop 6 · 0 running', progress])
  // overdue: red, on line 1
  const od = { ...AP, next_wake_at: Math.floor(DETAIL_NOW / 1000) - 3 * 3600, stats: STATS }
  expect(lines({ autopilot: od, queue: q })).toEqual([expect.stringMatching(/│ stalled 3h$/), progress])
  const odRows = detailRows(withHelper({ ci: null, autopilot: od, queue: q }) as any, NOCI, 400, DETAIL_NOW)
  expect(odRows.flat().find(x => x.text.startsWith('stalled'))?.color).toBe('error')
  // running cycles stay on line 1
  expect(lines({ autopilot: { ...AP, busy: true, busy_slots: 3, stats: STATS }, queue: q })[0]).toMatch(/│ 3 cycles running$/)
  // off: one line, `AP off`; nothing for line 2
  expect(lines({ autopilot: null, queue: q })).toEqual(['AP off'])
  // holds alone (no stats yet) still go on a second line; no holds and no stats: one line
  expect(lines({ autopilot: { ...AP, next_wake_at: WAKE }, queue: q })).toEqual([expect.stringMatching(/^AP on 2\/6h 3 loops ✓2 merged(?!.*next loop)/), '2 held by autopilot'])
  expect(lines({ autopilot: { ...AP, next_wake_at: WAKE }, queue: AP_Q }).length).toBe(1)
  // the second line carries a blank label column and the same colours: holds warning, arrow success
  const rows = detailRows(withHelper({ ci: null, autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, queue: q }) as any, NOCI, 400, DETAIL_NOW)
  const second = rows[rows.findIndex(r => r[0].text.startsWith('AUTOPILOT')) + 1]!
  expect(second[0]!.text).toBe(' '.repeat(10))
  expect(second.find(x => x.text === '2 held by autopilot')?.color).toBe('warning')
  expect(second.find(g => /▲/.test(g.text))?.color).toBe('success')
  // a narrow terminal wraps each line on its own; no label is abbreviated
  const narrow = lines({ autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, ap_config: cfg, queue: q }, 50)
  expect(squash(narrow.join(''))).toBe(squash(on.join('')))
})

test('details: parked shows the count only, never the parked ids', async () => {
  const ids = ['k5', 'k6', 'k7', 'k8', 'k9', 'k10', 'k11', 'k12', 'k13']
  const ledger = { running: [], lifetime_jobs: 82, parked: ids.map(id => ({ id })), next_job: 83, updated_at: '' }
  const lines = detail(withHelper({ ledger }) as any, 140)
  expect(sect(lines, 'WORK')).toMatch(/READY │ parked 9$/)
  expect(lines.join('\n')).not.toMatch(/k\d/)
})

const jobsLine = (stats: unknown) => jobsPart(detail(withHelper({ ledger: { running: [], lifetime_jobs: 782, stats, parked: [], next_job: 783, updated_at: '' } }) as any, 400))
const jobsPart = (lines: string[]): string => sect(lines, 'WORK').replace(/^.*?(?=READY|WORKING)/, '')
const JS = { approx: false, avg_approx: false, jobs_24h: 8, avg_jobs_day: 5.2, trend: 'up' }

test('details: the jobs cells end with `last 24h: jobs n / average m/day` and never show a total-jobs figure', async () => {
  expect(jobsLine(JS)).toBe('READY │ parked 0 │ last 24h: jobs 8 ▲ / average 5.2/day')
  expect(jobsLine({ ...JS, jobs_24h: 3, trend: 'down' })).toBe('READY │ parked 0 │ last 24h: jobs 3 ▼ / average 5.2/day')
  expect(jobsLine({ ...JS, jobs_24h: 5, avg_jobs_day: 5.04, trend: 'flat' })).toBe('READY │ parked 0 │ last 24h: jobs 5 / average 5.0/day') // equal at one decimal: no arrow
  expect(jobsLine({ ...JS, approx: true })).toBe('READY │ parked 0 │ last 24h: jobs ~8 / average 5.2/day') // estimate: ~, no arrow
  expect(jobsLine({ ...JS, avg_approx: true })).toBe('READY │ parked 0 │ last 24h: jobs 8 ▲ / average ~5.2/day')
  expect(jobsLine(null)).toBe('READY │ parked 0') // no stats, no cell, no total fallback
  expect(jobsLine(undefined)).toBe('READY │ parked 0')
  expect(detail(fullSnap(), 140).join('\n')).not.toMatch(/total jobs/)
})

test('details: the jobs 24h arrow is green above, red below, and absent for equal or an estimate', async () => {
  const arrow = (stats: object) => detailRows(withHelper({ ledger: { running: [], lifetime_jobs: 782, stats, parked: [], next_job: 783, updated_at: '' } }) as any, NOCI, 140, DETAIL_NOW)[3].find(g => /[▲▼]/.test(g.text))
  expect(arrow(JS)?.color).toBe('success')
  expect(arrow({ ...JS, trend: 'down' })?.color).toBe('error')
  expect(arrow({ ...JS, trend: 'flat' })).toBeUndefined()
  expect(arrow({ ...JS, approx: true })).toBeUndefined()
})

test('parseHelper: ledger.stats is kept when it is an object, otherwise null', async () => {
  const get = (stats: unknown) => parseHelper(JSON.stringify({ ...BASE, ledger: { running: [], lifetime_jobs: 5, stats, parked: [], next_job: 6, updated_at: '' } }))!.ledger!.stats
  expect(get(JS)).toEqual(JS)
  expect(get({ jobs_24h: 2.7, avg_jobs_day: 1, trend: 'sideways' })).toEqual({ approx: false, avg_approx: false, jobs_24h: 2, avg_jobs_day: 1, trend: 'flat' })
  for (const bad of [undefined, null, 'x', []]) expect(get(bad)).toBeNull()
})

test('details: every line fits the terminal at every width and the band row is untouched', async () => {
  for (let cols = 140; cols >= 22; cols--) {
    for (const s of [fullSnap(), fullSnap({ stale: true, rateUsed: 99 })]) {
      for (const line of detail(s, cols)) expect(line.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    }
  }
  expect(bandRows(fullSnap() as any, NOCI, 140).length).toBe(1)
})

const squash = (t: string) => t.replace(/[\s│]+/g, '')

test('details: a narrow terminal wraps a section onto an indented line, never cuts or abbreviates anything', async () => {
  const snap = () => fullSnap({ rateUsed: 42 })
  const wide = sections(detail(snap(), 400))
  expect(wide.SESSION).toEqual([expect.stringMatching(/^context 64% left ▓▓▓▓▓▓░░░░ │ 58% left │ you /)])
  // 56 columns: the SESSION row no longer fits on one line, so it wraps under the cells (indented by the label width)
  const lines = detail(snap(), 56)
  const sess = lines.filter((l, i) => i < 3 && (l.startsWith('SESSION') || l.startsWith(' '.repeat(10))))
  expect(sess.length).toBeGreaterThan(1)
  expect(sess[1]!.startsWith(' '.repeat(10))).toBe(true)
  expect(sess.join('\n')).not.toContain('…')
  // at every width every section keeps ALL of its text (modulo the blanks the wrapping eats) and every line fits
  for (let cols = 140; cols >= 22; cols--) {
    const narrow = sections(detail(snap(), cols))
    for (const label of Object.keys(wide)) expect(squash(narrow[label]!.join('')), `${label} at ${cols} columns`).toBe(squash(wide[label]!.join('')))
    expect(detail(snap(), cols).join('\n')).not.toContain('…')
    // no shortened forms at any width (the band's ctx / 5h / bare `total` forms never appear in details)
    expect(detail(snap(), cols).join('\n')).not.toMatch(/\bctx\b|5h limit|5-hour limit|API-equivalent|total \d|\bnext in\b/)
  }
  const old = Math.floor(DETAIL_NOW / 1000) - 3 * 86400
  expect(sect(detail(fullSnap({ helper: { ...fullSnap().helper, last_input_at: old } }), 400), 'SESSION')).toMatch(/you \w{3} \d+ \d\d:\d\d \(3d ago\)$/)
})

const RATE_NOW = 1_800_000_000_000
const rateReset = (elapsedSec: number) => RATE_NOW / 1000 + 5 * 3600 - elapsedSec

test('gapTone: more than 30 minutes green, more than 10 up to 30 yellow, 10 or less red, no runout green', () => {
  expect([31, 30, 11, 10, 1, 0].map(m => gapTone(m * 60))).toEqual(['success', 'warning', 'warning', 'error', 'error', 'error'])
  expect(gapTone(30 * 60 + 1)).toBe('success')
  expect(gapTone(10 * 60 + 1)).toBe('warning')
  expect(gapTone(null)).toBe('success')
})

test('rateRunoutHours: used% / elapsed projects the time to 100%; null when it outlasts the window or data is thin ', () => {
  // 50% in 1h: 1h more to full, 4h still in the window
  expect(Math.round(rateRunoutHours(50, rateReset(3600), RATE_NOW)! * 1000)).toBe(1000)
  // 80% in 2h: 0.5h to full
  expect(Math.round(rateRunoutHours(80, rateReset(7200), RATE_NOW)! * 1000)).toBe(500)
  // 10% in 2h: 18h to full, past the reset
  expect(rateRunoutHours(10, rateReset(7200), RATE_NOW)).toBeNull()
  expect(rateRunoutHours(50, null, RATE_NOW)).toBeNull() // no reset time
  expect(rateRunoutHours(0, rateReset(3600), RATE_NOW)).toBeNull() // nothing used
  expect(rateRunoutHours(50, rateReset(60), RATE_NOW)).toBeNull() // under 2 minutes elapsed: no projection
  expect(rateRunoutHours(50, RATE_NOW / 1000 - 5, RATE_NOW)).toBeNull() // window already reset
  expect(rateRunoutHours(100, rateReset(3600), RATE_NOW)).toBeNull() // already at the limit: no estimate
})

test('formatRunout: 1.5h from an hour, 40m below, never 0m', () => {
  expect([formatRunout(1.5), formatRunout(1), formatRunout(2.04), formatRunout(2 / 3), formatRunout(0.001), formatRunout(0.995)]).toEqual(['1.5h', '1h', '2h', '40m', '1m', '1h'])
})


test('resetEpochSec: epoch seconds, milliseconds, a numeric string or an ISO string; anything else is null', () => {
  expect([resetEpochSec(1_800_000_000), resetEpochSec(1_800_000_000_000), resetEpochSec('1800000000'), resetEpochSec('2027-01-15T08:00:00Z'), resetEpochSec('x'), resetEpochSec(null), resetEpochSec(0)]).toEqual([1_800_000_000, 1_800_000_000, 1_800_000_000, 1_800_000_000, null, null, null])
})

// A 5-hour window with `elapsed` seconds gone and `used` percent spent runs out after (100 - used) * elapsed / used seconds.
const gapMin = (m: number) => ({ rateUsed: 50, rateResetsAt: rateReset(m * 60) }) // 50% used after m minutes: runs out m minutes from now

test('rateRunoutSec: seconds to 100% at the burn rate; the window length is a parameter', () => {
  expect(rateRunoutSec(50, rateReset(1800), RATE_NOW)).toBe(1800)
  expect(rateRunoutSec(50, RATE_NOW / 1000 + 6 * 86400, RATE_NOW, 7 * 86400)).toBe(86400)
  expect(rateRunoutSec(10, rateReset(1800), RATE_NOW)).toBeNull() // outlasts the window
})

test('rate cell: percent left, runs out in Nm and the reset time; coloured by the gap to runout (boundaries 31/30/11/10 minutes)', () => {
  const rate = (over: object, cols = 200) => bandRows(fullSnap(over) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, cols, RATE_NOW)
  const find = (rows: Seg[][], re: RegExp) => rows.flat().find(g => re.test(g.text))
  const tone = (m: number) => find(rate(gapMin(m)), /runs out/)?.color
  expect([31, 30, 11, 10].map(tone)).toEqual(['success', 'warning', 'warning', 'error'])
  expect(find(rate(gapMin(30)), /50% left/)?.color).toBe('warning') // the percent is coloured by the gap too, not by itself
  expect(find(rate(gapMin(10)), /reset /)?.color).toBe('error')
  const row = text(rate(gapMin(28)))
  expect(row).toMatch(/50% left · runs out in 28m · reset (\w{3} )?\d\d:\d\d \S+/)
  expect(row).not.toMatch(/5h|5-hour|7d|resets/)
  // no runout before the reset: no runout text, green, however little is left
  const noRunout = rate({ rateUsed: 20, rateResetsAt: rateReset(7200) })
  expect(text(noRunout)).toMatch(/80% left · reset (\w{3} )?\d\d:\d\d/)
  expect(text(noRunout)).not.toMatch(/runs out/)
  expect(find(noRunout, /80% left/)?.color).toBe('success')
  // a spent limit is red
  expect(find(rate({ rateUsed: 100, rateResetsAt: rateReset(7200) }), /0% left/)?.color).toBe('error')
  // low percent but a long gap stays green (the colour follows the gap, not the percent)
  expect(find(rate({ rateUsed: 92, rateResetsAt: rateReset(17900) }), /8% left/)?.color).toBe('success')
})

test('rate cell: colour and text use the same whole minutes, rounded down (10m20s reads 10m and is red)', () => {
  const rate = (over: object) => bandRows(fullSnap(over) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, 200, RATE_NOW)
  const find = (rows: Seg[][], re: RegExp) => rows.flat().find(g => re.test(g.text))
  const secs = (s: number) => ({ rateUsed: 50, rateResetsAt: rateReset(s) }) // 50% used: runs out s seconds from now
  const at = (s: number) => find(rate(secs(s)), /runs out/)
  expect([at(10 * 60 + 20)?.text, at(10 * 60 + 20)?.color]).toEqual([' · runs out in 10m', 'error'])
  expect([at(11 * 60 - 1)?.text, at(11 * 60 - 1)?.color]).toEqual([' · runs out in 10m', 'error'])
  expect([at(11 * 60)?.text, at(11 * 60)?.color]).toEqual([' · runs out in 11m', 'warning'])
  expect([at(31 * 60 - 1)?.text, at(31 * 60 - 1)?.color]).toEqual([' · runs out in 30m', 'warning'])
  expect([at(31 * 60)?.text, at(31 * 60)?.color]).toEqual([' · runs out in 31m', 'success'])
})

const win = (label: '5h' | '7d', used: number, resetIn: number, sec: number) => ({ label, used, resetsAt: RATE_NOW / 1000 + resetIn, sec })
const five = (used: number, resetIn: number) => win('5h', used, resetIn, 5 * 3600)
const seven = (used: number, resetIn: number) => win('7d', used, resetIn, 7 * 86400)
const DAY = 86400

test('firstToRunOut: both run out, the 5-hour one first even with more % left; the 7-day one first when it is the only one that runs out', () => {
  expect(firstToRunOut([five(80, 4320), seven(95, 3 * DAY + 4 * 3600)], RATE_NOW).w.label).toBe('5h') // 57m vs ~4h
  expect(Math.round(firstToRunOut([five(80, 4320), seven(95, 3 * DAY + 4 * 3600)], RATE_NOW).gap!)).toBe(3420)
  // 5h has more left (30%) than 7d (5%) yet runs out sooner: runout time ranks, not % left
  expect(firstToRunOut([five(90, 3000), seven(95, 3 * DAY)], RATE_NOW).w.label).toBe('5h')
  // 7d first: 5h does not run out before its reset
  const r = firstToRunOut([five(10, 4320), seven(90, 3 * DAY + 4 * 3600)], RATE_NOW)
  expect(r.w.label).toBe('7d')
  expect(r.gap).not.toBeNull()
})

test('firstToRunOut: a window that runs out beats one with less % left that does not; neither running out falls back to less % left, a full tie keeps 5h', () => {
  // 7d: 60% used 6 days in, 4 days to full is past its 1 day reset (no runout), but 5h (80% used) runs out
  expect(firstToRunOut([five(80, 4320), seven(60, DAY)], RATE_NOW).w.label).toBe('5h')
  expect(firstToRunOut([seven(96, 3 * DAY), five(10, 7200)], RATE_NOW).w.label).toBe('7d') // 7d runs out, 5h does not
  expect(firstToRunOut([five(20, 7200), seven(40, 3 * DAY)], RATE_NOW).w.label).toBe('7d') // neither runs out: less left
  expect(firstToRunOut([five(60, 7200), seven(20, 3 * DAY)], RATE_NOW).w.label).toBe('5h')
  const tie = firstToRunOut([five(20, 7200), seven(20, 3 * DAY)], RATE_NOW)
  expect([tie.w.label, tie.gap]).toEqual(['5h', null])
  expect(firstToRunOut([seven(34, DAY)], RATE_NOW).w.label).toBe('7d') // one window
})

test('firstToRunOut: equal runout gaps fall back to less % left, then 5h', () => {
  // both spent: gap 0 each, equal % left, so the first listed (5h in practice) stays
  const a = firstToRunOut([five(100, 3600), seven(100, 3 * DAY)], RATE_NOW)
  expect([a.w.label, a.gap]).toEqual(['5h', 0])
  expect(firstToRunOut([seven(100, 3 * DAY), five(100, 3600)], RATE_NOW).w.label).toBe('7d') // full tie keeps the first listed
})

test('firstToRunOut: a spent window (0 left) runs out first, at gap 0', () => {
  const s = firstToRunOut([five(80, 4320), seven(100, 3 * DAY)], RATE_NOW)
  expect([s.w.label, s.gap]).toEqual(['7d', 0])
})

test('rate cell: the window that runs out first is shown with the gap colour computed from it (5h first, 7d first, neither, one missing, tie)', () => {
  const band = (over: object) => bandRows(fullSnap(over) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, 200, RATE_NOW)
  const find = (rows: Seg[][], re: RegExp) => rows.flat().find(g => re.test(g.text))
  const D = 86400
  // 5h: 70% used 4320 s from reset, 7d: 95% used (5% left, less): 5h runs out first, so 5h shows
  const fiveFirst = band({ rateUsed: 80, rateResetsAt: inSec(4320), rate7Used: 95, rate7ResetsAt: inSec(3 * D) })
  expect(text(fiveFirst)).toMatch(/20% left · runs out in 57m/)
  expect(text(fiveFirst)).not.toMatch(/5% left/)
  // 7d first: 5h is fine (no runout before reset), 7d runs out
  const sevenFirst = band({ rateUsed: 10, rateResetsAt: inSec(4320), rate7Used: 90, rate7ResetsAt: inSec(3 * D + 4 * 3600) })
  expect(text(sevenFirst)).toMatch(/10% left · runs out in 10\.2h/)
  expect(find(sevenFirst, /10% left/)?.color).toBe('success') // gap 10.2h, from the chosen (7d) window
  // neither runs out: less % left wins (the 7-day one here), green
  const neither = band({ rateUsed: 20, rateResetsAt: inSec(7200), rate7Used: 40, rate7ResetsAt: inSec(3 * D) })
  expect(text(neither)).toMatch(/60% left · reset/)
  expect(text(neither)).not.toMatch(/runs out|80% left/)
  expect(find(neither, /60% left/)?.color).toBe('success')
  // one window missing: the other shows; both missing (API-key login): nothing
  expect(text(band({ rate7Used: 40, rate7ResetsAt: inSec(3 * D) }))).toMatch(/60% left/)
  expect(text(band({ rateUsed: 20, rateResetsAt: inSec(7200) }))).toMatch(/80% left/)
  expect(text(band({}))).not.toMatch(/% left · /)
  // tie in runout (none) and in % left: the 5-hour window (nearer reset, same text pieces)
  const tie = band({ rateUsed: 20, rateResetsAt: inSec(7200), rate7Used: 20, rate7ResetsAt: inSec(3 * D) })
  expect(text(tie)).toMatch(/80% left · reset (\w{3} )?\d\d:\d\d/)
})

test('formatResetClock: local clock time with the timezone abbreviation, weekday when not today', () => {
  const at = Date.UTC(2027, 0, 15, 19, 55) / 1000 // 13:55 in Chicago (CST), 20:55 in Paris, 03:55 next day in Shanghai
  const now = Date.UTC(2027, 0, 15, 10, 0)
  expect(formatResetClock(at, now, 'America/Chicago')).toBe('13:55 CST')
  expect(formatResetClock(at, now, 'Asia/Shanghai')).toBe('Sat 03:55 CST')
  expect(formatResetClock(at, now, 'UTC')).toBe('19:55 UTC')
  expect(formatResetClock(at, now, 'Europe/Paris')).toMatch(/^20:55 (CET|GMT\+1)$/)
  expect(formatResetClock(NaN, now, 'UTC')).toBeNull()
})

const inSec = (sec: number) => RATE_NOW / 1000 + sec

test('rateWindows: a missing percent or a reset time already past drops that window only', () => {
  const w = (over: object) => rateWindows({ ...EMPTY, ...over } as any, RATE_NOW).map(x => x.label)
  expect(w({ rateUsed: 20, rateResetsAt: inSec(3600), rate7Used: 30, rate7ResetsAt: inSec(86400) })).toEqual(['5h', '7d'])
  expect(w({ rateUsed: 20, rateResetsAt: inSec(3600) })).toEqual(['5h']) // 7-day absent (older version, or a plan without it)
  expect(w({ rate7Used: 30, rate7ResetsAt: inSec(86400) })).toEqual(['7d'])
  expect(w({})).toEqual([]) // API-key login: nothing, no error
  expect(w({ rateUsed: 20, rateResetsAt: inSec(-1), rate7Used: 30, rate7ResetsAt: inSec(86400) })).toEqual(['7d']) // 5h reset time passed
  expect(w({ rateUsed: 20, rate7Used: 30 })).toEqual(['5h', '7d']) // percent without a reset time still shows
})

test('rate cell: the window that runs out first wins, no labels; a missing or past window shows nothing, never an error', () => {
  const band = (over: object, cols = 200) => bandRows(fullSnap(over) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, cols, RATE_NOW)
  const CLOCK = '(\\w{3} )?\\d\\d:\\d\\d \\S+'
  const both = { rateUsed: 80, rateResetsAt: inSec(4320), rate7Used: 34, rate7ResetsAt: inSec(3 * 86400 + 4 * 3600) }
  // 5h has 20% left, 7d has 66%: the 5-hour window shows, runs out in 57m (80% used 13680 s into the window)
  expect(text(band(both))).toMatch(new RegExp(`20% left · runs out in 57m · reset ${CLOCK}`))
  expect(text(band(both))).not.toMatch(/66%|7d|5h/)
  // 7d runs out first: it shows, projected over the 7-day window, with the weekday on its reset
  const sevenTight = { rateUsed: 10, rateResetsAt: inSec(4320), rate7Used: 90, rate7ResetsAt: inSec(3 * 86400 + 4 * 3600) }
  expect(text(band(sevenTight))).toMatch(new RegExp(`10% left · runs out in 10\\.2h · reset (Mon|Tue|Wed|Thu|Fri|Sat|Sun) ${CLOCK}`))
  // one window only
  expect(text(band({ rateUsed: 80, rateResetsAt: inSec(4320) }))).toContain('20% left · runs out in 57m')
  expect(text(band({ rate7Used: 34, rate7ResetsAt: inSec(90000) }))).toContain('66% left')
  expect(text(band({}))).not.toMatch(/% left · /) // both missing: no cell
  expect(text(band({ rateUsed: 80, rateResetsAt: inSec(-5) }))).not.toMatch(/20% left/) // past reset: dropped
  // narrow: the reset time goes first, then the runout; the percent stays
  const narrow = (cols: number) => text(bandRows({ ...EMPTY, ...both } as any, { ...NOCI, fields: ['rate'] }, cols, RATE_NOW))
  expect(narrow(60)).toMatch(new RegExp(`^20% left · runs out in 57m · reset ${CLOCK}$`))
  expect(narrow(28)).toBe('20% left · runs out in 57m')
  expect(narrow(22)).toBe('20% left')
  // rounding: 79.6 used shows 20% left
  expect(text(band({ rateUsed: 79.6 }))).toContain('20% left')
})

test('rate cell: NO_COLOR keeps the text (the colour is a theme token the renderer drops), so the gap is still readable', () => {
  const rows = bandRows(fullSnap(gapMin(5)) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, 200, RATE_NOW)
  expect(text(rows)).toContain('runs out in 5m')
})

test('details: the SESSION row carries the full limit text: percent left, runs out in, reset time, no label', () => {
  const d = (over: object) => sect(detailRows(fullSnap(over) as any, NOCI, 400, RATE_NOW).map(r => r.map(g => g.text).join('')), 'SESSION')
  expect(d({ rateUsed: 80, rateResetsAt: inSec(4320), rate7Used: 34, rate7ResetsAt: inSec(3 * 86400 + 4 * 3600) })).toMatch(/│ 20% left · runs out in 57m · reset (\w{3} )?\d\d:\d\d \S+( │|$)/)
  expect(d({ rate7Used: 34, rate7ResetsAt: inSec(86400) })).toMatch(/66% left · reset \S+ \d\d:\d\d/)
  expect(d({ rateUsed: 80, rateResetsAt: inSec(4320) })).not.toMatch(/5-hour|7-day|limit/)
})

test('details: the jobs cells never list the running jobs (the band already shows them); labels are spelled out', async () => {
  const lines = detail(fullSnap({ rateUsed: 4, ctxLeft: 88 }), 400)
  expect(sect(lines, 'SESSION')).toMatch(/^context 88% left ▓▓▓▓▓▓▓▓▓░ │ 96% left/)
  const all = lines.join('\n')
  expect(all).not.toMatch(/r70|r73|Redo HUD|Autopilot cycle|\btot\b|\bctx\b/)
  expect(jobsPart(lines)).toBe('WORKING (2) │ parked 2 │ last 24h: jobs 8 ▲ / average 5.2/day')
  // ...but the one-row band keeps its short forms
  expect(text(bandRows(fullSnap({ rateUsed: 4 }) as any, { ...NOCI, fields: [...CI.fields, 'rate'] }, 200))).toContain('ctx 64% ▓▓▓▓▓▓░░░░ │ WORKING (2)')
})

test('formatIn: under a minute, minutes, hours with minutes, days; due or past is now', async () => {
  const at = 1_000_000
  const inn = (secs: number) => formatIn(at, (at - secs) * 1000)
  expect([inn(30), inn(60), inn(720), inn(3599), inn(3600), inn(3900), inn(86400 * 2)]).toEqual(['in <1m', 'in 1m', 'in 12m', 'in 59m', 'in 1h', 'in 1h 5m', 'in 2d'])
  expect([inn(0), inn(-5)]).toEqual(['now', 'now'])
})

test('details: AP line carries no next-loop clock or countdown, whatever the wake time (owner decision d191)', async () => {
  // Local-time construction: the same clock reading in every timezone, never "yesterday".
  const now = new Date(2026, 9, 28, 12, 0, 0).getTime()
  const wake = Math.floor(now / 1000) + 12 * 60
  const apLine = (over: object, cols = 400) => apPart(detailRows(withHelper({ autopilot: { ...AP, ...over }, ci: null }) as any, DEFAULTS, cols, now).map(r => r.map(x => x.text).join('')))
  expect(apLine({ next_wake_at: wake })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apLine({ next_wake_at: wake + 86400 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apLine({ next_wake_at: Math.floor(now / 1000) - 5 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apLine({ next_wake_at: 0 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apLine({ next_wake_at: wake, status: 'paused', prefix: '[p]' })).toBe('AP ⏸ paused 2/6h 3 loops ✓2 merged')
  // a running cycle says `running` (or `N cycles running` with parallel cycles); the ledger job numbers are never shown
  const led = (rows: object[]) => ({ ledger: { running: rows, lifetime_jobs: 600, parked: [], next_job: 700, updated_at: '' } })
  const apWith = (rows: object[], over: object) => apPart(detailRows(withHelper({ autopilot: { ...AP, ...over }, ci: null, ...led(rows) }) as any, DEFAULTS, 400, now).map(r => r.map(x => x.text).join('')))
  const busy = { next_wake_at: wake, busy: true, current_task: 'T20261028-151063' }
  const rows = [{ job: 590, title: 'other', flags: '' }, { job: 596, title: 'autopilot cycle', flags: 'autopilot' }, { job: 599, title: 'x', flags: 'detached' }]
  expect(apWith(rows, busy)).toBe('AP on 2/6h 3 loops ✓2 merged │ running')
  expect(apWith(rows, { ...busy, next_wake_at: Math.floor(now / 1000) - 5 })).toMatch(/│ running$/)
  expect(apWith(rows, { ...busy, current_task: '' })).toMatch(/│ running$/)
  expect(apWith(rows, { ...busy, busy_slots: 2 })).toBe('AP on 2/6h 3 loops ✓2 merged │ 2 cycles running')
  expect(apWith(rows, { ...busy, busy_slots: 1 })).toBe('AP on 2/6h 3 loops ✓2 merged │ running')
  expect(apWith(rows, busy)).not.toMatch(/r\d/)
  expect(apWith([{ job: 599, title: 'x', flags: 'detached' }], busy)).toBe('AP on 2/6h 3 loops ✓2 merged │ running')
  expect(apWith([], busy)).toMatch(/│ running$/)
  expect(apWith(rows, { next_wake_at: wake })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(apWith(rows, { next_wake_at: Math.floor(now / 1000) - 5 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  // paused still wins over a busy mark
  expect(apLine({ next_wake_at: wake, busy: true, current_task: 'T20261028-151063', status: 'paused', prefix: '[p]' })).toBe('AP ⏸ paused 2/6h 3 loops ✓2 merged')
  // AP off or no record: no schedule
  expect(detailRows(withHelper({ autopilot: null }) as any, DEFAULTS, 140, now).map(r => r.map(x => x.text).join('')).join('\n')).not.toContain('next')
  // narrow: the row wraps, nothing about the next loop appears
  expect(squash(apLine({ next_wake_at: wake }, 52))).toBe(squash('AP on 2/6h 3 loops ✓2 merged'))
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
  expect(detail({ ...EMPTY, stale: true }, 140, DEFAULTS)).toEqual(['CLONE     stale'])
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

test('version: /hud details shows it in the RELEASE section (and `you` in SESSION)', async () => {
  const lines = detailRows(verSnap(PLUGIN_NEW), DEFAULTS, 160).map(r => r.map(s => s.text).join(''))
  expect(sect(lines, 'RELEASE')).toContain('ccxp 5.0.0 (5.1.0 available)')
  expect(sect(lines, 'SESSION')).toContain('you ')
  expect(lines[lines.length - 1]).toMatch(/^RELEASE /)
  const off = detailRows(verSnap(PLUGIN_NEW), { ...DEFAULTS, version: false }, 120).map(r => r.map(s => s.text).join(''))
  expect(off.join('\n')).not.toContain('ccxp')
})

const PLUGIN_LATEST = { installed: '5.2.0', latest: '5.2.0' }
const lastLine = (snap: object, cfg = DEFAULTS, cols = 160) => sect(detailRows(snap as any, cfg, cols, DETAIL_NOW).map(r => r.map(x => x.text).join('')), 'RELEASE')

test('version: details show the GitHub URL first, then (latest) or (X available); the manifest URL wins over the fallback', async () => {
  expect(lastLine(verSnap(PLUGIN_LATEST))).toBe('https://github.com/Synx-Data-Labs/ccxp-skills │ ccxp 5.2.0 (latest)')
  expect(lastLine(verSnap({ installed: '5.2.0', latest: '5.2.1' }))).toBe('https://github.com/Synx-Data-Labs/ccxp-skills │ ccxp 5.2.0 (5.2.1 available)')
  expect(lastLine(verSnap({ ...PLUGIN_LATEST, url: 'https://github.com/Acme/fork' }))).toMatch(/^https:\/\/github\.com\/Acme\/fork │ ccxp 5\.2\.0 \(latest\)$/)
  // latest unknown: still the link and the installed version
  expect(lastLine(verSnap({ installed: '5.2.0', latest: null }))).toBe('https://github.com/Synx-Data-Labs/ccxp-skills │ ccxp 5.2.0')
})

test('version: details show only the NUMBER of commits after the installed release (never subjects); the band never does', async () => {
  const u = { count: 5 }
  expect(lastLine(verSnap({ ...PLUGIN_LATEST, unreleased: u }), DEFAULTS, 220)).toMatch(/ccxp-skills │ ccxp 5\.2\.0 \(latest\) │ 5 unreleased$/)
  expect(lastLine(verSnap({ ...PLUGIN_LATEST, unreleased: { count: 1 } }), DEFAULTS, 220)).toMatch(/ │ 1 unreleased$/)
  // silent without data
  expect(lastLine(verSnap(PLUGIN_LATEST))).not.toContain('unreleased')
  expect(text(bandRows(verSnap({ ...PLUGIN_LATEST, unreleased: u }) as any, DEFAULTS, 220))).not.toContain('unreleased')
})

test('version: parseHelper keeps only a positive count of the unreleased commits and drops any subjects', async () => {
  const h = (unreleased: unknown) => parseHelper(JSON.stringify({ ...BASE, plugin: { ...PLUGIN_LATEST, unreleased } }))?.plugin?.unreleased
  expect(h({ count: 2, subjects: ['a', 'b'] })).toEqual({ count: 2 })
  expect(h({ count: 0 })).toBeUndefined()
  expect(h({ count: 'x' })).toBeUndefined()
  expect(h(['a'])).toBeUndefined()
  expect(h(null)).toBeUndefined()
})

test('version: the link is plain text (no escape bytes) and the band stays compact (no URL)', async () => {
  const lines = text(detailRows(verSnap(PLUGIN_LATEST) as any, DEFAULTS, 160, DETAIL_NOW))
  expect(lines).not.toContain('\u001b')
  expect(text(bandRows(verSnap(PLUGIN_LATEST), DEFAULTS, 160))).not.toContain('github.com')
  expect(text(bandRows(verSnap(PLUGIN_LATEST), DEFAULTS, 160))).toContain('ccxp 5.2.0 (latest)')
})

test('version: narrow details wrap the RELEASE row (the link is never dropped and nothing is cut)', async () => {
  const wide = squash(lastLine(verSnap({ ...PLUGIN_LATEST, unreleased: { count: 3 } }), DEFAULTS, 400))
  for (const cols of [160, 90, 70, 50, 40, 30, 22]) {
    const rows = detailRows(verSnap({ ...PLUGIN_LATEST, unreleased: { count: 3 } }) as any, DEFAULTS, cols, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
    expect(squash(sect(rows, 'RELEASE')), `at ${cols} columns`).toBe(wide)
    expect(rows.join('\n')).not.toContain('…')
    for (const l of rows) expect(l.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
  }
  expect(wide).toContain('github.com/Synx-Data-Labs/ccxp-skills')
  expect(wide).toContain('3unreleased')
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

const QUEUE = { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0, apholds: 0 }
// Short names: the queue cell is dropped early on a tight row (before repo/task shrink), so the long BASE names would crowd it out.
const SHORT = { repo: 'r', branch: 'b', task_id: 'T1', task_title: 't' }

test('queue: parseHelper clamps the counts and a missing or malformed queue is null', async () => {
  expect(parseHelper(HELPER)!.queue).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, queue: 'x' }))!.queue).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, queue: { total: 5, ready: -2, blocked: 1.9, revisited: 7, decision: 4 } }))!.queue).toEqual({ total: 5, ready: 0, blocked: 1, epic: 0, claimed: 0, apholds: 0 })
})

test('queue: the band shows the compact form, details spell the labels out, claimed only when above 0, no revisited count', async () => {
  const s = withHelper({ ...SHORT, queue: QUEUE })
  expect(text(bandRows(s as any, NOCI, 140))).toContain('queue 44 = 30r 6b 3x')
  expect(detail(s as any, 140).join('\n')).toContain('queue 44 = 30 ready | 6 blocked | 3 epics')
  expect(detail(withHelper({ queue: { ...QUEUE, claimed: 2 } }) as any, 160).join('\n')).toContain('3 epics | 2 claimed')
  // the auto-parked token is gone: a stray `autoparked` in an old helper answer draws nothing
  const ap = { ...QUEUE, autoparked: 2 }
  expect(detail(withHelper({ queue: ap }) as any, 160).join('\n')).not.toContain('auto-parked')
  expect(text(bandRows(withHelper({ ...SHORT, queue: ap }) as any, NOCI, 140))).not.toMatch(/\b2a\b/)
  // a count of 1 reads singular for epics, 0 stays plural
  const one = detail(withHelper({ queue: { ...QUEUE, epic: 1, blocked: 0 } }) as any, 160).join('\n')
  expect(one).toContain('0 blocked | 1 epic')
  expect(text(bandRows(s as any, NOCI, 140))).not.toContain('claimed')
  expect(text(bandRows(s as any, NOCI, 140))).not.toContain('revisited')
  // the old marker-derived buckets are gone
  expect(detail(s as any, 140).join('\n')).not.toMatch(/decision|external/)
})

test('queue: autopilot holds are not in the queue cell (band or details); they show in AUTOPILOT', async () => {
  const hd = { ...QUEUE, apholds: 2, claimed: 1 }
  expect(text(bandRows(withHelper({ ...SHORT, queue: hd }) as any, NOCI, 160))).toContain('queue 44 = 30r 6b 3x 1c')
  expect(text(bandRows(withHelper({ ...SHORT, queue: hd }) as any, NOCI, 160))).not.toContain('hd')
  const lines = detailRows(withHelper({ autopilot: AP, queue: hd }) as any, DEFAULTS, 200, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
  expect(lines.join('\n')).toContain('queue 44 = 30 ready | 6 blocked | 3 epics | 1 claimed')
  expect(sect(lines, 'QUEUE')).not.toMatch(/hold/)
  expect(sect(lines, 'AUTOPILOT')).toContain('2 held by autopilot')
  // the helper's count is clamped; a missing or non-numeric one is 0
  expect(parseHelper(JSON.stringify({ ...BASE, queue: { ...QUEUE, apholds: 4.7 } }))!.queue!.apholds).toBe(4)
  expect(parseHelper(JSON.stringify({ ...BASE, queue: { ...QUEUE, apholds: 'x' } }))!.queue!.apholds).toBe(0)
})

test('queue: no queue, no cell and no line; a tight band shrinks it to ready/total before dropping it', async () => {
  expect(text(bandRows(withHelper({ queue: null }) as any, NOCI, 140))).not.toContain('queue')
  expect(detail(withHelper({ queue: null }) as any, 140).join('\n')).not.toContain('queue')
  const tight = text(bandRows(withHelper({ ...SHORT, task_title: '', queue: QUEUE, ledger: null, ci: null }) as any, NOCI, 34))
  expect(tight).toMatch(/queue (30\/44|44 = 30r)/)
})

// --- queue maxima: removed (owner decision d190, the TREND one-liner replaces them) ---

test('queue max: a helper answer that still carries `hwm` draws no maxima, in the band or in details, and parseHelper drops it', async () => {
  const q = { ...QUEUE, hwm: { lm: 61, lw: 74, tw: 83 } }
  expect((parseHelper(JSON.stringify({ ...BASE, queue: q }))!.queue as any).hwm).toBeUndefined()
  const s = withHelper({ ...SHORT, queue: q })
  expect(text(bandRows(s as any, NOCI, 160))).toContain('queue 44 = 30r 6b 3x')
  expect(text(bandRows(s as any, NOCI, 160))).not.toMatch(/max|last month|last week|this week/)
  expect(detail(s as any, 200).join('\n')).toContain('queue 44 = 30 ready | 6 blocked | 3 epics')
  expect(detail(s as any, 200).join('\n')).not.toMatch(/max|last month|last week|this week/)
})

// --- autopilot 24h progress and lifetime average -------------------------------------------------
const STATS = { has_history: true, approx: false, merged_24h: 8, cycles_24h: 26, avg_merged_24h: 5.2, trend: 'up' }
const apStats = (over = {}) => withHelper({ autopilot: { ...AP, stats: { ...STATS, ...over } } })

test('AP stats: parseHelper keeps a valid stats object; absent or malformed is null', async () => {
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: STATS } }))?.autopilot?.stats).toEqual(STATS)
  expect(parseHelper(HELPER_AP)?.autopilot?.stats).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: [1] } }))?.autopilot?.stats).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, stats: { trend: 'sideways', merged_24h: 'x' } } }))?.autopilot?.stats).toEqual({ has_history: false, approx: false, merged_24h: 0, cycles_24h: 0, avg_merged_24h: 0, trend: 'flat' })
})

test('AP stats: the wide band shows a labeled last-24h merged/loops, the arrow right after the 24h count, and the spelled-out average', async () => {
  const wide = text(bandRows(apStats(), NOCI, 200))
  expect(wide).toContain('AP 2/6h 3 loops ✓2 merged │ last 24h: 8 merged ▲ / 26 loops · average 5.2/day │ ctx')
})

// The arrow: green up when the last 24 h beat the average, red down when slower, none when equal or when there is nothing to compare.
const arrowSeg = (rows: Seg[][]) => rows.flat().find(x => x.text.includes('▲') || x.text.includes('▼'))

test('AP stats: 24h above the average shows a green up arrow next to the 24h count', async () => {
  const rows = bandRows(apStats({ merged_24h: 8, avg_merged_24h: 5.2, trend: 'up' }), NOCI, 200)
  expect(arrowSeg(rows)).toMatchObject({ text: ' ▲', color: 'success' })
  expect(text(rows)).toContain('last 24h: 8 merged ▲ / 26 loops')
})

test('AP stats: 24h below the average shows a red down arrow (the error token, not yellow)', async () => {
  const rows = bandRows(apStats({ merged_24h: 3, avg_merged_24h: 5.2, trend: 'down' }), NOCI, 200)
  expect(arrowSeg(rows)).toMatchObject({ text: ' ▼', color: 'error' })
  expect(text(rows)).toContain('last 24h: 3 merged ▼ / 26 loops · average 5.2/day')
})

test('AP stats: 24h equal to the average (flat) shows no arrow and no `=`', async () => {
  const rows = bandRows(apStats({ merged_24h: 5, avg_merged_24h: 5.0, trend: 'flat' }), NOCI, 200)
  expect(arrowSeg(rows)).toBeUndefined()
  expect(text(rows)).toContain('last 24h: 5 merged / 26 loops · average 5.0/day')
  expect(text(rows)).not.toMatch(/[▲▼=]/)
})

test('AP stats: no stats object (no average / no history anywhere) shows no cell and no arrow', async () => {
  const rows = bandRows(withHelper({ autopilot: AP }), NOCI, 200)
  expect(arrowSeg(rows)).toBeUndefined()
  expect(text(rows)).not.toMatch(/24h|avg|average/)
})

test('AP stats: the arrow is a theme token plus a glyph, so NO_COLOR drops only the colour and the glyph stays in every width form', async () => {
  for (const cols of [200, 100, 90, 80, 60, 48]) {
    const rows = bandRows(apStats({ trend: 'up' }), NOCI, cols)
    const seg = arrowSeg(rows)!
    expect(['success', 'error']).toContain(seg.color)
    // What a colour-less terminal draws: the text without any colour, the glyph intact.
    expect(rows.flat().map(x => x.text).join('')).toContain('▲')
  }
  expect(arrowSeg(bandRows(apStats({ trend: 'down' }), NOCI, 48))).toMatchObject({ color: 'error' })
})

test('AP stats: with no history the 24h count still shows; `~` marks an estimate from the calendar-day counters (no arrow), none marks an exact zero', async () => {
  const noHist = { has_history: false, cycles_24h: 0, merged_24h: 0, trend: 'down' }
  const exact = text(bandRows(apStats(noHist), NOCI, 200))
  expect(exact).toContain('last 24h: 0 merged ▼ / 0 loops · average 5.2/day')
  const approx = bandRows(apStats({ ...noHist, approx: true, merged_24h: 3, cycles_24h: 4 }), NOCI, 200)
  expect(text(approx)).toContain('last 24h: ~3 merged / 4 loops · average 5.2/day')
  expect(text(bandRows(apStats({ ...noHist, approx: true, merged_24h: 9, trend: 'up' }), NOCI, 60))).toContain('24h ✓~9/0L avg 5.2/d')
  // an estimate carries no arrow whatever the trend says
  expect(arrowSeg(bandRows(apStats({ ...noHist, approx: true, merged_24h: 9, trend: 'up' }), NOCI, 200))).toBeUndefined()
  expect(arrowSeg(approx)).toBeUndefined()
})

test('AP stats: the 24h merged count and the average survive 100-140 columns; the ctx bar shrinks first', async () => {
  const at = (cols: number) => text(bandRows(apStats(), NOCI, cols))
  for (const cols of [100, 110, 120, 130, 140]) {
    expect(at(cols)).toMatch(/24h: 8 merged/)
    expect(at(cols)).toContain('average 5.2/day')
  }
  expect(at(120)).toContain('last 24h: 8 merged ▲ / 26 loops · average 5.2/day')
  expect(at(110)).not.toContain('▓')
  expect(at(100)).toContain('│ last 24h: 8 merged ▲ / 26 loops · average 5.2/day │')
  expect(at(90)).toContain('│ 24h: 8 merged ▲/26 loops · average 5.2/day │')
})

test('AP stats: narrow rows shrink the stats late and keep `avg` only in the narrowest forms; the row always fits', async () => {
  const at = (cols: number) => text(bandRows(apStats(), NOCI, cols))
  expect(at(80)).toContain('24h: ✓8▲/26L average 5.2/d')
  expect(at(60)).toContain('24h ✓8▲/26L avg 5.2/d')
  expect(at(60)).not.toContain('average')
  for (const cols of [30, 50, 70, 90, 110, 140, 200]) expect(at(cols).length).toBeLessThanOrEqual(cols)
  expect(at(48)).toContain('AP')
  expect(at(48)).toContain('24h ✓8▲')
  expect(text(bandRows(apStats(), { ...NOCI, fields: ['ap'] }, 69))).toContain('24h ✓8▲/26L avg 5.2/d')
})

test('AP stats: `ap` switched off hides the stats too; details show them on the AP line', async () => {
  expect(text(bandRows(apStats(), { ...NOCI, fields: ['ci'] }, 200))).not.toContain('24h')
  const line = apPart(detailRows(apStats() as any, DEFAULTS, 400).map(r => r.map(x => x.text).join('')))
  expect(line).toContain('last 24h: 8 merged ▲ / 26 loops · average 5.2/day')
})

test('AP stats: the details WORK row keeps the 24h cell in full and, when narrow, wraps it (never abbreviated, never cut)', async () => {
  const full = { ...AP, next_wake_at: NOW + 720, stats: STATS }
  const rows = (cols: number) => detailRows(withHelper({ autopilot: full }) as any, DEFAULTS, cols, NOW * 1000).map(r => r.map(x => x.text).join(''))
  const wide = squash(apPart(rows(400)))
  expect(wide).toContain(squash('last 24h: 8 merged ▲ / 26 loops · average 5.2/day'))
  for (const cols of [200, 140, 100, 80, 60, 40]) {
    expect(squash(apPart(rows(cols))), `at ${cols}`).toBe(wide)
    for (const l of rows(cols)) expect(l.length).toBeLessThanOrEqual(cols - 2)
    expect(rows(cols).join('\n')).not.toMatch(/…|24h: ✓|avg|\bnext in\b/)
  }
})

// --- CI top row: detail view, highlight, NO_COLOR ---

test('details: BUILD (CI first), then CLONE, WORK, QUEUE with the queue on its own row, SESSION first', async () => {
  const q = { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 }
  const lines = detail(withHelper({ ...fullSnap().helper, queue: q }), 400, CI)
  expect(lines.map(l => l.slice(0, 9).trim())).toEqual(['SESSION', 'CLONE', 'BUILD', 'AUTOPILOT', 'WORK', 'QUEUE'])
  expect(sect(lines, 'BUILD')).toMatch(/^CI \(nightly\.yml\) ✓ passing \d\d-\d\d \(2h ago\)$/)
  expect(sect(lines, 'CLONE')).toContain('acme/widgets')
  expect(sect(lines, 'AUTOPILOT') + sect(lines, 'WORK')).not.toContain('queue')
  expect(sect(lines, 'QUEUE')).toBe('queue 44 = 30 ready | 6 blocked | 3 epics')
  expect(lines.filter(l => l.includes('queue')).length).toBe(1)
  expect(lines.filter(l => l.includes('CI')).length).toBe(1)
  for (let cols = 200; cols >= 22; cols--) for (const l of detail(withHelper({ ...fullSnap().helper, queue: q }), cols, CI)) expect(l.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
})

// --- details: the AP line (AP, 24h average) and the queue on its own line right after it ---

const AP_Q = { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 }
const QLINE = 'queue 44 = 30 ready | 6 blocked | 3 epics'
const linesOf = (helper: object, cols = 240, now = DETAIL_NOW) => detailRows(withHelper({ ci: null, ...helper }) as any, DEFAULTS, cols, now).map(r => r.map(x => x.text).join(''))
const apLineOf = (helper: object, cols = 400) => apPart(linesOf(helper, cols))
const WAKE = Math.floor(DETAIL_NOW / 1000) + 720

test('details: AP on + queue data: AP (WORK) and queue (QUEUE) are two separate consecutive rows, no `||`', async () => {
  const lines = linesOf({ autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, queue: AP_Q }, 400)
  expect(apPart(lines)).toMatch(/^AP on 2\/6h 3 loops ✓2 merged last 24h: 8 merged ▲ \/ 26 loops · average 5\.2\/day$/)
  const at = lines.findIndex(l => l.startsWith('WORK '))
  expect(lines[at + 1]).toBe('QUEUE     ' + QLINE)
  expect(lines.join('\n')).not.toContain('||')
  expect(lines.filter(l => l.includes('queue')).length).toBe(1)
  // the queue row keeps its colours: ready is green, the other counts plain, zero counts dim
  const rows = detailRows(withHelper({ ci: null, autopilot: { ...AP, next_wake_at: WAKE }, queue: { ...AP_Q, epic: 0 } }) as any, DEFAULTS, 400, DETAIL_NOW)
  const q = rows.find(r => r[0].text.startsWith('QUEUE'))!
  expect(q.find(x => x.text === '30 ready')?.color).toBe('success')
  expect(q.find(x => x.text === '0 epics')?.dim).toBe(true)
  expect(q.find(x => x.text === '6 blocked')?.dim).toBe(false)
})

test('details: the QUEUE row follows the WORK row in every AP state (due, paused, running, no stats, AP off) and is omitted without queue data', async () => {
  const due = linesOf({ autopilot: { ...AP, next_wake_at: Math.floor(DETAIL_NOW / 1000) - 5, stats: STATS }, queue: AP_Q }, 400)
  expect(apPart(due)).toBe('AP on 2/6h 3 loops ✓2 merged last 24h: 8 merged ▲ / 26 loops · average 5.2/day') // two lines (status, progress), joined by sect
  expect(sections(due)['AUTOPILOT']).toEqual(['AP on 2/6h 3 loops ✓2 merged', 'last 24h: 8 merged ▲ / 26 loops · average 5.2/day'])
  expect(sect(due, 'QUEUE')).toBe(QLINE)
  const at = (helper: object) => { const l = linesOf(helper, 400); return [apPart(l), sect(l, 'QUEUE'), l.findIndex(x => x.startsWith('QUEUE')) - l.findIndex(x => x.startsWith('WORK '))] }
  expect(at({ autopilot: AP, queue: AP_Q })).toEqual(['AP on 2/6h 3 loops ✓2 merged', QLINE, 1])
  expect(at({ autopilot: { ...AP, status: 'paused', prefix: '[p]', next_wake_at: WAKE }, queue: AP_Q })).toEqual(['AP ⏸ paused 2/6h 3 loops ✓2 merged', QLINE, 1])
  expect(at({ autopilot: { ...AP, busy: true, next_wake_at: WAKE }, queue: AP_Q })).toEqual(['AP on 2/6h 3 loops ✓2 merged │ running', QLINE, 1])
  expect(at({ autopilot: null, queue: AP_Q })).toEqual(['AP off', QLINE, 1])
  // no queue data: no queue row and no empty row
  const none = linesOf({ autopilot: { ...AP, next_wake_at: WAKE, stats: STATS } }, 400)
  expect(none.join('\n')).not.toContain('queue')
  expect(none.every(l => l.trim() !== '')).toBe(true)
  expect(apLineOf({ autopilot: null })).toBe('AP off')
  expect(detailRows(EMPTY as any, DEFAULTS, 240, DETAIL_NOW).map(r => r.map(x => x.text).join('')).join('\n')).not.toContain('queue')
})

test('details: the queue row never abbreviates: narrow widths wrap it; the band keeps r/b/x', async () => {
  const helper = { autopilot: { ...AP, next_wake_at: WAKE, stats: STATS }, queue: AP_Q }
  for (let cols = 240; cols >= 22; cols--) {
    const lines = linesOf(helper, cols)
    for (const l of lines) expect(l.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    const q = sections(lines).QUEUE
    expect(q).toBeDefined()
    // wrapped at its spaces, never cut: the same words in full, so no r/h/x or `30/44` form ever appears
    expect(squash(q!.join(''))).toBe(squash(QLINE))
    expect(lines.join('\n')).not.toContain('…')
  }
  expect(sections(linesOf(helper, 60)).QUEUE).toEqual(['queue 44 = 30 ready | 6 blocked | 3 epics'])
  expect(sections(linesOf(helper, 40)).QUEUE).toEqual(['queue 44 = 30 ready | 6', 'blocked | 3 epics'])
  // the single-line band is where the short forms live
  expect(text(bandRows(withHelper({ ...helper, ci: null }) as any, NOCI, 240))).toContain('queue 44 = 30r 6b 3x')
  expect(text(bandRows(withHelper({ ...helper, ci: null }) as any, NOCI, 90))).not.toContain('30 ready')
})

// --- no next-loop text (d191); beyond a grace a red stalled cell is the only schedule signal ---

const STALL_NOW = new Date(2026, 10, 2, 12, 0, 0).getTime()
const secs = (n: number) => Math.floor(STALL_NOW / 1000) + n
const stallLines = (ap: object, cols = 400) => apPart(linesOf({ autopilot: { ...AP, ...ap }, queue: AP_Q }, cols, STALL_NOW))

test('stalled: not yet due and due within the 10-minute grace show nothing (no next-loop text)', async () => {
  expect(stallLines({ next_wake_at: secs(300) })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(stallLines({ next_wake_at: secs(-1) })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(stallLines({ next_wake_at: secs(-STALL_GRACE_SEC) })).toBe('AP on 2/6h 3 loops ✓2 merged') // exactly the grace: still due
})

test('stalled: beyond the grace the details row shows `stalled <span>` in red, how late (minutes, hours, days), no next-loop text', async () => {
  const at = (late: number) => stallLines({ next_wake_at: secs(-late) })
  expect(at(STALL_GRACE_SEC + 1)).toBe('AP on 2/6h 3 loops ✓2 merged │ stalled 10m')
  expect(at(25 * 60)).toBe('AP on 2/6h 3 loops ✓2 merged │ stalled 25m')
  expect(at(3 * 3600 + 5 * 60)).toBe('AP on 2/6h 3 loops ✓2 merged │ stalled 3h 5m')
  expect(at(2 * 86400 + 16 * 3600 + 120)).toBe('AP on 2/6h 3 loops ✓2 merged │ stalled 2d 16h')
  expect(at(2 * 86400)).toBe('AP on 2/6h 3 loops ✓2 merged │ stalled 2d')
  expect(at(2 * 86400)).not.toMatch(/due$|\d\d:\d\d|\(in /)
  const rows = detailRows(withHelper({ ci: null, autopilot: { ...AP, next_wake_at: secs(-86400) } }) as any, DEFAULTS, 200, STALL_NOW)
  expect(rows.flat().find(x => x.text.startsWith('stalled'))?.color).toBe('error')
  // the queue row still follows
  expect(sect(linesOf({ autopilot: { ...AP, next_wake_at: secs(-86400) }, queue: AP_Q }, 400, STALL_NOW), 'QUEUE')).toBe(QLINE)
})

test('stalled: paused and a running cycle are unaffected by how old the stored wake time is', async () => {
  const old = secs(-3 * 86400)
  expect(stallLines({ next_wake_at: old, status: 'paused', prefix: '[p]' })).toBe('AP ⏸ paused 2/6h 3 loops ✓2 merged')
  expect(stallLines({ next_wake_at: old, busy: true })).toBe('AP on 2/6h 3 loops ✓2 merged │ running')
  expect(stallLines({ next_wake_at: 0 })).toBe('AP on 2/6h 3 loops ✓2 merged')
  expect(text(bandRows(withHelper({ autopilot: { ...AP, next_wake_at: old, status: 'paused', prefix: '[p]' } }) as any, NOCI, 200, STALL_NOW))).not.toContain('stalled')
  expect(text(bandRows(withHelper({ autopilot: { ...AP, next_wake_at: old, busy: true } }) as any, NOCI, 200, STALL_NOW))).not.toContain('stalled')
})

test('stalled: a wake less than a second away shows nothing; the band drops the stalled cell after the version', async () => {
  const wake = secs(0) // wake at the whole second, `nowMs` half a second before it
  const line = apPart(linesOf({ autopilot: { ...AP, next_wake_at: wake }, queue: AP_Q }, 400, STALL_NOW - 500))
  expect(line).toBe('AP on 2/6h 3 loops ✓2 merged')
  // drop order on the band: ver goes before stalled, so whenever the version shows the stalled cell shows too
  const snap = withHelper({ autopilot: { ...AP, next_wake_at: secs(-2 * 86400) }, plugin: { installed: '5.2.0', latest: '5.2.0' } })
  let sawStalledAlone = false
  for (let cols = 240; cols >= 22; cols--) {
    const t = text(bandRows(snap as any, NOCI, cols, STALL_NOW))
    if (t.includes('ccxp')) expect(t).toContain('stalled 2d')
    if (t.includes('stalled 2d') && !t.includes('ccxp')) sawStalledAlone = true
  }
  expect(sawStalledAlone).toBe(true)
})

test('stalled: formatSpan and stalledFor; the single-line band shows a short red `stalled 2d` only beyond the grace', async () => {
  expect([formatSpan(59, true), formatSpan(600, true), formatSpan(3900, true), formatSpan(7200, true), formatSpan(2 * 86400 + 16 * 3600, true), formatSpan(2 * 86400 + 16 * 3600, false), formatSpan(3900, false)]).toEqual(['0m', '10m', '1h 5m', '2h', '2d 16h', '2d', '1h'])
  expect(stalledFor({ ...AP, next_wake_at: secs(-STALL_GRACE_SEC) } as any, STALL_NOW)).toBe(0)
  expect(stalledFor({ ...AP, next_wake_at: secs(-STALL_GRACE_SEC - 1) } as any, STALL_NOW)).toBe(STALL_GRACE_SEC + 1)
  const band = (ap: object, cols = 200) => bandRows(withHelper({ autopilot: { ...AP, ...ap } }) as any, NOCI, cols, STALL_NOW)
  expect(text(band({ next_wake_at: secs(-2 * 86400 - 16 * 3600) }))).toContain('AP 2/6h 3 loops ✓2 merged │ stalled 2d │')
  expect(band({ next_wake_at: secs(-2 * 86400) }).flat().find(x => x.text.startsWith('stalled'))).toEqual({ text: 'stalled 2d', color: 'error', bold: true })
  expect(text(band({ next_wake_at: secs(-120) }))).not.toContain('stalled')
  expect(text(band({ next_wake_at: secs(300) }))).not.toContain('stalled')
  expect(text(band({ next_wake_at: secs(-STALL_GRACE_SEC - 60) }))).toContain('stalled 11m')
  for (const cols of [200, 140, 100, 80, 60, 40, 30]) for (const r of band({ next_wake_at: secs(-86400) }, cols)) expect(r.map(x => x.text).join('').length).toBeLessThanOrEqual(Math.max(20, cols - 2))
})

test('details: a red CI cell is flagged for highlight (only the cell, not its label or the nightly beside it); a green one is not; no `ci` means no CI cell', async () => {
  const helper = { ...fullSnap().helper, nightly: { red: 1, green: 2, strip: '+-++.-+' } }
  const red = detailRows(withHelper({ ...helper, ci: { state: 'failing', at: RUN_AT } }) as any, CI, 140, DETAIL_NOW)
  const build = red.find(r => r[0].text.startsWith('BUILD'))!
  expect(build[0].alert).toBeFalsy() // the label
  const ciSegs = build.slice(1, build.findIndex(x => x.text.startsWith('nightly')))
  expect(ciSegs.length).toBeGreaterThan(1)
  expect(ciSegs.filter(x => x.text.trim() !== '' && x.text !== ' │ ').every(x => x.alert)).toBe(true)
  expect(build.filter(x => x.text.startsWith('nightly') || x.text.includes('green')).some(x => x.alert)).toBe(false)
  expect(red.filter(r => r !== build).some(r => r.some(x => x.alert))).toBe(false)
  expect(isAlertRow(build)).toBe(true)
  expect(detailRows(withHelper({ ...helper, ci: { state: 'passing', at: RUN_AT } }) as any, CI, 140, DETAIL_NOW).some(r => r.some(x => x.alert))).toBe(false)
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

// --- queue source (T20261104-420419, default flipped by T20261109-338243): the default branch (default) or the working tree (opt-in) ---

test('queue source: config parses {source} or a bare string; unknown means unset; a project value replaces the user value like ci', async () => {
  expect(parseConfigText('{"queue": {"source": "default-branch"}}').queue).toEqual({ source: 'default-branch' })
  expect(parseConfigText('{"queue": "Default-Branch"}').queue).toEqual({ source: 'default-branch' })
  expect(parseConfigText('{"queue": {"source": "working-tree"}}').queue).toEqual({ source: 'working-tree' })
  for (const bad of ['{"queue": {"source": "nope"}}', '{"queue": 3}', '{"queue": null}', '{"queue": {}}']) expect(parseConfigText(bad).queue).toBeUndefined()
  expect(mergeConfig({}, {}).queue).toBeUndefined()
  expect(mergeConfig(parseConfigText('{"queue": {"source": "default-branch"}}'), {}).queue).toEqual({ source: 'default-branch' })
  expect(mergeConfig(parseConfigText('{"queue": {"source": "default-branch"}}'), parseConfigText('{"queue": {"source": "working-tree"}}')).queue).toEqual({ source: 'working-tree' })
  // `"queue": null` in a project file drops a user-level source for that project (like `ci: null`): the HUD then uses the default, default-branch.
  expect(mergeConfig(parseConfigText('{"queue": {"source": "default-branch"}}'), parseConfigText('{"queue": null}')).queue).toBeUndefined()
})

test('queue source: withConfig writes the queue key and keeps the rest', async () => {
  expect(JSON.parse(withConfig('{"band": true}', { queue: { source: 'default-branch' } }))).toEqual({ band: true, queue: { source: 'default-branch' } })
  expect(JSON.parse(withConfig('{"queue": {"source": "default-branch"}}', { fillColor: 'blue' }))).toEqual({ queue: { source: 'default-branch' }, fillColor: 'blue' })
})

test('queue source: parseHelper keeps a plain branch name only for source default-branch, and a fallback flag', async () => {
  const q = (extra: object) => parseHelper(JSON.stringify({ ...BASE, queue: { ...QUEUE, ...extra } }))!.queue
  expect(q({ source: 'default-branch', branch: 'main' })).toEqual({ ...QUEUE, branch: 'main' })
  expect(q({ source: 'default-branch', branch: 'release/4.8' })!.branch).toBe('release/4.8')
  expect(q({ source: 'default-branch', branch: 'bad branch; ls' })).toEqual(QUEUE)
  expect(q({ source: 'working-tree', branch: 'main' })).toEqual(QUEUE)
  expect(q({ source: 'working-tree', fallback: true })).toEqual({ ...QUEUE, fallback: true })
})

test('queue source: the band reads queue@main, details queue (main); working tree is unchanged; a fallback is marked', async () => {
  const main = withHelper({ ...SHORT, queue: { ...QUEUE, branch: 'main' } })
  expect(text(bandRows(main as any, NOCI, 140))).toContain('queue@main 44 = 30r 6b 3x')
  expect(detail(main as any, 160).join('\n')).toContain('queue (main) 44 = 30 ready | 6 blocked | 3 epics')
  const wt = withHelper({ ...SHORT, queue: QUEUE })
  expect(text(bandRows(wt as any, NOCI, 140))).toContain('queue 44 = 30r 6b 3x')
  expect(text(bandRows(wt as any, NOCI, 140))).not.toContain('queue@')
  const fb = withHelper({ ...SHORT, queue: { ...QUEUE, fallback: true } })
  expect(text(bandRows(fb as any, NOCI, 140))).toContain('queue@wt 44 = 30r 6b 3x')
  expect(detail(fb as any, 200).join('\n')).toContain('queue (working tree, origin unavailable) 44 = 30 ready')
})

test('nightly cell: parseHelper keeps whole red and optional green counts and a 7-character +-. strip, hides anything else', async () => {
  const n = (x: unknown) => parseHelper(JSON.stringify({ ...BASE, nightly: x }))!.nightly
  expect(n({ red: 7, green: 16, strip: '++-++-+' })).toEqual({ red: 7, green: 16, strip: '++-++-+' })
  expect(n({ red: 7, strip: '++-++-+' })).toEqual({ red: 7, strip: '++-++-+' }) // an older cache without green still renders
  expect(n({ red: 0, green: 0, strip: '.....++' })).toEqual({ red: 0, green: 0, strip: '.....++' })
  expect(n({ red: 7, green: 'x', strip: '++-++-+' })).toEqual({ red: 7, strip: '++-++-+' })
  expect(n({ red: 7, green: -1, strip: '++-++-+' })).toEqual({ red: 7, strip: '++-++-+' })
  expect(n({ red: '7', strip: '++-++-+' })).toBeNull()
  expect(n({ red: 7, strip: '++-++-' })).toBeNull()
  expect(n({ red: 7, strip: '++x++-+' })).toBeNull()
  expect(n({ red: -1, strip: '++-++-+' })).toBeNull()
  expect(n(null)).toBeNull()
})

test('nightly cell: `nightly ++-++-+ · 30d: 16✓ 14✗`, coloured per character, hidden without data or when switched off', async () => {
  const rows = bandRows(withHelper({ nightly: { red: 14, green: 16, strip: '++-.+-+' } }) as any, NOCI, 200)
  expect(text(rows)).toContain('nightly ++-.+-+ · 30d: 16✓ 14✗')
  const segs = rows.flat()
  expect(segs.filter(x => x.text === '-').every(x => x.color === 'error')).toBe(true)
  expect(segs.filter(x => x.text === '+').every(x => x.color === 'success')).toBe(true)
  expect(segs.find(x => x.text === '.')!.dim).toBe(true)
  expect(segs.find(x => x.text === '14✗')!.color).toBe('error')
  expect(segs.find(x => x.text === '16✓')!.color).toBe('success')
  const zero = bandRows(withHelper({ nightly: { red: 0, green: 0, strip: '.......' } }) as any, NOCI, 200).flat()
  expect(zero.find(x => x.text === '0✓')!.dim).toBe(true)
  expect(zero.find(x => x.text === '0✗')!.dim).toBe(true)
  // an older cache without green: only the red count, as before
  expect(text(bandRows(withHelper({ nightly: { red: 7, strip: '++-.+-+' } }) as any, NOCI, 200))).toContain('nightly ++-.+-+ · 30d: 7✗')
  expect(text(bandRows(withHelper({ nightly: null }) as any, NOCI, 200))).not.toMatch(/nightly [-+.]/)
  expect(text(bandRows(withHelper({ nightly: { red: 7, green: 16, strip: '++-++-+' } }) as any, { ...NOCI, fields: ['repo'] }, 200))).not.toContain('nightly ++')
})

test('nightly cell: shrinks strip+counts, then strip alone, and is dropped only after the queue cell', async () => {
  const s = withHelper({ nightly: { red: 14, green: 16, strip: '++-++-+' }, queue: { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 } })
  const rows: string[] = []
  for (let w = 200; w >= 20; w -= 1) rows.push(text(bandRows(s as any, NOCI, w)))
  expect(rows.some(t => t.includes('nightly ++-++-+ 16✓ 14✗') && !t.includes('30d:'))).toBe(true)
  expect(rows.some(t => t.includes('nightly ++-++-+') && !t.includes('✓'))).toBe(true)
  // never dropped while the queue cell is still there; once the counts are gone the strip is
  for (const t of rows) if (t.includes('queue')) expect(t).toContain('nightly ++')
  // the counts stay as long as the strip is wider than the bare cell would be
  for (const t of rows) if (t.includes('✓')) expect(t).toContain('nightly ++-++-+')
  expect(rows.some(t => !t.includes('nightly ++') && !t.includes('queue'))).toBe(true)
})

test('details: the nightly cell spells out the 7-day strip and the 30-day green and red days', async () => {
  const lines = (n: object | null) => linesOf({ nightly: n }, 400)
  expect(sect(lines({ red: 14, green: 16, strip: '+-++.-+' }), 'BUILD')).toBe('nightly +-++.-+ (last 7 days) · last 30 days: 16 green ✓ / 14 red ✗')
  expect(sect(lines({ red: 14, strip: '+-++.-+' }), 'BUILD')).toBe('nightly +-++.-+ (last 7 days) · last 30 days: 14 red ✗')
  expect(lines(null).join('\n')).not.toMatch(/nightly [-+.]{7}/)
  const segs = detailRows(withHelper({ ci: null, nightly: { red: 14, green: 16, strip: '+-++.-+' } }) as any, DEFAULTS, 240, DETAIL_NOW).flat()
  expect(segs.find(x => x.text === '16 green ✓')!.color).toBe('success')
  expect(segs.find(x => x.text === '14 red ✗')!.color).toBe('error')
})

test('details: the nightly cell sits right after the CI cell in the BUILD row (first when there is no CI), never in the queue row', async () => {
  const q = { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 0 }
  const helper = { ...fullSnap().helper, queue: q, nightly: { red: 14, green: 16, strip: '+-++.-+' } }
  const ciOn = detail(withHelper(helper), 400, CI)
  expect(sect(ciOn, 'BUILD')).toMatch(/^CI \(nightly\.yml\).* │ nightly \+-\+\+\.-\+ \(last 7 days\) · last 30 days: 16 green ✓ \/ 14 red ✗$/)
  expect(ciOn.filter(l => /nightly [-+.]{7}/.test(l)).length).toBe(1)
  expect(sect(ciOn, 'QUEUE')).not.toMatch(/nightly [-+.]{7}/)
  const noCi = detail(withHelper({ ...helper, ci: null }), 400, NOCI)
  expect(sect(noCi, 'BUILD')).toMatch(/^nightly /)
})

// --- /hud details is a SUPERSET of /hud: every cell the band can show has a counterpart in details ---
// A new Field (or band-only cell) added without a details counterpart fails here, so cells cannot be forgotten.
const SUPERSET_MARK: Record<string, RegExp> = {
  repo: /acme\/widgets @ /,
  branch: /t20261021-354035-decouple/, // the branch rides on the repo line
  task: /T20261021-354035 /,
  ap: /AP on /,
  apstats: /last 24h: \d+ merged/,
  stall: /stalled/,
  ctx: /context \d+% left/,
  jobs: /READY|WORKING/,
  queue: /queue \d+ = /,
  nightly: /nightly [-+.]{7}.*last 30 days: \d+ green ✓ \/ \d+ red ✗/,
  issues: /issues \d+ open \| \d+ not delivered \| max open \d+ in 180 days/,
  bus: /bus 2 unread notes · newest from home/,
  ci: /CI \(/,
  rate: /\d+% left · .*reset (\w{3} )?\d\d:\d\d/,
  lastat: /you \d/,
  ver: /ccxp \d/,
  stale: /stale/,
}

test('details is a superset of the band: every band cell has a details counterpart', async () => {
  const stalled = Math.floor(DETAIL_NOW / 1000) - 86400
  const s = {
    ...fullSnap({ rateUsed: 40, rateResetsAt: Math.floor(DETAIL_NOW / 1000) + 3600, stale: true }),
  } as any
  s.helper = {
    ...s.helper,
    autopilot: { ...AP, next_wake_at: stalled, stats: STATS },
    queue: AP_Q,
    nightly: { red: 14, green: 16, strip: '+-++.-+' },
    issues: { open: 12, undelivered: 7, hwm: { d180: 18, d30: 15, d7: 12 } },
    bus: { unread: 2, from: 'home' },
    plugin: PLUGIN_NEW,
    ci: { state: 'passing', at: Math.floor(DETAIL_NOW / 1000) - 7200 },
  }
  const cfgAll = { ...CI, fields: [...ALL_FIELDS] }
  const det = detailRows(s, cfgAll, 400, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
  // The band's own cell ids, in both modes, must all be covered by a marker (a new one has to be added above).
  const band = (snapOver: any) => bandRows(snapOver, cfgAll, 400, DETAIL_NOW)
  const bandIds = new Set<string>()
  const apOff = { ...s, helper: { ...s.helper, autopilot: null } }
  for (const f of ALL_FIELDS) bandIds.add(f)
  for (const f of ['apstats', 'stall', 'ver', 'stale']) bandIds.add(f)
  for (const id of bandIds) {
    expect(SUPERSET_MARK[id], `no details marker registered for band cell "${id}"`).toBeDefined()
    expect(det.some(l => SUPERSET_MARK[id].test(l)), `/hud details lacks the "${id}" cell`).toBe(true)
  }
  // And the band really does draw these cells with this fixture (so the check above is not vacuous).
  const bandText = text(band(s)) + '\n' + text(band(apOff))
  for (const w of ['AP ', 'last 24h', 'queue', 'nightly +-++.-+', 'issues 12 open / 7 undelivered', 'bus 2 · home', 'ctx', 'stalled', 'stale', 'CI (', '60% left · reset ', 'acme/widgets', 'T20261021-354035']) expect(bandText, `band does not show ${w}`).toContain(w)
})

// --- the old details-on output, cell by cell (#1508): every one must still be in the sectioned layout ---
// INVENTORY (old line -> cell -> new section). Marker texts are what the OLD details view drew, verbatim.
//   0 CI                CI (workflow) state, run date, age, ETA, red run URL      -> BUILD
//   0b nightly          7-day strip, last 30 days green/red                       -> BUILD
//   0c issues           open, not delivered, max open 180/30/7 days               -> SUPPORT
//   0e bus              unread notes, newest from                                 -> SESSION
//   1 where             repo @ branch*, worktree, account, root, task, stale      -> CLONE
//   2 usage             context left, limit left + reset time (cost cell retired by the owner 2026-11-24) -> SESSION
//   3 jobs              READY/WORKING (N), parked N, last 24h jobs / average      -> WORK
//   4 autopilot         AP state/hours/loops/merged, running cycles / stalled, 24h merged/average -> AUTOPILOT
//   5 queue             queue (branch) N = ready | blocked | epics | claimed -> QUEUE
//   6 you               you HH:MM (age)                                           -> SESSION
//   6 version           ccxp X (latest | Y available)                             -> RELEASE
//   6 url               plugin GitHub URL                                         -> RELEASE
//   6 unreleased        N unreleased (subjects removed by owner decision, count kept) -> RELEASE
const OLD_CELLS: Array<[string, string, RegExp]> = [
  ['CI', 'BUILD', /CI \(nightly\.yml\) ✓ passing/],
  ['nightly', 'BUILD', /nightly \+-\+\+\.-\+ \(last 7 days\) · last 30 days: 16 green ✓ \/ 14 red ✗/],
  ['issues', 'SUPPORT', /issues 12 open \| 7 not delivered \| max open 18 in 180 days \/ 15 in 30 days \/ 12 in 7 days/],
  ['bus', 'SESSION', /bus 2 unread notes · newest from home/],
  ['repo', 'CLONE', /acme\/widgets @ t20261021-354035-decouple\*/],
  ['task', 'CLONE', /T20261021-354035 Decouple the nightly orchestrator/],
  ['stale', 'CLONE', /stale$/],
  ['context', 'SESSION', /context 64% left ▓▓▓▓▓▓░░░░/],
  ['limit', 'SESSION', /10% left · runs out in 26m · reset (\w{3} )?\d\d:\d\d/],
  ['you', 'SESSION', /you \d\d:\d\d \(5m ago\)/],
  ['jobs state', 'WORK', /WORKING \(2\)/],
  ['parked', 'WORK', /parked 2/],
  ['jobs 24h', 'WORK', /last 24h: jobs 8 ▲ \/ average 5\.2\/day/],
  ['AP', 'AUTOPILOT', /AP on 2\/6h 3 loops ✓2 merged/],
  ['stalled', 'AUTOPILOT', /stalled \d/],
  ['AP 24h', 'AUTOPILOT', /last 24h: 8 merged ▲ \/ 26 loops · average 5\.2\/day/],
  ['queue', 'QUEUE', /queue \(main\) 44 = 30 ready \| 6 blocked \| 3 epics \| 2 claimed/],
  ['version', 'RELEASE', /ccxp 5\.0\.0 \(5\.1\.0 available\)/],
  ['plugin URL', 'RELEASE', /https:\/\/github\.com\/Synx-Data-Labs\/ccxp-skills/],
  ['unreleased', 'RELEASE', /4 unreleased/],
]

test('details sections: every cell of the old details-on output is still present, in its section, at a wide and at a narrow terminal', async () => {
  const s = fullSnap({ rateUsed: 90, rateResetsAt: Math.floor(DETAIL_NOW / 1000) + 3600, stale: true }) as any
  s.helper = {
    ...s.helper,
    autopilot: { ...AP, next_wake_at: Math.floor(DETAIL_NOW / 1000) - 3600, stats: STATS },
    queue: { total: 44, ready: 30, blocked: 6, epic: 3, claimed: 2, branch: 'main' },
    nightly: { red: 14, green: 16, strip: '+-++.-+' },
    issues: { open: 12, undelivered: 7, hwm: { d180: 18, d30: 15, d7: 12 } },
    bus: { unread: 2, from: 'home' },
    plugin: { ...PLUGIN_NEW, unreleased: { count: 4 } },
    ci: { state: 'passing', at: Math.floor(DETAIL_NOW / 1000) - 7200 },
  }
  for (const cols of [400, 120, 60, 30]) {
    const secs_ = sections(detail(s, cols, CI))
    expect(Object.keys(secs_)).toEqual(DETAIL_LABELS)
    for (const [name, label, re] of OLD_CELLS) {
      // a cell may wrap across lines of its section (and the wrap eats blanks and separators): compare without them
      const flat = squash(secs_[label]!.join(''))
      const want = new RegExp(re.source.replace(/\\?[ │]/g, ''))
      expect(want.test(flat), `old cell "${name}" missing from ${label} at ${cols} columns`).toBe(true)
    }
    // Retired by the owner on 2026-11-24: the API-equivalent cost cell is gone from the details, in every section.
    expect(Object.values(secs_).flat().join('\n'), `the retired cost cell is back at ${cols} columns`).not.toMatch(/API-equivalent|cost \$/)
  }
})

// ---- CI ETA --------------------------------------------------------------------------------------
// Fixtures only: the helper's history logic is tested in tests/hud_ci.bats; here the display of its answer.

const START = new Date(2026, 9, 26, 3, 0).getTime() / 1000 // local 03:00
const hhmm = (sec: number) => {
  const d = new Date(sec * 1000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}
const H = 3600
const run = (eta?: object, state = 'running') => ({ state, at: START, ...(eta ? { eta } : {}) }) as any
const NARROW = { start: START, typ: 2 * H, min: 1.8 * H, max: 2.2 * H, n: 5 }
const WIDE = { start: START, typ: 4 * H, min: 2 * H, max: 9 * H, n: 5 }

test('ciEta: a narrow spread shows one time, the start plus the median, in local time', async () => {
  expect(ciEta(run(NARROW), (START + 600) * 1000)).toBe(`ETA ${hhmm(START + 2 * H)}`)
  expect(ciEta(run(NARROW), (START + 2 * H) * 1000)).toBe(`ETA ${hhmm(START + 2 * H)}`) // exactly on time is not overdue
})

test('ciEta: a wide spread (max - min > half the median) shows the fastest-slowest range', async () => {
  expect(ciEta(run(WIDE), (START + 1 * H) * 1000)).toBe(`ETA ${hhmm(START + 2 * H)}-${hhmm(START + 9 * H)}`)
  // past the median but within the slowest recent run: still the range, not overdue
  // past the fastest run (and the median) but within the slowest: still a range, not overdue; the first time is clamped to now, never a time that has already passed
  expect(ciEta(run(WIDE), (START + 6 * H) * 1000)).toBe(`ETA ${hhmm(START + 6 * H)}-${hhmm(START + 9 * H)}`)
})

test('ciEta: the spread boundary (max - min exactly half the median) is still narrow; now == start + typ is not overdue', async () => {
  const edge = { start: START, typ: 4 * H, min: 3 * H, max: 5 * H, n: 5 }
  expect(ciEta(run(edge), (START + 1 * H) * 1000)).toBe(`ETA ${hhmm(START + 4 * H)}`)
  expect(ciEta(run({ ...WIDE, max: 9 * H }), (START + 9 * H) * 1000)).toBe(`ETA ${hhmm(START + 9 * H)}-${hhmm(START + 9 * H)}`) // now == start + max is not overdue
})

test('ciEta: overdue shows the usual duration, never a negative time', async () => {
  expect(ciEta(run(NARROW), (START + 2 * H + 60) * 1000)).toBe('over usual (2h)')
  expect(ciEta(run(WIDE), (START + 9 * H + 60) * 1000)).toBe('over usual (4h)')
  expect(ciEta(run({ ...NARROW, typ: 45 * 60, min: 40 * 60, max: 50 * 60 }), (START + 3 * H) * 1000)).toBe('over usual (45m)')
  expect(ciEta(run({ start: START, typ: 3590, min: 3500, max: 3650, n: 5 }), (START + 2 * H) * 1000)).toBe('over usual (1h)') // 59.8 minutes reads 1h, not 60m
  expect(ciEta(run({ ...NARROW, typ: 4.5 * H, min: 4 * H, max: 5 * H }), (START + 6 * H) * 1000)).toBe('over usual (4.5h)')
})

test('ciEta: nothing when not running or without an eta; +Nd when it lands on another day', async () => {
  expect(ciEta(run(NARROW, 'passing'), START * 1000)).toBe('')
  expect(ciEta(run(), START * 1000)).toBe('')
  const night = new Date(2026, 9, 26, 22, 0).getTime() / 1000
  expect(ciEta(run({ start: night, typ: 5 * H, min: 4.8 * H, max: 5.2 * H, n: 5 }), (night + 60) * 1000)).toBe('ETA 03:00 +1d')
})

test('CI row: a running run with an eta carries it after the state; no eta, no extra text; it is dropped when narrow', async () => {
  const started = NOW - 600 // the band's clock is the real one, so the run started ten minutes ago
  const row = (eta: object | undefined, cols: number) => text(bandRows(withHelper({ ci: { ...run(eta), at: started } }), { ...CI, fields: ['ci'] }, cols).slice(0, 1))
  expect(row({ ...NARROW, start: started }, 140)).toMatch(/^CI \(nightly\.yml\) ◐ running ETA \d\d:\d\d(?: \+\dd)? \d\d-\d\d /)
  expect(row(undefined, 140)).toMatch(/^CI \(nightly\.yml\) ◐ running \d\d-\d\d /)
  expect(row({ ...NARROW, start: started }, 20)).not.toContain('ETA')
})

test('parseHelper: eta survives only on a running run with sane numbers and >= 3 runs of history', async () => {
  const eta = (ci: unknown) => parseHelper(JSON.stringify({ ...BASE, ci }))?.ci?.eta
  const good = { start: START, typ: 7200, min: 6000, max: 8000, n: 5 }
  expect(eta({ state: 'running', at: START, eta: good })).toEqual(good)
  expect(eta({ state: 'passing', at: START, eta: good })).toBeUndefined()
  expect(eta({ state: 'running', at: START, eta: { ...good, n: 2 } })).toBeUndefined()
  expect(eta({ state: 'running', at: START, eta: { ...good, typ: 'x' } })).toBeUndefined()
  expect(eta({ state: 'running', at: START, eta: { ...good, max: 1 } })).toBeUndefined()
  expect(eta({ state: 'running', at: START, eta: [1, 2, 3] })).toBeUndefined()
})

test('config: ci.eta is on unless explicitly false; withConfig keeps a hand-set false across /hud config', async () => {
  expect(parseCi({ workflow: 'w.yml' })).toEqual({ workflow: 'w.yml' })
  expect(parseCi({ workflow: 'w.yml', eta: true })).toEqual({ workflow: 'w.yml' })
  expect(parseCi({ workflow: 'w.yml', eta: false })).toEqual({ workflow: 'w.yml', eta: false })
  expect(parseCi({ workflow: 'w.yml', eta: 'no' })).toEqual({ workflow: 'w.yml' })
  const old = '{"ci": {"workflow": "old.yml", "eta": false}}'
  expect(JSON.parse(withConfig(old, { ci: { workflow: 'new.yml' } })).ci).toEqual({ workflow: 'new.yml', eta: false })
  expect(JSON.parse(withConfig(old, { ci: null })).ci).toBeNull()
  expect(JSON.parse(withConfig('{"ci": {"workflow": "old.yml"}}', { ci: { workflow: 'new.yml' } })).ci).toEqual({ workflow: 'new.yml' })
})

// ---- customer-issue stats cell (opt-in; the helper's lookups are tested in tests/hud_issues.bats) ----------------

test('issues: opt-in config, validated; the cell is off until a repo is set', async () => {
  expect(DEFAULTS.issues).toBeUndefined()
  expect(parseConfigText('{"issues": {"repo": "acme/support", "ghConfigDir": "~/.config/gh-acme"}}').issues).toEqual({ repo: 'acme/support', ghConfigDir: '~/.config/gh-acme' })
  expect(parseIssues('acme/support')).toEqual({ repo: 'acme/support' })
  for (const bad of [null, 5, {}, { repo: 'nope' }, { repo: 'a/b c' }, { repo: 'a/b;rm' }]) expect(parseIssues(bad)).toBeUndefined()
  expect(parseIssues({ repo: 'a/b', ghConfigDir: 'relative/dir' })).toEqual({ repo: 'a/b' })
  expect(parseIssues({ repo: 'a/b', ghConfigDir: '/x\ny' })).toEqual({ repo: 'a/b' })
  // no helper data (not configured): no cell
  expect(text(bandRows(withHelper({}), { ...DEFAULTS }, 200))).not.toContain('issues')
})

test('issues: parseHelper keeps whole counts, caps undelivered at open and nests the windows', async () => {
  const h = parseHelper(JSON.stringify({ ...BASE, issues: { open: 5, undelivered: 9, hwm: { d180: 1, d30: 2, d7: 3 } } }))!
  expect(h.issues).toEqual({ open: 5, undelivered: 5, hwm: { d180: 5, d30: 5, d7: 5 } })
  expect(parseHelper(JSON.stringify({ ...BASE, issues: { open: 'x', undelivered: 1 } }))!.issues).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, issues: { open: 4, undelivered: 2 } }))!.issues).toEqual({ open: 4, undelivered: 2 })
  expect(parseHelper(JSON.stringify({ ...BASE, issues: null }))!.issues).toBeNull()
})

test('issues: band forms shrink, details spell it out', async () => {
  const i = { open: 12, undelivered: 7, hwm: { d180: 18, d30: 15, d7: 12 } }
  const forms = issuesVariants(i, false).map(v => v.map(x => x.text).join(''))
  expect(forms).toEqual(['issues 12 open / 7 undelivered · max 18 180d / 15 30d / 12 7d', 'issues 12 open / 7 undeliv. · max 18/15/12', 'issues 12/7', 'issues 12'])
  expect(issuesVariants(i, true)[0].map(x => x.text).join('')).toBe('issues 12 open | 7 not delivered | max open 18 in 180 days / 15 in 30 days / 12 in 7 days')
  expect(issuesVariants({ open: 3, undelivered: 0 }, false).map(v => v.map(x => x.text).join(''))[0]).toBe('issues 3 open / 0 undelivered')
  // at the 180-day high the max block is warning-coloured
  expect(issuesVariants({ open: 18, undelivered: 1, hwm: { d180: 18, d30: 18, d7: 18 } }, false)[0].some(x => x.color === 'warning' && x.text.includes('max'))).toBe(true)
  const cfg = { ...DEFAULTS, issues: { repo: 'acme/support' } }
  expect(text(bandRows(withHelper({ issues: i }), cfg, 200))).toContain('issues 12 open / 7 undelivered')
  expect(text(bandRows(withHelper({ issues: i }), { ...cfg, fields: ['repo'] }, 200))).not.toContain('issues')
})

const RUN_URL = 'https://github.com/Synx-Data-Labs/synxdb-build-pipeline/actions/runs/123456'

test('CI url: a failing run keeps only an exact github.com run address; other states and addresses are dropped', async () => {
  const ci = (state: string, url: unknown) => parseHelper(JSON.stringify({ ...BASE, ci: { state, at: RUN_AT, url } }))!.ci
  expect(ci('failing', RUN_URL)).toEqual({ state: 'failing', at: RUN_AT, url: RUN_URL })
  expect(ci('passing', RUN_URL)).toEqual({ state: 'passing', at: RUN_AT })
  for (const bad of ['http://github.com/o/r/actions/runs/1', 'https://evil.example/o/r/actions/runs/1', `${RUN_URL}\u001b[31m`, `${RUN_URL}/x`, 5, null]) expect(ci('failing', bad)).toEqual({ state: 'failing', at: RUN_AT })
})

test('CI row: red ends with the run address (no scheme), it survives the workflow-name and state-word shrinks and is gone at 60 columns; green shows none; no other workflow is drawn (d143)', async () => {
  const row = (state: string, cols: number) => text(bandRows(withHelper({ ci: { state, at: RUN_AT, ...(state === 'failing' ? { url: RUN_URL } : {}) } }) as any, { ...CI, fields: ['ci'] }, cols).slice(0, 1))
  expect(row('failing', 200)).toMatch(/^CI \(nightly\.yml\) ✗ failing 10-26 \(\d+[dh] ago\) github\.com\/Synx-Data-Labs\/synxdb-build-pipeline\/actions\/runs\/123456$/)
  expect(row('failing', 60)).not.toContain('github.com')
  expect(row('passing', 200)).not.toContain('github.com')
  const rows = bandRows(withHelper({ ci: { state: 'failing', at: RUN_AT, url: RUN_URL }, redci: { n: 3, items: [{ wf: 'Upstream Sync', at: RUN_AT, repo: 'r' }] } }) as any, { ...CI, fields: ['ci'] }, 200)
  expect(text(rows)).not.toContain('unhandled')
  expect(text(rows)).not.toContain('Upstream Sync')
  for (const cols of [20, 30, 50, 80, 120, 200]) {
    for (const r of bandRows(withHelper({ ci: { state: 'failing', at: RUN_AT, url: RUN_URL } }) as any, CI, cols)) expect(r.reduce((n, x) => n + x.text.length, 0)).toBeLessThanOrEqual(Math.max(20, cols - 2))
  }
})

test('parseHelp / helpText: sections, aliases, index, unknown topic, missing source', () => {
  const src = 'intro\n## overview\nRead it.\n\n## redci | unhandled, red-ci\nFirst line.\nMore.\n'
  const t = parseHelp(src)
  expect(t.map(x => x.name)).toEqual(['overview', 'redci'])
  expect(findTopic(t, '/hud help Unhandled')?.name).toBe('redci')
  expect(helpText(src, '')).toContain('redci')
  expect(helpText(src, 'red-ci')).toContain('More.')
  expect(helpText(src, 'zzz')).toMatch(/no topic "zzz"/)
  expect(helpText(undefined, '')).toMatch(/could not be read/)
  expect(parseHelp(null)).toEqual([])
})

test('configReport: missing files mean defaults; values, sources, invalid and unknown keys are named', () => {
  const none = configReport({ paths: { user: '/u/ccxp-hud.json', project: '/p/ccxp-hud.json' }, env: { HOME: '/h' } })
  expect(none).toContain('/u/ccxp-hud.json  missing, so defaults apply')
  expect(none).toContain('/h/.claude/state/hud-ci')
  const some = configReport({
    paths: { user: '/u/c.json' },
    userText: '{"version": false, "pollSeconds": 30, "ci": {"workflow": "n.yml", "repo": "a/b"}, "bogus": 1, "ctxWarn": "x"}',
    env: { CLAUDE_CONFIG_DIR: '/cfg' },
  })
  expect(some).toMatch(/version\s+false; default true; user file/)
  expect(some).toMatch(/pollSeconds\s+30;/)
  expect(some).toContain('n.yml in a/b')
  expect(some).toContain('unknown keys (ignored): bogus')
  expect(some).toContain('invalid value (ignored, default used): ctxWarn')
  expect(some).toContain('/cfg/state/hud-ci')
  expect(configReport({ paths: { user: '/u/c.json' }, userText: '{nope', env: {} })).toContain('not valid JSON')
})

// ---- cross-account bus cell ----
const ANOW = Date.UTC(2026, 10, 20, 12, 0, 0)

test('parseHelper: bus keeps a positive whole count and a plain agent name; anything else is no cell or no name', async () => {
  const b = (x: unknown) => parseHelper(JSON.stringify({ ...BASE, bus: x }))!.bus
  expect(b({ unread: 2, from: 'home' })).toEqual({ unread: 2, from: 'home' })
  expect(b({ unread: 2.7, from: 'work-2' })).toEqual({ unread: 2, from: 'work-2' })
  expect(b({ unread: 5000, from: 'home' })!.unread).toBe(999)
  expect(b({ unread: 2, from: 'Home\u001b[31m' })).toEqual({ unread: 2, from: '' })
  expect(b({ unread: 0, from: 'home' })).toBeNull()
  expect(b({ unread: -1, from: 'home' })).toBeNull()
  expect(b({ unread: 'x' })).toBeNull()
  expect(b('home')).toBeNull()
  expect(b(null)).toBeNull()
  expect(parseHelper(JSON.stringify(BASE))!.bus).toBeNull()
})

test('bus cell: warning colour, narrows to the count, details spells it out', async () => {
  expect(busVariants({ unread: 2, from: 'home' })).toEqual([[{ text: 'bus 2 · home', color: 'warning' }], [{ text: 'bus 2', color: 'warning' }]])
  expect(busVariants({ unread: 1, from: '' })[0][0].text).toBe('bus 1')
  expect(busVariants({ unread: 1, from: 'home' }, true)[0][0].text).toBe('bus 1 unread note · newest from home')
  expect(busVariants({ unread: 3, from: 'home' }, true)[0][0].text).toBe('bus 3 unread notes · newest from home')
})

test('bus cell: drawn in the band when the helper has it, off with `bus` out of fields, absent without data', async () => {
  const s = withHelper({ ci: null, bus: { unread: 2, from: 'home' } }) as any
  expect(text(bandRows(s, NOCI, 200, ANOW))).toContain('bus 2 · home')
  expect(text(bandRows(s, { ...NOCI, fields: ['repo'] }, 200, ANOW))).not.toContain('bus 2')
  expect(text(bandRows(withHelper({ ci: null, bus: null }) as any, NOCI, 200, ANOW))).not.toContain('bus ')
})

test('bus cell: shrinks to the count in a narrow band, and is dropped before the band is cut', async () => {
  const s = withHelper({ ci: null, bus: { unread: 2, from: 'home' } }) as any
  const wide = text(bandRows(s, NOCI, 200, ANOW))
  expect(wide).toContain('bus 2 · home')
  let shrunk = false
  let dropped = false
  for (let w = 200; w >= 22; w--) {
    const t = text(bandRows(s, NOCI, w, ANOW))
    if (t.includes('bus 2') && !t.includes('bus 2 · home')) shrunk = true
    if (shrunk && !t.includes('bus')) dropped = true
  }
  expect(shrunk, 'bus never narrows to `bus 2`').toBe(true)
  expect(dropped, 'bus is never dropped as the band narrows').toBe(true)
})

// ---- AP max_dop cell (T20261124-239428) ----
const dopSnap = (apc: object | null, ap: object | null = {}) => withHelper({ autopilot: ap === null ? null : { ...AP, ...ap }, ap_config: apc }) as any
const CFG16 = { max_dop: 16, reserved_slots: 2, source: 'override', file: true }
const dopLine = (s: object) => (detail(s).find(l => l.startsWith('AUTOPILOT ')) ?? '').replace(/^AUTOPILOT\s+/, '')
const dopBand = (s: object, cols = 160) => text(bandRows(s as any, NOCI, cols))

test('parseHelper: ap_config is kept when well formed, null when absent or malformed', async () => {
  expect(parseHelper(JSON.stringify({ ...BASE, ap_config: CFG16 }))?.ap_config).toEqual(CFG16)
  expect(parseHelper(JSON.stringify({ ...BASE, ap_config: { max_dop: 8, reserved_slots: null, source: 'default', file: false } }))?.ap_config?.reserved_slots).toBeNull()
  for (const bad of [null, [], 'x', { max_dop: 0 }, { max_dop: 'a' }, {}]) expect(parseHelper(JSON.stringify({ ...BASE, ap_config: bad }))?.ap_config).toBeNull()
  expect(parseHelper(HELPER)?.ap_config).toBeNull()
})

test('parseHelper: busy_routine is kept, and falls back to busy_slots for a helper without the split', async () => {
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, busy_slots: 3, busy_routine: 2 } }))?.autopilot?.busy_routine).toBe(2)
  expect(parseHelper(JSON.stringify({ ...BASE, autopilot: { ...AP, busy_slots: 3 } }))?.autopilot?.busy_routine).toBe(3)
})

test('band: AP on shows `dop running/max_dop` (config present), neutral colour below the routine limit', async () => {
  const s = dopSnap(CFG16, { busy_slots: 8 })
  expect(dopBand(s)).toContain('dop 8/16')
  expect(bandRows(s, NOCI, 160)[0]!.find(g => g.text === 'dop 8/16')?.color).toBeUndefined()
  expect(dopBand(dopSnap({ ...CFG16, reserved_slots: null, max_dop: 8 }, {}))).toContain('dop 0/8') // idle, reserved key absent
})

test('band: warning colour at the routine limit (max_dop less reserved), also with the reserved key absent', async () => {
  const color = (s: object) => bandRows(s as any, NOCI, 160)[0]!.find(g => g.text.startsWith('dop '))?.color
  expect(color(dopSnap(CFG16, { busy_slots: 14 }))).toBe('warning') // 14 routine + 2 reserved: routine full
  expect(color(dopSnap(CFG16, { busy_slots: 13 }))).toBeUndefined()
  expect(color(dopSnap({ ...CFG16, reserved_slots: null }, { busy_slots: 16 }))).toBe('warning')
  expect(color(dopSnap({ ...CFG16, reserved_slots: null }, { busy_slots: 15 }))).toBeUndefined()
  expect(color(dopSnap({ ...CFG16, max_dop: 1, reserved_slots: null }, { busy_slots: 0 }))).toBeUndefined() // nothing running is never capped
  // urgent cycles run in the reserved slots and do not use up the routine limit (as `autopilot-state.sh routine-free`)
  expect(color(dopSnap(CFG16, { busy_slots: 14, busy_routine: 12 }))).toBeUndefined() // 12 routine + 2 urgent: 2 routine slots still free
  expect(color(dopSnap(CFG16, { busy_slots: 14, busy_routine: 14 }))).toBe('warning')
  expect(color(dopSnap(CFG16, { busy_slots: 16, busy_routine: 14 }))).toBe('warning')
  expect(color(dopSnap(CFG16, { busy_slots: 16, busy_routine: 10 }))).toBe('warning') // 10 routine + 6 urgent: every slot is taken, routine-free is 0
  expect(color(dopSnap({ max_dop: 6, reserved_slots: 2, source: 'override', file: true }, { busy_slots: 8, busy_routine: 0 }))).toBe('warning') // lowered under 8 urgent cycles
})

test('band: max_dop lowered below the running count (running 8, max_dop 6) reads 8/6 in warning colour', async () => {
  const s = dopSnap({ max_dop: 6, reserved_slots: null, source: 'override', file: true }, { busy_slots: 8 })
  const g = bandRows(s, NOCI, 160)[0]!.find(x => x.text.startsWith('dop '))
  expect(g).toEqual({ text: 'dop 8/6', color: 'warning' })
})

test('band: silent without a config answer, and with the autopilot off (the band shows no AP cell then)', async () => {
  expect(dopBand(dopSnap(null, {}))).not.toContain('dop ')
  expect(dopBand(dopSnap(CFG16, null))).not.toContain('dop ')
  expect(dopBand(dopSnap(CFG16, { prefix: '[s]', status: 'stopped' }))).not.toContain('dop ')
})

test('band: dop sits right after the AP cell and is the one cell this feature drops on a narrow row, AP stays', async () => {
  const s = dopSnap(CFG16, { busy_slots: 8, stats: { has_history: true, merged_24h: 8, cycles_24h: 26, avg_merged_24h: 5.2, trend: 'up' } })
  expect(dopBand(s, 200)).toMatch(/^AP [^│]*│ dop 8\/16 │ /)
  // shrinking order: dop is dropped after the AP cell has taken its shortest form and before the ctx cell goes
  const widths = [160, 120, 100, 90, 80, 70, 60, 50, 40].map(w => dopBand(s, w))
  const gone = widths.findIndex(t => !t.includes('dop '))
  expect(gone).toBeGreaterThan(0) // present while wide
  for (const t of widths.slice(gone)) expect(t).not.toContain('dop ') // once dropped, it stays dropped
  expect(widths[gone]).toContain('AP 2/6h 3L ✓2') // the AP cell is at its shortest form by then
})

test('details: AP line carries `max_dop 16 (14 routine + 2 reserved) · 8 running`; without reserved, max_dop alone', async () => {
  expect(dopLine(dopSnap(CFG16, { busy_slots: 8 }))).toMatch(/^AP on [^│]*│ max_dop 16 \(14 routine \+ 2 reserved\) · 8 running(?: │ |$)/)
  expect(detail(dopSnap({ ...CFG16, reserved_slots: null }, { busy_slots: 8 })).join('\n')).toContain('│ max_dop 16 · 8 running')
  expect(detail(dopSnap(CFG16, { busy_slots: 0 })).join('\n')).toContain('max_dop 16 (14 routine + 2 reserved) · 0 running')
})

test('details: running above a lowered max_dop is called out; warning colour at the routine limit', async () => {
  const rows = detailRows(dopSnap({ max_dop: 6, reserved_slots: 2, source: 'override', file: true }, { busy_slots: 8 }), NOCI, 200, DETAIL_NOW)
  const ap = rows.find(r => r.some(g => g.text.startsWith('max_dop')))!
  expect(ap.map(g => g.text).join('')).toContain('max_dop 6 (4 routine + 2 reserved) · 8 running (limit lowered)')
  expect(ap.find(g => g.text.includes('running'))?.color).toBe('warning')
})

test('details: AP off shows the configured max_dop dim only when a config exists; silent with none', async () => {
  expect(dopLine(dopSnap({ max_dop: 8, reserved_slots: null, source: 'override', file: true }, null))).toMatch(/^AP off │ max_dop 8(?: │ |$)/)
  expect(dopLine(dopSnap(null, null))).toMatch(/^AP off(?: │ WORKING| │ READY|$)/)
  expect(dopLine(dopSnap(null, null))).not.toContain('max_dop')
})

// ---- the weekly trend row (hud-trend.sh, T20261126-122285) ----

const TREND_ROWS = [
  { key: 'queue', label: 'Queue', short: 'Queue 172 ▇▇▆▆▅▅* -9', full: 'Queue   172 ▇▇▆▆▅▅*  -9 vs last wk   (in 14 / out 23)' },
  { key: 'support', label: 'Support', short: 'Support 5 ▃▅▆▄▃▂* -1', full: 'Support   5 ▃▅▆▄▃▂*  -1 vs last wk   (opened 2 / delivered 3)' },
  { key: 'ap', label: 'AP', short: 'AP 32 ▂▃▅▆▇▅* merged/wk', full: 'AP       32 ▂▃▅▆▇▅*  merged/wk       (holds 52 ▅▆▆▇▇▇* up)' },
]
const trendSnap = (rows: object[] = TREND_ROWS) => snap({}, JSON.stringify({ ...BASE, trend: { rows } }))

test('trend: the band gets its own bottom row with the three short forms; wide terminals show all of them', async () => {
  const rows = bandRows(trendSnap() as any, NOCI, 120)
  const last = rows[rows.length - 1]!.map(s => s.text).join('')
  expect(last).toBe('trend Queue 172 ▇▇▆▆▅▅* -9 │ Support 5 ▃▅▆▄▃▂* -1 │ AP 32 ▂▃▅▆▇▅* merged/wk')
  expect(rows.length).toBe(bandRows(snap() as any, NOCI, 120).length + 1)
})

test('trend: narrow terminals drop rows from the right (AP first) instead of wrapping; one row is cut with an ellipsis at the very least', async () => {
  const at = (w: number) => text([bandRows(trendSnap() as any, NOCI, w).at(-1)!])
  expect(at(70)).toBe('trend Queue 172 ▇▇▆▆▅▅* -9 │ Support 5 ▃▅▆▄▃▂* -1')
  expect(at(40)).toBe('trend Queue 172 ▇▇▆▆▅▅* -9')
  expect(displayWidth(at(24))).toBeLessThanOrEqual(22)
})

test('trend: `trend: false` hides the row; absent or empty trend draws nothing', async () => {
  const off = bandRows(trendSnap() as any, { ...NOCI, trend: false }, 120)
  expect(text(off)).not.toContain('trend ')
  expect(text(bandRows(snap() as any, NOCI, 120))).not.toContain('trend ')
  expect(text(bandRows(trendSnap([]) as any, NOCI, 120))).not.toContain('trend ')
  expect(mergeConfig(parseConfigText('{"trend": false}'), {}).trend).toBe(false)
  expect(mergeConfig(parseConfigText('{"trend": "no"}'), {}).trend).toBeUndefined()
})

test('trend: parseHelper keeps only known keys and plain text, at most three rows', async () => {
  const h = parseHelper(JSON.stringify({ ...BASE, trend: { rows: [...TREND_ROWS, { key: 'queue', short: 'x', full: 'y' }] } }))!
  expect(h.trend!.rows.map(r => r.key)).toEqual(['queue', 'support', 'ap'])
  const bad = parseHelper(JSON.stringify({ ...BASE, trend: { rows: [{ key: 'evil', short: 'a', full: 'b' }, { key: 'ap', short: '\u001b[31mred', full: 'z' }, { key: 'ap', short: 5, full: 'z' }] } }))!
  expect(bad.trend).toBeNull()
  expect(parseHelper(JSON.stringify({ ...BASE, trend: 'x' }))!.trend).toBeNull()
  expect(parseHelper(HELPER)!.trend).toBeNull()
})

test('trend: details has a TREND section with the full line per domain, one row each', async () => {
  const rows = detailRows(trendSnap() as any, NOCI, 100, DETAIL_NOW).map(r => r.map(s => s.text).join(''))
  const i = rows.findIndex(r => r.startsWith('TREND'))
  expect(i).toBeGreaterThanOrEqual(0)
  expect(rows.slice(i, i + 3).map(r => r.slice(10))).toEqual(TREND_ROWS.map(r => r.full))
  expect(rows.find(r => r.startsWith('TREND'))).toContain('Queue   172 ▇▇▆▆▅▅*')
})
