import { expect, test } from 'claude-code/testing'

import { CANCEL, CURRENT_REPO, DEFAULT_BRANCH, NONE, SCOPE_PROJECT, SCOPE_USER, WRITE, setupCi, togglePane } from './setup'

type Run = { out: string; writes: { path: string; text: string }[]; asked: string[] }

async function run(answers: (string | Error)[], files: Record<string, string> = {}): Promise<Run> {
  const writes: { path: string; text: string }[] = []
  const asked: string[] = []
  const queue = [...answers]
  const out = await setupCi({
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

test('setup: valid answers write only the ci block to the user file, after a confirmation that shows it', async () => {
  const r = await run(['nightly-orchestrator.yml', DEFAULT_BRANCH, CURRENT_REPO, SCOPE_USER, WRITE])
  expect(r.writes.length).toBe(1)
  expect(r.writes[0].path).toBe('/h/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly-orchestrator.yml' } })
  expect(r.asked[r.asked.length - 1]).toContain('"ci": {"workflow":"nightly-orchestrator.yml"}')
  expect(r.asked[r.asked.length - 1]).toContain('/h/.claude/ccxp-hud.json')
})

test('setup: branch, repo and project scope are honoured; other keys in the file are kept', async () => {
  const files = { '/p/.claude/ccxp-hud.json': '{"band": true, "fields": "ci"}' }
  const r = await run(['w.yml', 'release/4.8', 'acme/widgets', SCOPE_PROJECT, WRITE], files)
  expect(r.writes[0].path).toBe('/p/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ band: true, fields: 'ci', ci: { workflow: 'w.yml', branch: 'release/4.8', repo: 'acme/widgets' } })
})

test('setup: choosing none hides CI (ci: null) without asking branch or repo', async () => {
  const r = await run([NONE, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"enabled": true}' })
  expect(JSON.parse(r.writes[0].text)).toEqual({ enabled: true, ci: null })
  expect(r.asked.length).toBe(3)
})

test('setup: invalid input (spaces, metacharacters, bad repo, bad branch) writes nothing and says why', async () => {
  for (const [wf, br, repo] of [
    ['a b.yml', DEFAULT_BRANCH, CURRENT_REPO],
    ['x;y', DEFAULT_BRANCH, CURRENT_REPO],
    ['$(id)', DEFAULT_BRANCH, CURRENT_REPO],
    ['w.yml', 'bad branch', CURRENT_REPO],
    ['w.yml', DEFAULT_BRANCH, 'not-owner-name'],
  ]) {
    const r = await run([wf, br, repo, SCOPE_USER, WRITE])
    expect(r.writes).toEqual([])
    expect(r.out).toMatch(/Nothing written/)
  }
})

test('setup: cancel at any step, a declined confirmation, or a dismissed dialog writes nothing', async () => {
  const plans: (string | Error)[][] = [
    [CANCEL],
    ['w.yml', CANCEL],
    ['w.yml', DEFAULT_BRANCH, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, SCOPE_USER, CANCEL],
    ['w.yml', DEFAULT_BRANCH, CURRENT_REPO, SCOPE_USER, 'something else'],
    ['w.yml', new Error('dismissed')],
    [],
  ]
  for (const plan of plans) {
    const r = await run(plan)
    expect(r.writes).toEqual([])
    expect(r.out).toMatch(/cancelled|Nothing written/)
  }
})

test('setup: an unknown scope answer or a missing path writes nothing', async () => {
  expect((await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, '/etc/passwd', WRITE])).writes).toEqual([])
})

test('pane toggle: open when closed, close when open, and it never opens twice', async () => {
  let isUp = false
  const calls: string[] = []
  const io = {
    isOpen: async () => isUp,
    open: async () => {
      calls.push('open')
      isUp = true
    },
    close: async () => {
      calls.push('close')
      isUp = false
    },
  }
  expect(await togglePane(io)).toMatch(/opened/)
  expect(await togglePane(io)).toMatch(/closed/)
  expect(await togglePane(io)).toMatch(/opened/)
  expect(calls).toEqual(['open', 'close', 'open'])
})

test('setup: an unparsable existing config file is left alone and nothing is written', async () => {
  const files = { '/h/.claude/ccxp-hud.json': '{ "band": true, // comment\n }' }
  const r = await run(['w.yml', DEFAULT_BRANCH, CURRENT_REPO, SCOPE_USER, WRITE], files)
  expect(r.writes.length).toBe(0)
  expect(r.out).toContain('left alone')
})

test('setup: a repo that starts with - or . is rejected', async () => {
  const r = await run(['w.yml', DEFAULT_BRANCH, '--web/x', SCOPE_USER, WRITE])
  expect(r.writes.length).toBe(0)
})
