import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, ciFromAnswers, configPaths, heartbeatPath, mergeConfig, parseCi, parseConfigText, withCi, withEnabled } from './config'
import { EMPTY, bandRows, compactLine, countJobs, ctxTone, formatStamp, isApOn, meter, parseHelper, tierOf, truncateWords } from './model'

const NOW = Math.floor(Date.now() / 1000)
const RUN_AT = new Date(2026, 9, 26, 3, 0).getTime() / 1000
const AP = { status: 'running', prefix: '[r]', elapsed_hr: 2, requested_hr: 6, stuck: 0, cycle: 3, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 2 }
const BASE = {
  repo: 'synxdb-build-pipeline',
  task_id: 'T20261021-354035',
  task_title: 'Decouple the nightly orchestrator',
  branch: 't20261021-354035-decouple',
  worktree: '',
  autopilot: null as any,
  ledger: { running: [{ job: 230, title: 'fix hud' }], lifetime_jobs: 230, parked: 3, parked_ids: [], next_job: 231, updated_at: '' },
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

test('config: ci defaults to unset (no CI segment); jobs is gone from the fields and ignored in a user file', async () => {
  expect(DEFAULTS.ci).toBeUndefined()
  expect(DEFAULTS.fields).not.toContain('jobs' as any)
  expect(parseConfigText('{"fields": "ap,ctx,branch,task,jobs,lastat"}').fields).toEqual(['ap', 'ctx', 'branch', 'task', 'lastat'])
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

test('setup: answers are validated; blanks mean defaults', async () => {
  expect(ciFromAnswers({ workflow: ' nightly.yml ', branch: '', repo: '' })).toEqual({ ok: true, ci: { workflow: 'nightly.yml' } })
  expect(ciFromAnswers({ workflow: 'w.yml', branch: 'main', repo: 'acme/widgets' })).toEqual({ ok: true, ci: { workflow: 'w.yml', branch: 'main', repo: 'acme/widgets' } })
  for (const bad of [
    { workflow: 'a b.yml', branch: '', repo: '' },
    { workflow: 'w.yml; ls', branch: '', repo: '' },
    { workflow: '', branch: '', repo: '' },
    { workflow: 'w.yml', branch: 'x y', repo: '' },
    { workflow: 'w.yml', branch: '', repo: 'justname' },
    { workflow: 'w.yml', branch: '', repo: 'a/b/c' },
  ]) expect(ciFromAnswers(bad).ok).toBe(false)
})

test('setup: withCi writes only the ci key, keeps every other key, stays valid JSON (even from garbage)', async () => {
  expect(JSON.parse(withCi('{"band": false, "fields": "ctx", "userColor": "red"}', { workflow: 'w.yml' }))).toEqual({ band: false, fields: 'ctx', userColor: 'red', ci: { workflow: 'w.yml' } })
  expect(JSON.parse(withCi('{"ci": {"workflow": "old.yml"}, "enabled": false}', { workflow: 'new.yml' }))).toEqual({ ci: { workflow: 'new.yml' }, enabled: false })
  expect(JSON.parse(withCi('{"enabled": true}', null))).toEqual({ enabled: true, ci: null })
  expect(JSON.parse(withCi('garbage', { workflow: 'w.yml' }))).toEqual({ ci: { workflow: 'w.yml' } })
  expect(JSON.parse(withCi(undefined, null))).toEqual({ ci: null })
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

test('ctxTone: green above warn, yellow to crit, red below', async () => {
  expect(ctxTone(64, DEFAULTS)).toBe('success')
  expect(ctxTone(40, DEFAULTS)).toBe('warning')
  expect(ctxTone(15, DEFAULTS)).toBe('warning')
  expect(ctxTone(14, DEFAULTS)).toBe('error')
  expect(meter(50)).toBe('▓▓▓▓▓░░░░░')
})

test('countJobs groups agent statuses (the pane still shows them)', async () => {
  expect(countJobs([{ status: 'running' }, { status: 'pending' }, { status: 'idle' }, { status: 'waiting' }, { status: 'failed' }, { status: 'completed' }])).toEqual({ running: 2, waiting: 2, failed: 1 })
})

test('mode: AP ON while running, backing off or paused; OFF when stopped, absent or no data', async () => {
  const mk = (prefix: string) => withHelper({ autopilot: { ...AP, prefix } })
  expect([isApOn(mk('[r]')), isApOn(mk('[b]')), isApOn(mk('[p]'))]).toEqual([true, true, true])
  expect([isApOn(mk('[s]')), isApOn(snap()), isApOn(EMPTY)]).toEqual([false, false, false])
})

test('AP OFF row: repo | branch | task ID + slug | CI | you HH:MM; no AP, no ctx, no jobs', async () => {
  const rows = bandRows(snap(), CI, 160)
  expect(rows.length).toBe(1)
  expect(text(rows)).toMatch(/^synxdb-build-pipeline │  t20261021-354035-decouple │ T20261021-354035 Decouple the nightly orchestrator │ CI ✗ failing 10-26 │ you \d\d:\d\d$/)
  for (const gone of ['AP', 'ctx', 'jobs']) expect(text(rows)).not.toContain(gone)
})

test('AP ON row: AP elapsed/duration loops n done | ctx % | CI | you HH:MM; no repo, branch or task', async () => {
  const rows = bandRows(snapAp(), CI, 160)
  expect(rows.length).toBe(1)
  expect(text(rows)).toMatch(/^AP 2\/6h loops 3 ✓2 merged │ ctx 64% ▓▓▓▓▓▓░░░░ │ CI ✗ failing 10-26 │ you \d\d:\d\d$/)
  for (const gone of ['synxdb', 't20261021', 'T20261021', 'jobs']) expect(text(rows)).not.toContain(gone)
})

test('AP ON: paused is marked and stuck shows; a stopped autopilot gets the OFF row', async () => {
  const paused = text(bandRows(withHelper({ autopilot: { ...AP, prefix: '[p]', status: 'paused', stuck: 2 } }), CI, 160))
  expect(paused).toContain('AP ⏸ paused 2/6h ⚠2 loops 3')
  const stopped = text(bandRows(withHelper({ autopilot: { ...AP, prefix: '[s]', status: 'stopped' } }), CI, 160))
  expect(stopped).not.toContain('AP')
  expect(stopped).toContain('synxdb-build-pipeline')
})

test('always ONE row at every width, in both modes, never wider than the terminal', async () => {
  for (const s of [snap(), snapAp()]) {
    for (const cols of [10, 20, 30, 40, 50, 60, 69, 70, 80, 99, 100, 120, 160, 300]) {
      const rows = bandRows(s, CI, cols)
      expect(rows.length).toBe(1)
      const line = rows[0].map(x => x.text).join('')
      expect(line.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
      expect(line).not.toContain('\n')
      expect(line).not.toMatch(/│\s*│/)
    }
  }
})

test('tiers only change abbreviation: wide full labels, compact short, tiny minimal', async () => {
  expect(text(bandRows(snapAp(), CI, 140))).toContain('CI ✗ failing 10-26')
  expect(text(bandRows(snapAp(), CI, 140))).toContain('✓2 merged')
  const compact = text(bandRows(snapAp(), CI, 80))
  expect(compact).toContain('CI ✗ 10-26')
  expect(compact).toContain('AP 2/6h loops 3 ✓2')
  expect(compact).not.toContain('merged')
  expect(compact).not.toContain('▓')
  const tiny = text(bandRows(snapAp(), CI, 60))
  expect(tiny).toContain('AP 2/6h L3 ✓2')
  expect(tiny).toContain('ctx 64%')
})

test('CI states: symbol, word, colour; the date shows when known', async () => {
  const cell = (state: string, at = RUN_AT) => bandRows(withHelper({ ci: { state, at } }), { ...CI, fields: ['ci'] }, 140)[0]
  const look = (state: string) => [cell(state)[1].text, cell(state)[1].color]
  expect(look('passing')).toEqual(['✓ passing 10-26', 'success'])
  expect(look('failing')).toEqual(['✗ failing 10-26', 'error'])
  expect(look('running')).toEqual(['◐ running 10-26', 'warning'])
  expect(look('unknown')).toEqual(['? unknown 10-26', 'inactive'])
  expect(cell('passing', 0)[1].text).toBe('✓ passing')
})

test('CI missing (no data from the helper): the segment is dropped silently, nothing else changes', async () => {
  const t = text(bandRows(withHelper({ ci: null }), CI, 160))
  expect(t).not.toContain('CI')
  expect(t).not.toMatch(/│\s*│/)
  expect(t).toContain('synxdb-build-pipeline')
  expect(text(bandRows(withHelper({ ci: null }, HELPER_AP), CI, 160))).toBe(text(bandRows(snapAp(), CI, 160)).replace(' │ CI ✗ failing 10-26', ''))
})

test('fields can switch a member off; retired names have no effect', async () => {
  expect(text(bandRows(snapAp(), { ...CI, fields: ['ap', 'ci'] }, 160))).toBe('AP 2/6h loops 3 ✓2 merged │ CI ✗ failing 10-26')
  expect(bandRows(snap(), { ...DEFAULTS, fields: ['ctx'] }, 160)).toEqual([]) // ctx is not part of the OFF row
})

test('narrow drop order, AP OFF: last input first, then task slug, then branch, then task ID; repo and CI stay longest', async () => {
  const at = (cols: number) => text(bandRows(snap(), CI, cols))
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
    const order = ['lastat', 'slug', 'branch', 'taskId'].filter(k => gone[k] !== undefined)
    for (let i = 1; i < order.length; i++) expect(gone[order[i - 1]]).toBeGreaterThanOrEqual(gone[order[i]])
  }
  expect(flags(at(200)).lastat).toBe(true)
  expect(flags(at(100)).slug).toBe(true)
  expect(at(40)).toContain('CI')
  expect(at(40)).toContain('synxdb')
  expect(at(40)).not.toMatch(/you |\d\d:\d\d/)
})

test('narrow drop order, AP ON: last input and CI detail first, ctx meter, then ctx; AP and CI stay', async () => {
  const at = (cols: number) => text(bandRows(snapAp(), CI, cols))
  expect(at(100)).toContain('you ')
  const tight = at(30)
  expect(tight).toContain('AP')
  expect(tight).toContain('CI')
  expect(tight).not.toContain('you ')
  expect(tight).not.toContain('▓')
})

test('last input: you HH:MM today, date when older, hidden when absent', async () => {
  const f = { ...CI, fields: ['lastat' as const] }
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
  expect(text(bandRows(snap({ stale: true }), CI, 160))).toContain('stale')
})

test('band: an unclaimed task or empty branch leaves no cell at all', async () => {
  const t = text(bandRows(withHelper({ task_id: '', task_title: '', branch: '' }), CI, 160))
  expect(t).toMatch(/^synxdb-build-pipeline │ CI /)
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
