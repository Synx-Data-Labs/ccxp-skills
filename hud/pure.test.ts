import { expect, test } from 'claude-code/testing'

import { DEFAULTS, borderOf, ciFromAnswers, configPaths, heartbeatPath, mergeConfig, parseCi, parseConfigText, withCi, withEnabled, withFill } from './config'
import { FILL_BG, charWidth, displayWidth, fillRow, fillStyleFor, fitSegs, stripAnsi, truncateDisplay } from './fill'
import { EMPTY, bandRows, baseName, compactLine, countJobs, ctxTone, detailRows, formatAge, formatStamp, isApOn, isWithin, jobState, meter, parseHelper, tierOf, truncateWords } from './model'

const NOW = Math.floor(Date.now() / 1000)
const RUN_AT = new Date(2026, 9, 26, 3, 0).getTime() / 1000
const AP = { status: 'on', prefix: '[r]', elapsed_hr: 2, requested_hr: 6, stuck: 0, cycle: 3, last_outcome: '', last_task: '', stuck_reason: '', stop_reason: '', merged: 2 }
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
      const cell = bandRows(snapAp({ ctxLeft: Number(left) }), CI, cols)[0].find(s => s.text.startsWith('ctx '))
      expect(cell?.text).toContain(`ctx ${left}%`)
      expect(cell?.color).toBe(color)
    }
  }
  // The colour follows the percentage shown: 75.4 is displayed as 75, which is yellow.
  expect(bandRows(snapAp({ ctxLeft: 75.4 }), CI, 140)[0].find(s => s.text.startsWith('ctx '))?.color).toBe('warning')
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

test('AP OFF row: repo @ branch | task ID + slug | jobs | CI | you HH:MM; no AP, no ctx', async () => {
  const rows = bandRows(snap(), CI, 160)
  expect(rows.length).toBe(1)
  expect(text(rows)).toMatch(/^synxdb-build-pipeline @ t20261021-354035-decouple │ T20261021-354035 Decouple the nightly orchestrator │ WORKING \(1\) │ CI ✗ failing 10-26 │ you \d\d:\d\d$/)
  for (const gone of ['AP', 'ctx']) expect(text(rows)).not.toContain(gone)
  // The repo cell carries the branch, so there is no separate branch cell.
  expect(text(rows).split('t20261021-354035-decouple').length).toBe(2)
})

test('AP ON row: AP elapsed/duration loops n done | ctx % | jobs | CI | you HH:MM; no repo, branch or task', async () => {
  const rows = bandRows(snapAp(), CI, 160)
  expect(rows.length).toBe(1)
  expect(text(rows)).toMatch(/^AP 2\/6h loops 3 ✓2 merged │ ctx 64% ▓▓▓▓▓▓░░░░ │ WORKING \(1\) │ CI ✗ failing 10-26 │ you \d\d:\d\d$/)
  for (const gone of ['synxdb', 't20261021', 'T20261021']) expect(text(rows)).not.toContain(gone)
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
  expect(text(bandRows(withHelper({ ci: null }, HELPER_AP), CI, 160))).toContain('WORKING (1)')
})

test('fields can switch a member off; retired names have no effect', async () => {
  expect(text(bandRows(snapAp(), { ...CI, fields: ['ap', 'ci'] }, 160))).toBe('AP 2/6h loops 3 ✓2 merged │ CI ✗ failing 10-26')
  expect(bandRows(snap(), { ...DEFAULTS, fields: ['ctx'] }, 160)).toEqual([]) // ctx is not part of the OFF row
})

