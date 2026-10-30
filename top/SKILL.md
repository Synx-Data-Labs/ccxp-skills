---
name: top
description: Use when the user explicitly asks to move a task (or several) to the front of the dev/TODO priority queue
argument-hint: "T<id> [T<id> ...] | T<id> [T<id> ...] --before T<id>"
---

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Move one or more tasks to the front of `dev/TODO/queue.md` — the explicit
"work on this next, ahead of everything else" override. This is the manual
lever for cases the queue's plain top-to-bottom order can't express on its
own: an in-flight task at risk of being buried, a maintainer directive, a
newly-urgent item that shouldn't wait for the next IPM.

## Argument

**Default (no `--before`):** one or more `T<id>`s, space-separated.
`/top T<id1> T<id2> T<id3>` moves `T<id1>` to position 1, `T<id2>` to
position 2, `T<id3>` to position 3, pushing everything else down —
**first-listed wins the very top.**

**`--before T<id>` mode:** `/top T<id1> [T<id2> ...] --before T<targetId>`
inserts the given task(s), in the order given, immediately ahead of `T<targetId>`'s *current*
position, instead of jumping to the absolute front. Use this whenever a
task's urgency is relative to one specific other task — most commonly, a
blocker that must land before the thing it blocks, but doesn't need to
leapfrog everything else in the queue. Plain `/top` (no `--before`) is for
"this is now the most important thing, full stop"; `--before` is for
"this must come before *that one task*, wherever *that* currently sits."

## Behavior

### 1. Branch off `origin/main`

Not whatever's checked out — a `/drive` call fires mid-feature-branch and would drag its commits in otherwise:

```bash
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch origin main -q
BRANCH="docs/top-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH" origin/main  # fails on conflicting local changes — commit first, retry
```

### 2. Run the script

```bash
bash <skills-root>/top/scripts/top.sh [--dry-run] T<id> [T<id> ...] [--before T<targetId>]
```

`top.sh` is `<skills-root>/_queue/queue-op.sh top` (unit-tested in `tests/queue_op.bats`); do not re-derive its logic. In order, it:

1. **Resolves** every id (and the `--before` target) to exactly one `dev/TODO/T<id>-*.md` **before touching `queue.md`**; zero matches runs `_taskid/in-this-repo.sh` for the diagnosis. In `--before` mode the target must already be queued (`/stage` it first, or drop `--before`).
2. **Expands blockers** (both modes): each id becomes `[deepest-blocker, ..., immediate-blocker, id]` by following only the structured `status: Blocked by T<id>` field (case-insensitive, first id named) — never `related:`. A blocker with no file in `dev/TODO/` (closed, or another repo) ends the walk. More than 10 hops, a cycle, or the `--before` target appearing in the expanded list is a hard stop (exit 4), not a silent truncation.
3. **Reorders** through `_queue/queue.sh`, writing `queue.md` only on success. Default: the expanded list goes to the front, first-listed at #1 (queue `[X, Y, Z]`, `/top A B` gives `[A, B, X, Y, Z]`; an unqueued id is added and promoted in one step). `--before`: the list lands in order immediately above the target, which is why `/top T --before Y` with `T` blocked by `K` yields `[..., K, T, Y, ...]`; everything else keeps its place. A repeated id keeps its first occurrence.

Stdout is the confirmation (new head of the queue, or the neighborhood of the target, with `[blocker of T<id>, pulled up]` on pulled-up blockers) followed by `CHANGED=0|1` and `UNTRACKED=<paths>`. Exit: 0 ok (even if already in place, `CHANGED=0`), 1 unresolvable id or unqueued `--before` target, 2 usage, 4 cycle / over 10 hops / target in chain. Judgment stays here: whether `--before` is the right mode, and whether a pulled-up blocker is really wanted.

### 3. Commit, push, and merge

```bash
# Also pass every path in the script's UNTRACKED= line (newly-untracked task files) as extra paths.
bash <skills-root>/_gh/land.sh --branch "$BRANCH" --message "docs(queue): move T<id> [T<id> ...] to the top" \
  --title "docs(queue): move T<id> to the top" --body "Queue reorder." -- dev/TODO/queue.md [dev/TODO/T<id>-*.md ...]
# --before mode message: "...to immediately before T<targetId>"
```

Then drive the PR to merge with `/address-pr <number>`. Pure `queue.md`
reorder — lifecycle bookkeeping, not a code change — auto-merges under the
pure status-change carve-out in `dev/branch-merge-policy.md` once standard
gates pass.

After merge: `git checkout "$ORIG_BRANCH"` (`git pull` too if that's
`main`), delete the local `$BRANCH` — back to the caller's actual branch,
not a hardcoded `main`.

### 4. Echo confirmation

Show the script's confirmation block (new head of the queue, or the neighborhood around the target) and add `Landed: PR #<n> merged`.

## What this skill does NOT do

- **Does not write `scheduled:`** or anything else in the task's own frontmatter — it only touches `queue.md`. Iteration-scheduling happens at IPM commit time, separately.
- **Does not chase `related:` links, only `status: Blocked by`.** Pulling in every soft reference would make `/top` unpredictable — it follows the one field the lifecycle convention reserves for hard dependencies.
- **Does not give any task permanent protection.** A `/top`'d task can be `/top`'d again by something else later — it's a position, not a lock. If an in-flight task needs to stay protected across the whole week, re-`/top` it if it drifts, or raise it at the IPM.
- **`--before` mode does not verify the blocking relationship is real.** It trusts the caller (a human, `/stage`, or `/todo sweep`) to have already established that `T<id>` genuinely gates `T<targetId>` — it just performs the reposition. Garbage in, garbage out.
- **Is not the P0 escalation channel.** `/top` reorders a list; it doesn't page anyone. For production-down / customer-blocked / security incidents, use the Slack escalation protocol (see `/todo`'s P0 escape hatch) — do that first, and `/top` the resulting task as a secondary, non-urgent bookkeeping step if it helps.

## When NOT to use `/top`

- **Routine backlog additions** with no urgency — use `/stage` (appends to the end, doesn't disturb existing order).
- **You just want to see what's next** — that's `/todo next`, which reads the queue but doesn't change it.
- **A task's urgency is only "ahead of the specific thing it blocks," not "ahead of everything"** — use `--before` instead of plain `/top`. Sending a blocker to the absolute front when it only needed to outrank one other task needlessly buries unrelated higher-priority work every time this fires (this is why `/todo sweep`'s blocker-ordering enforcement uses `--before`, not plain `/top` — see `/todo`).

## Cross-references

- `/stage` — append-if-missing; also uses `--before` mode when a newly-staged task blocks something already queued, instead of appending to the end
- `/bottom` — the mirror-image back-of-queue mover
- `/todo` — `list`/`next` read `queue.md`; `sweep` enforces blocker ordering via `/top --before` and keeps membership in sync with `dev/TODO/`
