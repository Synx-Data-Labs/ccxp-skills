---
name: stage
description: Ensure a task is present in dev/TODO/queue.md — appended at the end, or inserted immediately before a task it blocks
disable-model-invocation: false
argument-hint: "T<id> [T<id> ...]"
---

Make sure one or more tasks are in `dev/TODO/queue.md` — the ordered priority
queue `/todo` reads. `/stage` never reorders an *already-queued* task; it
only adds tasks that are missing — **but a newly-added task that blocks an
existing queued task is inserted immediately before it**, not appended to
the end (see step 2). Appending a blocker behind what it blocks would be a
topologically broken queue from the moment it's created, not a legitimate
priority call — the same principle `/todo sweep`'s blocker-ordering
enforcement applies to existing entries. To move an already-queued task
that *doesn't* block anything specific, use `/top` instead.

## Argument

One or more `T<id>`s, space-separated. Each must match an existing file
`dev/TODO/T<id>-*.md` in the current working repo (the same repo whose
`dev/TODO/queue.md` will be updated).

## Behavior

### 1. Resolve each task

- Glob `dev/TODO/T<id>-*.md`. Exactly one match → that's the task file; continue.
- **Zero matches** → delegate the diagnosis to the shared clone-locality guard (T20260626-298293) — DRY with `/drive`, and it adds cross-repo awareness (it names the sibling clone that actually holds the task):

  ```bash
  bash ../_taskid/in-this-repo.sh "T<id>"   # exit 3 = closed here; 1/2 = cross-repo (names the clone that has it)
  ```

  Hard-fail after the guard prints its diagnosis:
  - **Exit 3** — task is closed in this repo's `dev/JOURNAL`; "file a new task instead."
  - **Exit 1/2** — cross-repo: the file lives in another clone (named if discoverable); stage it from *that* clone.
  - **Exit 0** — task exists locally but not in `dev/TODO` (typically `dev/PARKING`); `/stage` still stops because it only queues TODO tasks.

  `/stage` always **hard-stops** on zero-match resolution for any of the given IDs — it can't stage a task unless `dev/TODO/T<id>-*.md` resolves in this repo.

### 2. Check current queue membership

Read `dev/TODO/queue.md`. For each resolved `T<id>`:

- **Already listed** (anywhere in the file): no-op for this ID. Note its current 1-based position for the confirmation output.
- **Missing**: check whether this task blocks something already queued (either direction of the convention — the new task's own frontmatter has `blocks: T<blockedId>`, or an already-queued task's `status:` reads `Blocked by T<id>`, prefix match, trailing notes ignored). Both checks are cheap grep-scale — run them before deciding where to place the line:
  - **Blocks nothing queued:** append `- [T<id>](T<id>-<slug>.md): <title>` to the end, as before.
  - **Blocks one or more already-queued tasks:** insert immediately before the *frontmost* one (lowest queue position) instead of appending — invoke `/top`'s `--before` mode directly (`/top T<id> --before T<blockedId>`) rather than reimplementing the insertion logic. If it blocks several queued tasks, `--before` the frontmost one — that's sufficient to make it precede everything it gates, since it's now ahead of the earliest of them.

  `<slug>.md` is the actual `dev/TODO/T<id>-*.md` filename (relative link —
  renders clickable both on GitHub and in-editor) and `<title>` is the first
  `# T<id>: <title>` heading from the task file (fall back to the legacy
  bullet-list title field if pre-2026-05-14 frontmatter).

If `dev/TODO/queue.md` doesn't exist yet in this repo, create it with the header block documented in `/todo`'s "The queue" section, then append/insert as above.

### 3. Commit, push, and merge — only if something actually changed

If every given `T<id>` was already queued, skip straight to step 4 (nothing to land). Otherwise:

```bash
BRANCH="docs/stage-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"
git add dev/TODO/queue.md
# Untracked task file being staged for the first time (e.g. /new-task just
# created it and called /stage immediately): also add THAT exact file, so it
# actually gets committed instead of silently staying untracked forever —
# /stage's resolution step above already reads it (for the queue-line title),
# but the commit historically only added queue.md. Does NOT widen scope for
# the common case: a task file already committed on main is untouched here,
# only a currently-untracked one this exact invocation is staging.
for id in T<id> [T<id> ...]; do
  f="$(git status --porcelain -- "dev/TODO/${id}-"*.md | awk '/^\?\?/{print $2}')"
  [ -n "$f" ] && git add "$f"
done
git commit -m "docs(queue): stage T<id> [T<id> ...]"
git push -u origin "$BRANCH"
bash ../_gh/gh.sh pr create --base main --head "$BRANCH" --title ... --body ...
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

### 4. Echo confirmation

```
T<id>: already at position 3 of 42 — no change
T<id2>: appended at position 43 of 43
T<id3>: inserted at position 12 of 44, immediately before T<blockedId> (it blocks T<blockedId>)
Landed: PR #<n> merged  (or: nothing to land — all already queued)
```

## What this skill does NOT do

- **Does not reorder an already-queued task.** If `T<id>` is already in `queue.md`, staging it again is a no-op regardless of any blocks-relationship — `/stage` only decides *placement* at insertion time, once. To fix a blocker that's already queued but ranked behind what it blocks, that's `/top --before` (or let the next `/todo sweep` catch it).
- **Does not chase indirect/transitive blocking.** If `T<id>` blocks `T<X>` which blocks `T<Y>`, `/stage` only looks at `T<id>`'s direct relationship — it inserts before `T<X>`, not before `T<Y>`. Transitive chains are `/todo sweep`'s job (it re-checks every task on every run).
- **Does not write `scheduled:`.** That field is stamped only at IPM commit time (`/ccxp` Phase 2a), for whichever tasks the IPM actually picks off the top of the queue — staging membership and iteration-scheduling are separate concerns.
- **Does not bundle unrelated working-tree changes.** The staging commit adds only `dev/TODO/queue.md` and, when applicable, the exact newly-untracked `T<id>` task file(s) this invocation is staging (see step 3) — nothing else in the working tree.

## When NOT to use `/stage`

- **An already-queued task needs to jump the line** — that's `/top` (or `/top --before`), not `/stage`.
- **P0 / production incidents**: bypass the queue entirely via the Slack escalation P0 escape hatch (see `/todo` skill).

## Cross-references

- `/top` — moves an *already-queued* task; `/stage` only decides placement once, at first insertion
- `/bottom` — the back-of-queue mover
- `/todo` — `sweep` re-checks blocker ordering on every run (catches what `/stage` couldn't — transitive chains, blockers added after the fact)