test('narrow drop order, AP OFF: last input first, then task slug, then task ID, then the repo cell loses its branch; repo and CI stay longest', async () => {
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
    const order = ['lastat', 'slug', 'taskId', 'branch'].filter(k => gone[k] !== undefined)
    for (let i = 1; i < order.length; i++) expect(gone[order[i - 1]]).toBeGreaterThanOrEqual(gone[order[i]])
  }
  expect(flags(at(200)).lastat).toBe(true)
  expect(flags(at(130)).slug).toBe(true)
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
  expect(t).toMatch(/^synxdb-build-pipeline │ WORKING \(1\) │ CI /)
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

const repoCell = (h: object, extra = {}, cols = 200) => text(bandRows({ ...withHelper(h), ...extra }, { ...CI, fields: ['repo'] }, cols))

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
  const star = bandRows(withHelper({ repo_slug: 'a/b', branch: 'main', dirty: 2 }), { ...CI, fields: ['repo'] }, 200)[0].find(s => s.text === '*')
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
  const arrow = bandRows({ ...withHelper(h), moved: true }, { ...CI, fields: ['repo'] }, 200)[0][0]
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
  const root = bandRows({ ...withHelper(h), sessionRoot: '/proj/launch' }, { ...CI, fields: ['repo'] }, 200)[0].find(s => s.text.includes('root:'))
  expect(root?.color).toBe('warning')
  expect([baseName('/a/b/'), baseName(''), isWithin('/a/b', '/a/b'), isWithin('/a/bc', '/a/b')]).toEqual(['b', '', true, false])
})

