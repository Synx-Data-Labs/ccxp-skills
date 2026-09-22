---
name: new-task
description: Use when the user explicitly asks to file, create, or add a new task to the dev/TODO backlog
disable-model-invocation: false
argument-hint: "[one-line description]"
---

Create a new `dev/TODO/T<id>-<slug>.md` task file — gathering its content
through a short back-and-forth rather than fabricating it — then hand off
to `/stage` to land it in `dev/TODO/queue.md` and merge. This is the
"create" half; `/stage` is the "add to queue" half (see its own skill for
why they're split: `/stage` also stages already-existing task files on
their own, with no creation step).

## Argument

`[one-line description]` — optional. If given, use it as the starting
point for the title/Problem instead of asking for one. If omitted, ask for
it first.

## Workflow

### 1. Determine the type

Ask which of these the task is, unless it's obvious from context:

| Type | What it means |
|---|---|
| `bug` | Something is broken; needs repro evidence and (eventually) a root cause |
| `feature` | New capability; needs the use case and how it fits what exists |
| `chore` | Friction/cleanup, not a behavior change |
| `research` | A question to answer — reading-based, no code |
| `spike` | A throwaway prototype to verify feasibility (mirrors `superpowers:brainstorming`'s own Spike path — code, but disposable) |
| `rca` | Investigates a reported failure/bug; usually links the triggering incident |
| `other` | None of the above fit |

### 2. Gather content

Ask only for what isn't already evident from the current conversation —
don't re-ask about something the user just told you. At minimum you need:

- **Title** — a short, action-oriented line
- **Problem** — what's wrong or needed, as bullets with evidence (a
  `file:line`, a failing command, a quoted requirement) — not a paragraph
- **Estimation** — one of `15m|30m|1h|2h|4h|1d|2d|1w`

Ask about these only when they plausibly apply — don't force them:

- `deadline` (hard date), `blocks`/`blocked-by` (dependency on another
  `T<id>`), `source` (where this came from — infer "this conversation,
  YYYY-MM-DD" when that's genuinely the origin rather than asking),
  `related`, `owner`

**Never fabricate Problem detail, an estimation, or a source the user
hasn't given and that isn't clearly inferable from the conversation — ask
instead of guessing.** A vague or wrong task file is worse than one more
question.

### 3. Mint the ID and write the file

```bash
bash ../_taskid/new.sh --check ./dev
```

Write `dev/TODO/T<id>-<slug>.md` from
[`repo-conventions/templates/task.md`](../repo-conventions/templates/task.md) —
frontmatter (`status: Open`, `estimation`, and whichever optional fields
step 2 collected — delete the ones that don't apply, per the template's own
instructions), then:

```markdown
# T<id>: <title>

## Problem

- **Type**: <chosen type>
- <the gathered Problem bullets>
```

`repo-conventions/templates/task.md` has no `Type` concept of its own — this
bullet is a forward-compatible seed. When `/drive` Phase 2 later grows this
file into the full `design-doc.md` structure, its `## TLDR` gets its own
**Type** line (per that template's enum, which matches step 1's table
exactly) — fold this bullet into that line then, don't leave both.

### 4. Lint before proceeding

Mirror the canonical pre-commit doc-lint bundle (`gcpr/SKILL.md`'s Step
1.5, T20260627-192311) — scoped to just the file you created, never
repo-wide, so this never touches an unrelated pre-existing doc as a side
effect of filing one task:

```bash
python3 ../repo-conventions/scripts/lint_tasks.py --changed dev/TODO/T<id>-<slug>.md
bash ../_docs/lint-docs.sh --fix dev/TODO/T<id>-<slug>.md
python3 ../repo-conventions/scripts/lint_paragraphs.py --changed dev/TODO/T<id>-<slug>.md
python3 ../repo-conventions/scripts/lint_refs.py --fix --changed dev/TODO/T<id>-<slug>.md
```

`lint_tasks.py` is the hard gate — fix and re-check on any failure.
`lint-docs.sh`/`lint_paragraphs.py`/`lint_refs.py` are fix-then-continue by
their own policy (never block the commit), same as `gcpr`'s usage; a
residual `lint-docs.sh` violation surfaces loudly and the PR's own
`Markdown Lint` CI check is the authoritative gate for it.

### 5. Stage it

Invoke `/stage T<id>`. It resolves the file, inserts it into `queue.md`
(appended, or before a task it blocks), and lands **both** the queue line
and this newly-untracked task file in one commit/PR — see `/stage`'s own
step 3 for the untracked-file handling this relies on.

### 6. Report

Echo `/stage`'s own confirmation output (task ID, queue position, PR link
or merge status) — don't re-derive it.

## Important Notes

- This skill only **creates and stages** the task. It does not claim,
  design, or implement it — that's `/claim` or `/drive`.
- Don't hand-roll a separate commit/PR for the new file — `/stage` handles
  landing it (step 5 above). If `/stage` isn't reachable for some reason,
  leave the file uncommitted and say so; the next `/todo sweep` will pick
  it up.

## Cross-references

- `/stage` — lands the file this skill creates into `dev/TODO/queue.md`
- `/todo` — `sweep` picks up any task file this skill leaves unstaged
- `/claim`, `/drive` — pick up and work the task once filed
