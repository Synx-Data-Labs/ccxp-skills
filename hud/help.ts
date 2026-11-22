// ccxp-hud `/hud help [topic]`: pure functions over the text of hud/HELP.md (the one source of the help text).
// Sections are `## <topic> | <alias>, <alias>`; the first paragraph of a section is its summary line in the index.

export type HelpTopic = { name: string; aliases: string[]; body: string }

/** Splits HELP.md into topics; text before the first `## ` heading is ignored. Never throws. */
export function parseHelp(text: string | undefined | null): HelpTopic[] {
  if (!text) return []
  const out: HelpTopic[] = []
  let cur: { head: string; lines: string[] } | undefined
  const flush = () => {
    if (!cur) return
    const [name, aliasPart = ''] = cur.head.split('|').map(s => s.trim())
    if (name) out.push({ name: name.toLowerCase(), aliases: aliasPart.split(',').map(s => s.trim().toLowerCase()).filter(Boolean), body: cur.lines.join('\n').trim() })
  }
  for (const line of text.split('\n')) {
    const m = /^##\s+(.+?)\s*$/.exec(line)
    if (m) {
      flush()
      cur = { head: m[1], lines: [] }
    } else cur?.lines.push(line)
  }
  flush()
  return out
}

/** First sentence-ish line of a topic body, for the index. */
function summary(body: string): string {
  const first = body.split('\n').find(l => l.trim() !== '') ?? ''
  const line = first.replace(/^[-\s]+/, '').trim()
  return line.length > 90 ? `${line.slice(0, 87)}...` : line
}

/** The topic named `query` (case-insensitive, name or alias; a leading `/` or `hud ` is ignored), or undefined. */
export function findTopic(topics: HelpTopic[], query: string): HelpTopic | undefined {
  const q = query.trim().toLowerCase().replace(/^\/?(hud\s+)?(help\s+)?/, '').replace(/\s+/g, '-')
  return topics.find(t => t.name === q || t.aliases.includes(q) || t.aliases.map(a => a.replace(/\s+/g, '-')).includes(q))
}

/**
 * `/hud help` (no topic): the overview and the topic index. `/hud help <topic>`: that section. An unknown topic names the
 * known ones. Missing help text says so plainly.
 */
export function helpText(source: string | undefined | null, topic: string): string {
  const topics = parseHelp(source)
  if (topics.length === 0) return 'ccxp-hud help: the help text (hud/HELP.md) could not be read, so there is nothing to show. See hud/README.md in the ccxp-skills plugin.'
  const names = topics.filter(t => t.name !== 'overview').map(t => t.name)
  if (!topic.trim()) {
    const over = topics.find(t => t.name === 'overview')
    const index = topics.filter(t => t.name !== 'overview').map(t => `  ${t.name.padEnd(9)} ${summary(t.body)}`)
    return [`ccxp-hud help`, '', over?.body ?? '', '', 'Topics (/hud help <topic>):', ...index].join('\n')
  }
  const t = findTopic(topics, topic)
  if (!t) return `ccxp-hud help: no topic "${topic.trim().slice(0, 40)}". Topics: ${names.join(', ')}.`
  const alias = t.aliases.length ? ` (also: ${t.aliases.join(', ')})` : ''
  return `ccxp-hud help: ${t.name}${alias}\n\n${t.body}`
}
