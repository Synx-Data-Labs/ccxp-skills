import { expect, test } from 'claude-code/testing'

import { CANCEL, COLOR_DEFAULT, CI_QUESTION, NONE, SCOPE_PROJECT, SCOPE_USER, VERSION_HIDE, VERSION_SHOW, WRITE, configureHud } from './configure'

type Run = { out: string; writes: { path: string; text: string }[]; asked: string[]; headers: string[] }

async function run(answers: unknown[], files: Record<string, string> = {}, preset?: { ci?: string }, hooks: { read?: () => Promise<string | undefined>; write?: () => Promise<void> } = {}): Promise<Run> {
  const writes: { path: string; text: string }[] = []
  const asked: string[] = []
  const headers: string[] = []
  const queue = [...answers]
  const out = await configureHud({
    ask: async (q, o) => {
      asked.push(q)
      headers.push(o.header)
      const a = queue.shift()
      if (a === undefined || a instanceof Error) throw a ?? new Error('dismissed')
      return a as string
    },
    paths: { user: '/h/.claude/ccxp-hud.json', project: '/p/.claude/ccxp-hud.json' },
    read: hooks.read ?? (async p => files[p]),
    write: hooks.write ?? (async (path, text) => {
      writes.push({ path, text })
    }),
  }, preset)
  return { out, writes, asked, headers }
}

const URL1 = 'https://github.com/acme/widgets/actions/workflows/nightly.yml'

test('config: one workflow URL gives repo + workflow; asks CI, colour, scope, confirm and nothing else', async () => {
  const r = await run([URL1, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.asked.length).toBe(5)
  expect(r.asked[0]).toBe(CI_QUESTION)
  expect(r.asked[0]).toContain('Paste a GitHub Actions workflow URL (repo and workflow are derived from it), or none to hide CI.')
  expect(r.writes.length).toBe(1)
  expect(r.writes[0].path).toBe('/h/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly.yml', repo: 'acme/widgets' }, fillColor: 'gray' , version: true })
  expect(r.asked[4]).toContain('"fillColor": "gray"')
  expect(r.asked[4]).toContain('"version": true')
})

test('config: a branch in the URL is kept; project scope; other keys in the file are kept', async () => {
  const files = { '/p/.claude/ccxp-hud.json': '{"band": true, "fields": "ci"}' }
  const r = await run([`${URL1}?query=branch%3Arelease%2F4.8`, COLOR_DEFAULT, VERSION_SHOW, SCOPE_PROJECT, WRITE], files)
  expect(r.writes[0].path).toBe('/p/.claude/ccxp-hud.json')
  expect(JSON.parse(r.writes[0].text)).toEqual({ band: true, fields: 'ci', fillColor: 'gray', ci: { workflow: 'nightly.yml', repo: 'acme/widgets', branch: 'release/4.8' } , version: true })
})

test('config: a bare workflow file name keeps the current repo', async () => {
  const r = await run(['nightly.yml', COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text).ci).toEqual({ workflow: 'nightly.yml' })
})

test('config: none, no, - and blank hide CI (ci: null)', async () => {
  for (const a of [NONE, 'none', 'No', '-', '']) {
    const r = await run([a, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"enabled": true}' })
    expect(JSON.parse(r.writes[0].text)).toEqual({ enabled: true, ci: null, fillColor: 'gray' , version: true })
  }
})

test('config: an invalid CI answer is re-asked, naming the value and an example URL; a good second answer is used', async () => {
  const r = await run(['not a workflow', URL1, 'blue', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.asked[1]).toContain('not a workflow')
  expect(r.asked[1]).toContain('https://github.com/acme/widgets/actions/workflows/nightly.yml')
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'nightly.yml', repo: 'acme/widgets' }, fillColor: 'blue' , version: true })
})

test('config: two invalid CI answers skip CI (left unchanged) and the fill colour and scope are still asked and written', async () => {
  const files = { '/h/.claude/ccxp-hud.json': '{"ci": {"workflow": "old.yml"}, "enabled": true}' }
  const r = await run(['x;y', 'https://github.com/acme/widgets/actions/runs/9', 'purple', VERSION_SHOW, SCOPE_USER, WRITE], files)
  expect(r.asked.some(q => q.includes('Which colour'))).toBe(true)
  expect(r.writes.length).toBe(1)
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: { workflow: 'old.yml' }, enabled: true, fillColor: 'purple' , version: true })
  expect(r.asked[r.asked.length - 1]).toContain('"ci" unchanged')
  expect(r.out).toContain('Skipped')
  expect(r.out).not.toMatch(/Nothing written/)
})

