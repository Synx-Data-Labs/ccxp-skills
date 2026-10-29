import { expect, test } from 'claude-code/testing'

import { CANCEL, COLOR_DEFAULT, CI_QUESTION, NONE, SCOPE_PROJECT, SCOPE_USER, VERSION_HIDE, VERSION_SHOW, WRITE, configureHud } from './configure'

type Run = { out: string; writes: { path: string; text: string }[]; asked: string[] }

async function run(answers: (string | Error)[], files: Record<string, string> = {}): Promise<Run> {
  const writes: { path: string; text: string }[] = []
  const asked: string[] = []
  const queue = [...answers]
  const out = await configureHud({
    ask: async q => {
      asked.push(q)
      const a = queue.shift()
      if (a === undefined || a instanceof Error) throw a ?? new Error('dismissed')
      return a
    },
    paths: { user: '/h/.claude/ccxp-hud.json', project: '/p/.claude/ccxp-hud.json' },
    read: async p => files[p],
    write: async (path, text) => {
      writes.push({ path, text })
    },
  })
  return { out, writes, asked }
}

const URL1 = 'https://github.com/acme/widgets/actions/workflows/nightly.yml'

test('config: one workflow URL gives repo + workflow; asks CI, colour, scope, confirm and nothing else', async () => {
  const r = await run([URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.asked.length).toBe(5)
  expect(r.asked[0]).toBe(CI_QUESTION)
  expect(r.asked[0]).toContain('Paste a GitHub Actions workflow URL (repo and workflow are derived from it), or none to hide CI.')
  expect(r.writes.length).toBe(1)
  expect(r.writes[0].path).toBe('/h/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly.yml', repo: 'acme/widgets' }, fillColor: 'gray' })
  expect(r.asked[4]).toContain('"fillColor": "gray"')
  expect(r.asked[4]).toContain('"version": true')
})

test('config: a branch in the URL is kept; project scope; other keys in the file are kept', async () => {
  const files = { '/p/.claude/ccxp-hud.json': '{"band": true, "fields": "ci"}' }
  const r = await run([`${URL1}?query=branch%3Arelease%2F4.8`, COLOR_DEFAULT, VERSION_SHOW, SCOPE_PROJECT, WRITE], files)
  expect(r.writes[0].path).toBe('/p/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ band: true, fields: 'ci', fillColor: 'gray', ci: { workflow: 'nightly.yml', repo: 'acme/widgets', branch: 'release/4.8' } })
})

test('config: a bare workflow file name keeps the current repo', async () => {
  const r = await run(['nightly.yml', COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text).ci).toEqual({ workflow: 'nightly.yml' })
})

test('config: none, no, - and blank hide CI (ci: null)', async () => {
  for (const a of [NONE, 'none', 'No', '-', '']) {
    const r = await run([a, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"enabled": true}' })
    expect(JSON.parse(r.writes[0].text)).toEqual({ enabled: true, ci: null, fillColor: 'gray' })
  }
})

test('config: an invalid CI answer is re-asked, naming the value and an example URL; a good second answer is used', async () => {
  const r = await run(['not a workflow', URL1, 'blue', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.asked[1]).toContain('not a workflow')
  expect(r.asked[1]).toContain('https://github.com/acme/widgets/actions/workflows/nightly.yml')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly.yml', repo: 'acme/widgets' }, fillColor: 'blue' })
})

test('config: two invalid CI answers skip CI (left unchanged) and the fill colour and scope are still asked and written', async () => {
  const files = { '/h/.claude/ccxp-hud.json': '{"ci": {"workflow": "old.yml"}, "enabled": true}' }
  const r = await run(['x;y', 'https://github.com/acme/widgets/actions/runs/9', 'purple', VERSION_SHOW, SCOPE_USER, WRITE], files)
  expect(r.asked.some(q => q.includes('Which colour'))).toBe(true)
  expect(r.writes.length).toBe(1)
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'old.yml' }, enabled: true, fillColor: 'purple' })
  expect(r.asked[r.asked.length - 1]).toContain('"ci" unchanged')
  expect(r.out).toContain('Skipped')
  expect(r.out).not.toMatch(/Nothing written/)
})

test('config: a bad CI answer never aborts: colour is reachable (the reported bug)', async () => {
  const r = await run(['nightly orchestrator', 'still bad', '#A1B2C3', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text)).toEqual({ fillColor: '#a1b2c3' })
})

test('config: an invalid colour is re-asked once, then skipped (unchanged) while the flow continues', async () => {
  const r = await run([URL1, 'chartreuse', '#12345', VERSION_SHOW, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"fillColor": "green"}' })
  expect(r.asked[2]).toContain('chartreuse')
  expect(JSON.parse(r.writes[0].text)).toEqual({ fillColor: 'green', ci: { workflow: 'nightly.yml', repo: 'acme/widgets' } })
  const ok = await run([URL1, 'red; ls', 'blue', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(ok.writes[0].text).fillColor).toBe('blue')
})

test('config: both CI and colour skipped writes nothing and says so', async () => {
  const r = await run(['x;y', 'x;y', 'bad', 'bad'])
  expect(r.writes).toEqual([])
  expect(r.out).toMatch(/Nothing written/)
  expect(r.asked.length).toBe(5)
})

test('config: the fill colour is asked with gray as the default option, and a custom hex is lowercased', async () => {
  const d = await run([URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(d.writes[0].text).fillColor).toBe('gray')
  const r = await run([URL1, '#A1B2C3', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text).fillColor).toBe('#a1b2c3')
})

test('config: an explicit cancel at any step, a declined confirmation, or a dismissed dialog writes nothing', async () => {
  const plans: (string | Error)[][] = [
    [CANCEL],
    [URL1, CANCEL],
    [URL1, COLOR_DEFAULT, CANCEL],
    [URL1, COLOR_DEFAULT, VERSION_SHOW, CANCEL],
    [URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, CANCEL],
    [URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, 'something else'],
    ['bad one', CANCEL],
    [URL1, new Error('dismissed')],
    [],
  ]
  for (const plan of plans) {
    const r = await run(plan)
    expect(r.writes).toEqual([])
    expect(r.out).toMatch(/cancelled|Nothing written/)
  }
})

test('config: an unknown scope answer writes nothing', async () => {
  const r = await run([URL1, COLOR_DEFAULT, VERSION_SHOW, '/etc/passwd', WRITE])
  expect(r.writes).toEqual([])
  expect(r.out).toMatch(/Nothing written/)
})

test('config: an unparsable existing config file is left alone and nothing is written', async () => {
  const files = { '/h/.claude/ccxp-hud.json': '{ "band": true, // comment\n }' }
  const r = await run([URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], files)
  expect(r.writes.length).toBe(0)
  expect(r.out).toContain('left alone')
})

test('config: the plugin version question is reachable after a bad CI answer; hide is written; an odd answer leaves it unchanged', async () => {
  const hidden = await run(['bad one', 'bad two', COLOR_DEFAULT, VERSION_HIDE, SCOPE_USER, WRITE])
  expect(JSON.parse(hidden.writes[0].text)).toEqual({ fillColor: 'gray', version: false })
  const odd = await run([URL1, COLOR_DEFAULT, 'maybe', SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"version": false}' })
  expect(JSON.parse(odd.writes[0].text)).toEqual({ version: false, fillColor: 'gray', ci: { workflow: 'nightly.yml', repo: 'acme/widgets' } })
})
