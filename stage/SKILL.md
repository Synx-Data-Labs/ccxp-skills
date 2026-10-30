---
name: stage
description: Use when the user explicitly asks to ensure a task is present in dev/TODO/queue.md — appended at the end, or inserted immediately before a task it blocks
argument-hint: "T<id> [T<id> ...]"
---

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Make sure one or more tasks are in `dev/TODO/queue.md` — the ordered priority
queue `/todo` reads. `/stage` never reorders an *already-queued* task; it
only adds tasks that are missing — **but a newly-added task that blocks an
existing queued task is inserted immediately before it**, not appended to
the end (see step 1). Appending a blocker behind what it blocks would be a
topologically broken queue from the moment it's created, not a legitimate
priority call — the same principle `/todo sweep`'s blocker-ordering
enforcement applies to existing entries. To move an already-queued task
that *doesn't* block anything specific, use `/top` instead.

## Argument

One or more `T<id>`s, space-separated. Each must match an existing file
`dev/TODO/T<id>-*.md` in the current working repo (the same repo whose
`dev/TODO/queue.md` will be updated).

## Behavior

### 1. Run the script

```bash
bash <skills-root>/stage/scripts/stage.sh [--dry-run] T<id> [T<id> ...]
```

`stage.sh` is `<skills-root>/_queue/queue-op.sh stage` (unit-tested in `tests/queue_op.bats`); do not re-derive its logic. In order, it:

1. **Resolves** every id to exactly one `dev/TODO/T<id>-*.md` before touching `queue.md`. A zero-match id hard-stops (exit 1) after `_taskid/in-this-repo.sh` prints its diagnosis: exit 3 there means closed in this repo's `dev/JOURNAL` ("file a new task instead"), 1/2 means the file lives in another clone (stage it from *that* clone), 0 means it sits in `dev/PARKING`, which `/stage` does not queue.
2. **Checks membership** for each id, in the order given, against the queue as updated so far. Already listed: no-op, its position is reported.
3. **Places** a missing id through `_queue/queue.sh` (never hand-edit the lines; a missing `queue.md` is created with a header). If it blocks an already-queued task (its own `blocks: T<id>` field, or a queued task whose `status:` starts `Blocked by` and names it, trailing notes ignored) it is inserted immediately before the frontmost such task, so a blocker is never appended behind what it blocks; otherwise it is appended. Title is the task's `# T<id>: <title>` heading (slug if absent).

Stdout is the confirmation block, then `CHANGED=0|1` and `UNTRACKED=<paths>` (newly-untracked task files, e.g. one `/new-task` just created). Exit: 0 something was added, 1 unresolvable id (nothing written), 2 usage, 3 everything was already queued (no-op). Judgment stays here: whether the task belongs in the queue at all.

### 2. Commit, push, and merge — only if something actually changed

If the script exited 3 (every `T<id>` already queued), skip straight to step 3 (nothing to land). Otherwise:

```bash
BRANCH="docs/stage-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"
# Pass every path in the script's UNTRACKED= line as an extra path so a newly-created
# task file (e.g. /new-task just called /stage) is committed instead of staying untracked.
bash <skills-root>/_gh/land.sh --branch "$BRANCH" --message "docs(queue): stage T<id> [T<id> ...]" \
  --title "docs(queue): stage T<id>" --body "Queue staging." -- dev/TODO/queue.md [dev/TODO/T<id>-*.md ...]
```

Then drive the PR to merge with `/address-pr <number>`. This is a pure
`queue.md` append (plus, in the untracked case above, the one new task file
that's the subject of this staging call) — lifecycle bookkeeping, not a
code change — so it auto-merges under the pure status-change carve-out in
`dev/branch-merge-policy.md` once the standard gates pass. After merge:
`git checkout main && git pull`, delete the local branch.

- **Batch staging** (several `T<id>`s in one invocation): ONE commit / ONE PR for the whole batch.
- **Scope discipline**: `git add` only `dev/TODO/queue.md` and — only when
  newly-untracked — the exact task file(s) named in this invocation's
  `T<id>` arguments. Every other working-tree change stays behind untouched.
- **No-network fallback**: if push/PR fails (offline, auth), report it and leave the working-tree change in place — say so explicitly in the summary.

### 3. Echo confirmation

Show the script's per-id lines (`already at position N of M — no change`, `appended at position ...`, `inserted at position ..., immediately before T<blockedId> (it blocks T<blockedId>)`) and add `Landed: PR #<n> merged` (or `nothing to land — all already queued`).

## What this skill does NOT do

- **Does not reorder an already-queued task.** If `T<id>` is already in `queue.md`, staging it again is a no-op regardless of any blocks-relationship — `/stage` only decides *placement* at insertion time, once. To fix a blocker that's already queued but ranked behind what it blocks, that's `/top --before` (or let the next `/todo sweep` catch it).
- **Does not chase indirect/transitive blocking.** If `T<id>` blocks `T<X>` which blocks `T<Y>`, `/stage` only looks at `T<id>`'s direct relationship — it inserts before `T<X>`, not before `T<Y>`. Transitive chains are `/todo sweep`'s job (it re-checks every task on every run).
- **Does not write `scheduled:`.** That field is stamped only at IPM commit time (`/ccxp` Phase 2a), for whichever tasks the IPM actually picks off the top of the queue — staging membership and iteration-scheduling are separate concerns.
- **Does not bundle unrelated working-tree changes.** The staging commit adds only `dev/TODO/queue.md` and, when applicable, the exact newly-untracked `T<id>` task file(s) this invocation is staging (see step 2) — nothing else in the working tree.

## When NOT to use `/stage`

- **An already-queued task needs to jump the line** — that's `/top` (or `/top --before`), not `/stage`.
- **P0 / production incidents**: bypass the queue entirely via the Slack escalation P0 escape hatch (see `/todo` skill).

## Cross-references

- `/top` — moves an *already-queued* task; `/stage` only decides placement once, at first insertion
- `/bottom` — the back-of-queue mover
- `/todo` — `sweep` re-checks blocker ordering on every run (catches what `/stage` couldn't — transitive chains, blockers added after the fact)