test('config: a bad CI answer never aborts: colour is reachable (the reported bug)', async () => {
  const r = await run(['nightly orchestrator', 'still bad', '#A1B2C3', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(r.writes[0].text)).toEqual({ fillColor: '#a1b2c3' , version: true })
})

test('config: an invalid colour is re-asked once, then skipped (unchanged) while the flow continues', async () => {
  const r = await run([URL1, 'chartreuse', '#12345', VERSION_SHOW, SCOPE_USER, WRITE], { '/h/.claude/ccxp-hud.json': '{"fillColor": "green"}' })
  expect(r.asked[2]).toContain('chartreuse')
  expect(JSON.parse(r.writes[0].text)).toEqual({ fillColor: 'green', ci: { workflow: 'nightly.yml', repo: 'acme/widgets' } , version: true })
  const ok = await run([URL1, 'red; ls', 'blue', VERSION_SHOW, SCOPE_USER, WRITE])
  expect(JSON.parse(ok.writes[0].text).fillColor).toBe('blue')
})

test('config: CI, colour and version all skipped writes nothing and says so', async () => {
  const r = await run(['x;y', 'x;y', 'bad', 'bad', 'maybe'])
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

const BLOB = 'https://github.com/acme/widgets/blob/main/.github/workflows/nightly.yml'
const CI_BLOB = { workflow: 'nightly.yml', repo: 'acme/widgets', branch: 'main' }

test('config: a long blob URL, quoted or not, with whitespace or newlines, is accepted on the first try', async () => {
  for (const a of [BLOB, `"${BLOB}"`, `'${BLOB}'`, `\`${BLOB}\``, `<${BLOB}>`, `  ${BLOB}\n`, `\n"${BLOB}"\n`]) {
    const r = await run([a, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
    expect(r.asked.length).toBe(5)
    expect(JSON.parse(r.writes[0].text).ci).toEqual(CI_BLOB)
  }
})

test('config: non-string dialog answers are coerced instead of throwing', async () => {
  const r = await run([{ answer: BLOB }, [COLOR_DEFAULT], { text: VERSION_SHOW }, SCOPE_USER, WRITE])
  expect(r.writes.length).toBe(1)
  expect(JSON.parse(r.writes[0].text)).toEqual({ ci: CI_BLOB, fillColor: 'gray', version: true })
})

test('config: every dialog header fits the engine limit of 12 characters (a longer one makes the dialog reject)', async () => {
  const r = await run([BLOB, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE])
  expect(r.headers.length).toBe(5)
  for (const h of r.headers) expect(h.length <= 12).toBe(true)
})

test('config: /hud config <url> uses the URL as the CI answer and skips that question; an unusable one falls back to asking', async () => {
  const r = await run([COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], {}, { ci: `"${BLOB}"` })
  expect(r.asked.length).toBe(4)
  expect(JSON.parse(r.writes[0].text).ci).toEqual(CI_BLOB)
  const bad = await run([BLOB, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], {}, { ci: 'nonsense here' })
  expect(bad.asked.length).toBe(5)
  expect(bad.asked[0]).toContain('nonsense here')
  expect(JSON.parse(bad.writes[0].text).ci).toEqual(CI_BLOB)
})

test('config: a dismissed dialog is a cancel with the reason; any other exception reports why and writes nothing', async () => {
  const dismissed = await run([BLOB, new Error('dialog dismissed')])
  expect(dismissed.out).toContain('cancelled')
  expect(dismissed.out).toContain('dialog dismissed')
  expect(dismissed.writes).toEqual([])
  const failed = await run([BLOB, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER], {}, undefined, { read: async () => { throw new Error('EACCES: cannot read') } })
  expect(failed.out).toBe('ccxp-hud config failed: EACCES: cannot read; nothing written.')
  const wfail = await run([BLOB, COLOR_DEFAULT, VERSION_SHOW, SCOPE_USER, WRITE], {}, undefined, { write: async () => { throw new Error('disk full') } })
  expect(wfail.out).toContain('ccxp-hud config failed: disk full')
  expect(wfail.out).not.toContain('cancelled')
})
