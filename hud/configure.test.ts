import { expect, test } from 'claude-code/testing'

import { CANCEL, COLOR_DEFAULT, CURRENT_REPO, DEFAULT_BRANCH, NONE, SCOPE_PROJECT, SCOPE_USER, VERSION_HIDE, VERSION_SHOW, WRITE, configureHud } from './configure'

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

test('config: valid answers write only the ci block to the user file, after a confirmation that shows it', async () => {
  const r = await run(['nightly-orchestrator.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.writes.length).toBe(1)
  expect(r.writes[0].path).toBe('/h/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly-orchestrator.yml' }, fillColor: 'gray', version: true })
  expect(r.asked[r.asked.length - 1]).toContain('"ci": {"workflow":"nightly-orchestrator.yml"}')
  expect(r.asked[r.asked.length - 1]).toContain('/h/.claude/ccxp-hud.json')
})

test('config: branch, repo and project scope are honoured; other keys in the file are kept', async () => {
  const files = { '/p/.claude/ccxp-hud.json': '{"band": true, "fields": "ci"}' }
  const r = await run(['w.yml', 'release/4.8', 'acme/widgets', COLOR_DEFAULT, VERSION_SHOW, SCOPE_PROJECT, WRITE], files)
  expect(r.writes[0].path).toBe('/p/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ band: true, fields: 'ci', fillColor: 'gray', version: true, ci: { workflow: 'w.yml', branch: 'release/4.8', repo: 'acme/widgets' } })
})

test('config: choosing none hides CI (ci: null) without asking branch or repo', async () => {
  const r = await run([NONE, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"enabled": true}' })
  expect(JSON.parse(r.writes[0].text)).toEqual({ enabled: true, ci: null, fillColor: 'gray', version: true })
  expect(r.asked.length).toBe(5)
})

test('config: invalid input (spaces, metacharacters, bad repo, bad branch) writes nothing and says why', async () => {
  for (const [wf, br, repo] of [
    ['a b.yml', DEFAULT_BRANCH, CURRENT_REPO],
    ['x;y', DEFAULT_BRANCH, CURRENT_REPO],
    ['$(id)', DEFAULT_BRANCH, CURRENT_REPO],
    ['w.yml', 'bad branch', CURRENT_REPO],
    ['w.yml', DEFAULT_BRANCH, 'not-owner-name'],
  ]) {
    const r = await run([wf, br, repo, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
    expect(r.writes).toEqual([])
    expect(r.out).toMatch(/Nothing written/)
  }
})

test('config: cancel at any step, a declined confirmation, or a dismissed dialog writes nothing', async () => {
  const plans: (string | Error)[][] = [
    [CANCEL],
    ['w.yml', CANCEL],
    ['w.yml', DEFAULT_BRANCH, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, 'something else'],
    ['w.yml', new Error('dismissed')],
    [],
  ]
  for (const plan of plans) {
    const r = await run(plan)
    expect(r.writes).toEqual([])
    expect(r.out).toMatch(/cancelled|Nothing written/)
  }
})

test('config: an unknown scope answer or a missing path writes nothing', async () => {
  expect((await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, '/etc/passwd', WRITE])).writes).toEqual([])
})

test('config: an unparsable existing config file is left alone and nothing is written', async () => {
  const files = { '/h/.claude/ccxp-hud.json': '{ "band": true, // comment\n }' }
  const r = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], files)
  expect(r.writes.length).toBe(0)
  expect(r.out).toContain('left alone')
})

test('config: a repo that starts with - or . is rejected', async () => {
  const r = await run(['w.yml', DEFAULT_BRANCH, '--web/x', COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.writes.length).toBe(0)
})

test('config: the fill colour is asked with gray as the default option, and persisted next to ci', async () => {
  const r = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, 'blue', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'w.yml' }, fillColor: 'blue', version: true })
  expect(r.asked.some(q => q.includes('Which colour'))).toBe(true)
  expect(r.asked[r.asked.length - 1]).toContain('"fillColor": "blue"')
  const d = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(d.writes[0].text).fillColor).toBe('gray')
})

test('config: a custom #rrggbb hex is accepted and lowercased; an unknown colour writes nothing', async () => {
  const r = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, '#A1B2C3', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text).fillColor).toBe('#a1b2c3')
  for (const bad of ['chartreuse', '#12345', 'red; ls', '']) {
    const b = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, bad, VERSION_SHOW, SCOPE_USER, WRITE])
    expect(b.writes).toEqual([])
    expect(b.out).toMatch(/Nothing written/)
  }
})

test('config: the plugin version question defaults to show; hide writes version: false; a bad answer or cancel writes nothing', async () => {
  const shown = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(shown.writes[0].text).version).toBe(true)
  expect(shown.asked.some(q => q.includes('ccxp-skills version'))).toBe(true)
  const hidden = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, VERSION_HIDE, SCOPE_USER, WRITE])
  expect(JSON.parse(hidden.writes[0].text).version).toBe(false)
  expect(hidden.asked[hidden.asked.length - 1]).toContain('"version": false')
  for (const plan of [
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, COLOR_DEFAULT, 'maybe', SCOPE_USER, WRITE],
  ]) {
    const r = await run(plan)
    expect(r.writes).toEqual([])
  }
})
