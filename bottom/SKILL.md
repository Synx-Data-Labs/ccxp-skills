---
name: bottom
description: Use when the user explicitly asks to move a task (or several) to the back of the dev/TODO priority queue
disable-model-invocation: false
argument-hint: "T<id> [T<id> ...]"
---

Move one or more tasks to the back of `dev/TODO/queue.md` — the explicit
"deprioritize this, work everything else first" override. Mirror image of
`/top`: same mechanics, opposite extreme. Use it for tasks that turned out
less important than their current position implies (a `ccxp` auto-file that
landed too high, a nice-to-have that shouldn't compete with real work).

## Argument

One or more `T<id>`s, space-separated. `/bottom T<id1> T<id2> T<id3>` moves
`T<id1>` to the very last position, `T<id2>` to second-to-last,
`T<id3>` to third-to-last, pulling everything else up —
**first-listed wins the very bottom.** (Same "first argument wins the
extreme slot" contract as `/top`, just the opposite slot.)

## Behavior

### 1. Resolve each task

Same resolution and hard-stop rules as `/stage` step 1 — glob
`dev/TODO/T<id>-*.md`, delegate zero-match diagnosis to
`bash ~/.claude/skills/_taskid/in-this-repo.sh "T<id>"`, hard-fail on any ID
that doesn't resolve to a file in this repo's `dev/TODO/`. Do not partially
apply — resolve every ID before touching `queue.md`.

### 2. Reorder `queue.md`

Read `dev/TODO/queue.md`. Process the given IDs **in reverse order** —
exactly like `/top`, just appending at the bottom instead of inserting at
the top:

```
for id in reversed(argument_list):
    remove the line for `id` from queue.md if present (no-op if it's new)
    append `- [T{id}](T{id}-{slug}.md): {title}` at the very bottom of the list
```

`{slug}.md` is the actual `dev/TODO/T{id}-*.md` filename — same relative-link format `/stage`/`/top` use.

Worked example — queue starts as `[X, Y, Z]`, running `/bottom A B`:

1. Process `B` (last-listed) first: remove if present, append at bottom → `[X, Y, Z, B]`
2. Process `A`: remove if present, append at bottom → `[X, Y, Z, B, A]`

Final order has `A` truly last, `B` second-to-last — exactly matching the
order given on the command line (first-listed = furthest back). If an ID
wasn't already queued, this both adds and demotes it in one step — no need
to `/stage` first.

### 3. Commit, push, and merge

```bash
BRANCH="docs/bottom-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"
git add dev/TODO/queue.md
git commit -m "docs(queue): move T<id> [T<id> ...] to the bottom"
git push -u origin "$BRANCH"
bash ~/.claude/skills/_gh/gh.sh pr create --base main --head "$BRANCH" --title ... --body ...
```

Then drive the PR to merge with `/address-pr <number>`. Pure `queue.md`
reorder — lifecycle bookkeeping, not a code change — auto-merges under the
pure status-change carve-out in `dev/branch-merge-policy.md` once standard
gates pass. After merge: `git checkout main && git pull`, delete the local
branch.

### 4. Echo confirmation

Print the new tail of the queue so the effect is visible, not just claimed:

```
New queue order (tail):
...
N-2. <previous last>: <title>
N-1. T<id2>: <title>
N.   T<id1>: <title>
Landed: PR #<n> merged
```

## What this skill does NOT do

- **Does not write `scheduled:`** or anything else in the task's own frontmatter — it only touches `queue.md`.
- **Does not park or close the task.** A `/bottom`'d task is still open and workable, just deprioritized — if it should stop being actively tracked at all, that's `/todo`'s park/close flow, not this.
- **Is not a rejection of the task's validity.** Use it for "this can wait," not as a substitute for actually deciding a task is wrong/obsolete (park or close it instead).

## When NOT to use `/bottom`

- **The task should be closed or parked**, not just deprioritized — see `/todo`.
- **You just want to see what's last** — read `dev/TODO/queue.md`'s tail directly; no need to reorder anything.

## Cross-references

- `/top` — the mirror-image front-of-queue mover; same mechanics, opposite end
- `/stage` — append-if-missing at the bottom, but does NOT demote an already-queued task (that's this skill's job)
- `/todo` — `list`/`next` read `queue.md`; `sweep` keeps its membership in sync with `dev/TODO/`