test('repo cell shrinks by width: worktree, then account, then names; the marker survives longest and the row never overflows', async () => {
  const full = { repo_slug: 'synx-data-labs/ccxp-skills', branch: 'feat/a-rather-long-branch-name', dirty: 2, worktree: 'wt-one', gh_account: 'shine-work', cwd: '/other/ccxp-skills' }
  const at = (cols: number) => text(bandRows({ ...withHelper(full), moved: true, sessionRoot: '/proj/launch' }, { ...CI, fields: ['repo'] }, cols))
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

test('repo cell with the other cells: a narrow row keeps repo and CI, and the repo cell also fits the compact line', async () => {
  const s = withHelper({ repo_slug: 'acme/widgets', branch: 'main', dirty: 1 })
  expect(text(bandRows(s, CI, 160))).toMatch(/^acme\/widgets @ main\* │ T20261021-354035 Decouple the nightly orchestrator │ WORKING \(1\) │ CI ✗ failing 10-26 │ you \d\d:\d\d$/)
  expect(compactLine(s, CI)).toContain('acme/widgets @ main*')
  expect(text(bandRows(s, CI, 45))).toMatch(/^widgets\*/)
  expect(text(bandRows(s, CI, 45))).toContain('CI')
})

test('branch cell: shown on its own when `repo` is not a field; the repo cell otherwise says it once', async () => {
  expect(text(bandRows(snap(), { ...CI, fields: ['branch'] }, 200))).toBe(' t20261021-354035-decouple')
  expect(text(bandRows(snap(), { ...CI, fields: ['repo', 'branch'] }, 200))).toBe('synxdb-build-pipeline @ t20261021-354035-decouple')
})

// --- jobs cell: green READY when no job runs, yellow WORKING (N) otherwise; hidden without a ledger ---

const ledgerOf = (n: number) => ({ ledger: { running: Array.from({ length: n }, (_, i) => ({ job: 230 + i, title: `job ${i}` })), lifetime_jobs: 230 + n, parked: 0, parked_ids: [], next_job: 231 + n, updated_at: '' } })
const jobsCell = (n: number, base = HELPER, cols = 200) => bandRows(withHelper(ledgerOf(n), base), { ...CI, fields: ['jobs'] }, cols)[0]

test('jobs cell: READY green at 0, WORKING (N) yellow at 1 and 5', async () => {
  expect(jobsCell(0).map(s => [s.text, s.color])).toEqual([['READY', 'success']])
  expect(jobsCell(1).map(s => [s.text, s.color])).toEqual([['WORKING (1)', 'warning']])
  expect(jobsCell(5).map(s => [s.text, s.color])).toEqual([['WORKING (5)', 'warning']])
})

test('jobs cell: no ledger means no cell at all (no READY without a source)', async () => {
  expect(bandRows(withHelper({ ledger: null }), { ...CI, fields: ['jobs'] }, 200)).toEqual([])
  expect(text(bandRows(withHelper({ ledger: null }), CI, 160))).not.toMatch(/READY|WORKING/)
  expect(text(bandRows(withHelper({ ledger: null }, HELPER_AP), CI, 160))).not.toMatch(/READY|WORKING/)
})

test('jobs cell sits before CI in both orderings; `fields` can switch it off', async () => {
  const idle = { ...ledgerOf(0) }
  expect(text(bandRows(withHelper(idle), CI, 160))).toMatch(/ │ READY │ CI ✗ failing/)
  expect(text(bandRows(withHelper(idle, HELPER_AP), CI, 160))).toMatch(/ctx 64% ▓▓▓▓▓▓░░░░ │ READY │ CI ✗ failing/)
  expect(text(bandRows(withHelper(idle), { ...CI, fields: ['repo', 'ci'] }, 160))).not.toContain('READY')
})

test('jobs cell narrow: the count goes before the word, READY keeps its word; the row stays one line', async () => {
  const work = withHelper(ledgerOf(3), HELPER_AP)
  const idle = withHelper(ledgerOf(0), HELPER_AP)
  expect(text(bandRows(work, CI, 140))).toContain('WORKING (3)')
  let seenBare = false
  for (let cols = 140; cols >= 22; cols--) {
    const t = text(bandRows(work, CI, cols))
    if (t.includes('WORKING') && !t.includes('WORKING (3)')) seenBare = true
    expect(t.includes('WORKING (3)') && seenBare).toBe(false) // never back to the count once dropped
    expect(bandRows(work, CI, cols).length).toBe(1)
  }
  expect(seenBare).toBe(true)
  expect(text(bandRows(idle, CI, 60))).toContain('READY')
  expect(text(bandRows(withHelper(ledgerOf(2)), CI, 60))).toMatch(/WORKING/)
})

// --- /hud details: the band expanded to five live lines ---

const DETAIL_NOW = Date.now()
const detail = (s: object, cols = 140, cfg = CI) => detailRows(s as any, cfg, cols, DETAIL_NOW).map(r => r.map(x => x.text).join(''))
const fullSnap = (over = {}) => ({
  ...withHelper({
    repo_slug: 'acme/widgets',
    dirty: 2,
    autopilot: AP,
    ledger: { running: [{ job: 70, title: 'Redo HUD repo field' }, { job: 73, title: 'Autopilot cycle 2' }], lifetime_jobs: 82, parked: 2, parked_ids: ['k1', 'k2'], next_job: 83, updated_at: '' },
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
  const on = text(bandRows(withHelper({ autopilot: { ...AP, status: 'on', requested_hr: 0 } }), CI, 160))
  expect(on).toContain('AP 2h loops 3 ✓2 merged')
  expect(on).not.toContain('/0h')
  const idle = text(bandRows(withHelper({ autopilot: { ...AP, status: 'on', prefix: '[i]', last_outcome: 'idle', requested_hr: 0 } }), CI, 160))
  expect(idle).toContain('AP idle 2h')
  const paused = text(bandRows(withHelper({ autopilot: { ...AP, status: 'paused', prefix: '[p]', requested_hr: 0 } }), CI, 160))
  expect(paused).toContain('AP ⏸ paused 2h')
})

test('details: five lines in order: where, usage, jobs, autopilot with CI, last prompt', async () => {
  const lines = detail(fullSnap({ rateUsed: 42, costUsd: 1.5 }))
  expect(lines.length).toBe(5)
  expect(lines[0]).toBe('acme/widgets @ t20261021-354035-decouple* │ T20261021-354035 Decouple the nightly orchestrator')
  expect(lines[1]).toBe('ctx 64% ▓▓▓▓▓▓░░░░ │ 5h 42% │ $1.50')
  expect(lines[2]).toBe('WORKING (2) │ r70 Redo HUD repo field  r73 Autopilot cycle 2 │ parked 2 (k1 k2) │ tot 82')
  expect(lines[3]).toMatch(/^AP on 2\/6h loops 3 ✓2 merged │ CI \(nightly\.yml\) ✓ passing \d\d-\d\d \(2h ago\)$/)
  expect(lines[4]).toMatch(/^you \d\d:\d\d \(5m ago\)$/)
})

test('details: colours match the band (ctx tone, READY/WORKING, CI state) and the dirty mark is yellow', async () => {
  const rows = detailRows(fullSnap({ ctxLeft: 40 }) as any, CI, 140, DETAIL_NOW)
  expect(rows[1].find(s => s.text.startsWith('ctx '))?.color).toBe('error')
  expect(rows[2][0]).toEqual({ text: 'WORKING (2)', color: 'warning' })
  expect(rows[0].find(s => s.text === '*')?.color).toBe('warning')
  expect(rows[3].find(s => s.text.includes('passing'))?.color).toBe('success')
  const idle = detailRows(withHelper({ ledger: { running: [], lifetime_jobs: 82, parked: 0, parked_ids: [], next_job: 83, updated_at: '' } }) as any, CI, 140, DETAIL_NOW)
  expect(idle[2][0]).toEqual({ text: 'READY', color: 'success' })
})

test('details: lines with nothing to say are left out (no ledger, no CI config, no prompt time, no ctx)', async () => {
  const lines = detail({ ...withHelper({ ledger: null, last_input_at: 0 }), ctxLeft: null }, 140, DEFAULTS)
  expect(lines.length).toBe(2) // where, autopilot (off)
  expect(lines[1]).toBe('AP off')
  expect(lines.join('\n')).not.toMatch(/READY|WORKING|you |CI/)
})

test('details: every line fits the terminal at every width and the band row is untouched', async () => {
  for (let cols = 140; cols >= 22; cols--) {
    for (const s of [fullSnap(), fullSnap({ stale: true, rateUsed: 99, costUsd: 123.45 })]) {
      for (const line of detail(s, cols)) expect(line.length).toBeLessThanOrEqual(Math.max(20, cols - 2))
    }
  }
  expect(bandRows(fullSnap() as any, CI, 140).length).toBe(1)
})

test('details: a narrow terminal shrinks titles and ages before it cuts', async () => {
  const wide = detail(fullSnap(), 140)
  const narrow = detail(fullSnap(), 70)
  expect(narrow[2]).toMatch(/^WORKING \(2\) │ r70/)
  expect(narrow[2].length).toBeLessThan(wide[2].length)
  const old = Math.floor(DETAIL_NOW / 1000) - 3 * 86400
  expect(detail(fullSnap({ helper: { ...fullSnap().helper, last_input_at: old } }), 140)[4]).toMatch(/^you \w{3} \d+ \d\d:\d\d \(3d ago\)$/)
  expect(detail(fullSnap({ helper: { ...fullSnap().helper, last_input_at: old } }), 22)[4]).toMatch(/^you \w{3} \d+ \d\d:\d\d$/)
})

test('details: an empty snapshot has no lines; a stale helper keeps its tag', async () => {
  expect(detailRows(EMPTY, DEFAULTS, 140, DETAIL_NOW)).toEqual([])
  expect(detail({ ...EMPTY, stale: true }, 140, DEFAULTS)).toEqual(['stale'])
})

const fillWidth = (segs: { text: string }[]) => segs.reduce((n, s) => n + displayWidth(s.text), 0)

test('fill: config defaults to false, parses booleans only, withFill keeps other keys', async () => {
  expect(DEFAULTS.fill).toBe(false)
  expect(mergeConfig(parseConfigText('{"fill": true}'), {}).fill).toBe(true)
  expect(mergeConfig(parseConfigText('{"fill": "yes"}'), {}).fill).toBe(false)
  expect(mergeConfig(parseConfigText('{"fill": true}'), parseConfigText('{"fill": false}')).fill).toBe(false)
  expect(JSON.parse(withFill('{"band": false}', true))).toEqual({ band: false, fill: true })
  expect(JSON.parse(withFill('garbage', false))).toEqual({ fill: false })
})

test('fill: displayWidth counts ASCII 1, CJK and emoji 2, marks and joiners 0', async () => {
  expect(displayWidth('abc')).toBe(3)
  expect(displayWidth('')).toBe(0)
  expect(displayWidth('你好')).toBe(4)
  expect(displayWidth('ab你')).toBe(4)
  expect(displayWidth('🚀')).toBe(2)
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
