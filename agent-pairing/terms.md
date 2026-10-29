# Owner terms (`terms.sh`, `terms.json`)

The ccxp-agent learns the owner's acronyms and shorthand. Type "root cause analysis (RCA)" once; later a bare "RCA" is recognized and expanded, also in the prompts the dispatcher writes for background jobs (subagents never see the owner's glossary rule).

## Where things live

- **Store**: `${CCXP_TERMS_FILE:-${CLAUDE_CONFIG_DIR:-~/.claude}/terms.json}`, one per profile. Two profiles that should share terms symlink the file, like they do for `rules/glossary.md`.
- **Writer**: only `agent-pairing/scripts/terms.sh` (atomic temp file + `mv`, previous version kept as `terms.json.bak`, an unreadable file moved aside as `terms.json.corrupt-<time>`, never overwritten). Not locked: last write wins.
- **Hook**: `hooks/terms-hook.sh` (UserPromptSubmit), read-only.
- **Agent rules**: the `## Terms` section of `assets/ccxp-agent.md`; `/agent-pairing update` installs it.

## Layers (nearest first)

1. **Repo glossary**: `<repo>/.claude/rules/glossary.md` of the current repo, read-only, lines `- TERM = expansion (context)`. Domain terms shared with the team.
2. **Repo-scoped** `terms.json` entries (`scope: "repo:<name>"`). The name is the main checkout's directory name (a worktree resolves to its repo).
3. **Global** `terms.json` entries (`scope: "global"`), including the one-way import of the owner's `~/.claude/rules/glossary.md`.

- The first layer that knows the term decides. Another repo's scope is invisible.
- New captures are `global` (personal shorthand must not leak into a shared repo). `--scope repo` is for terms the owner says belong to this repo.
- `terms.json` is the live store the agent can update mid-session; the hand-curated `glossary.md` is loaded only at session start and is never written by this feature.

## Schema (version 1)

```json
{"version": 1, "updated_at": "2026-10-29T10:00:00Z",
 "terms": {"WTF": {"defs": [
   {"text": "what the f**k", "context": null, "scope": "global", "default": false, "pinned": false,
    "hits": 1, "added_at": "2026-10-29", "last_hit": "2026-10-29", "origin": "captured"},
   {"text": "want to find", "context": "search", "scope": "global", "default": false, "pinned": false,
    "hits": 3, "added_at": "2026-10-29", "last_hit": "2026-10-29", "origin": "asked"}]}}}
```

- `origin`: `glossary` (imported, always `pinned`), `captured` (the owner defined it in a message), `asked` (added after the owner said yes or answered).
- `pinned`, `hits`, `last_hit` are recorded so a later owner-triggered export can choose what to keep (see Follow-ups).
- Limits: term 2-12 chars from `A-Za-z0-9&+/-` with at least 2 uppercase letters; text one line, 120 chars; 200 terms; 8 definitions per term (exit 3 beyond that). Lookup is case-sensitive, with a case-insensitive fallback for terms of 3+ chars (`rca` finds `RCA`, `cc` never finds `CC`); plurals (`RCAs`) and hyphen parts (`RCA-style`) match too.

## Commands

| Command | Does |
|---------|------|
| `add TERM text [--context C] [--scope global\|repo\|repo:NAME] [--default] [--pin] [--origin captured\|asked]` | Upsert a definition on term+text+scope; prints `noted: ...` |
| `lookup TERM [--context a,b]` | Resolve one term to JSON (`resolved` with `reason`/`tier`, `ambiguous` with candidates, or `unknown`) |
| `expand [-\|TEXT]` | Every known term used in a message, resolved (read-only) |
| `detect [-\|TEXT]` | Definition candidates in a message: `explicit` or `ask` (read-only) |
| `choose TERM text [--default]` | The owner picked this meaning: `hits`+1, `--default` makes it the default |
| `remove TERM [text]` | Delete one meaning or the whole term (the undo for `noted`) |
| `list [--json]`, `path` | Inspect |
| `import-glossary [FILE] [--dry-run]` | One-way, idempotent, re-runnable import of `- TERM = expansion (tag)` lines; imported entries are `pinned`; the untagged first line of a term becomes its default; a tag becomes the `context`; the file is never modified |

Repo options on the resolving commands: `--cwd DIR` (default `$PWD`), `--repo NAME`, `--repo-glossary FILE`.

## Resolution inside a layer

1. One definition: use it.
2. A `context` tag equal (case-insensitive) to the repo name or a word of the message: use it.
3. The `default` definition.
4. The untagged definition when it is the only one.
5. A clear most-used leader: at least 2 hits, at least 2 ahead, at least double the runner-up.
6. Otherwise `ambiguous`: ask the owner one short question, then `choose` (the answer adds a hit, so two answers make the leader clear and the question stops; "always" sets `--default`).

## Detection (what counts as a definition)

- **Patterns**: `expansion (ACR)`, `ACR (expansion)`, `ACR = expansion`, `ACR means / stands for / is short for ... expansion`, `expansion aka ACR`, and Chinese `ACR 的全称是 / 指的是 / 意思是 ...`.
- **`explicit`** (record, then tell the owner `noted: RCA = root cause analysis`): the letters of the term equal the initials of the expansion (stopwords like of/the/and may be skipped), for example `Department of Defense (DOD)`.
- **`ask`** (ask `remember RCA = root cause analysis?` first): a statement form whose letters do not match (`ENV = production`), a partial match, or any pattern in a message longer than 1500 characters (a pasted document).
- **Ignored**: code spans and fences, quoted `>` lines, units and tickers (`(MB)`, `Apple Inc. (AAPL)`), numbers (`PORT = 8080`), single-letter or lowercase tokens, parentheticals that are not one acronym token. Already known meanings are not reported; a second meaning of a known term is `additional`. At most 3 candidates per message.
- Only the owner's own typed words count. The agent does not capture from pasted text, emails, logs, tool or job output.

## Loading strategy: UserPromptSubmit hook, matched terms only

- **Chosen**: `hooks/terms-hook.sh` runs on every prompt, calls `expand` and `detect`, and injects only the terms that appear in that prompt (plus capture hints). A few lines, nothing when nothing matches, so context never grows with the store.
- **Why not SessionStart**: it would inject the whole store every session (grows without bound), goes stale after a mid-session `add`, and cannot see the current prompt.
- **Why not lookup-on-demand alone**: it costs a tool call per prompt and depends on the model remembering to do it. The agent keeps it as the fallback when the hook is absent.
- **Existing plugin hooks** (checked): a PreToolUse `Skill` hook (`skill-ask.sh`) and the HUD module; no prompt-time hook existed.
- **Scope of the hook**: it fires for every session of the profile, but is silent unless a term matches. Capture hints appear only when the profile has a `terms.json` or defaults to `ccxp-agent` in `settings.json`, so other profiles never see the feature. It never writes.

## Consent

- The owner's own explicit definition counts as the instruction (the glossary rule's "never edit silently" is about silent edits): the agent records it and says so in one line afterwards.
- Inferred or doubtful: ask first.
- `remove` undoes; `terms.json.bak` holds the previous version.

## Setup

1. Update the plugin, then run `/agent-pairing update` (installs the Terms section).
2. Optional seed: `bash <plugin>/agent-pairing/scripts/terms.sh import-glossary --dry-run`, then without `--dry-run`.

## Follow-ups (not built)

- **`promote`**: with the owner's yes, copy a domain-tagged term to the current repo's `.claude/rules/glossary.md` as a small commit/PR. Personal shorthand is never promoted.
- **Distill/export**: an owner-triggered, diffed, never silent selection of the top ~40-50 terms (recency-weighted `hits` plus `pinned`) into a separate generated file, never into the hand-curated `glossary.md`.

## Tests

`bats tests/terms.bats tests/terms_hook.bats`
