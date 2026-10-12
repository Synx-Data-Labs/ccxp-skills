---
name: top
description: Use when the user explicitly asks to move a task (or several) to the front of the dev/TODO priority queue
disable-model-invocation: false
argument-hint: "T<id> [T<id> ...] | T<id> [T<id> ...] --before T<id>"
---

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

### 1. Resolve each task

Same resolution and hard-stop rules as `/stage` step 1 — glob
`dev/TODO/T<id>-*.md`, delegate zero-match diagnosis to
`bash <skills-root>/_taskid/in-this-repo.sh "T<id>"`, hard-fail on any ID
that doesn't resolve to a file in this repo's `dev/TODO/`. Do not partially
apply — resolve every ID before touching `queue.md`. **In `--before` mode**,
the target `T<targetId>` must resolve the same way, **and** must already
have a line in `queue.md` — there's no position to insert "before" if it
isn't queued yet (`/stage` it first, or drop `--before`).

### 2. Transitive blocker resolution

Topping a task that can't actually be worked yet just buries the real
next-step — the blocker — one level deeper. Applies in **both** modes —
before reordering, expand each given ID into its blocker chain:

For each resolved task, read its frontmatter `status:` field. If it matches
`Blocked by T<id>` (the canonical lifecycle status, case-insensitive):

1. Resolve `T<id>` the same way as step 1 (glob `dev/TODO/T<id>-*.md`).
   - **Not found** (already closed/Done, or lives in another repo) — nothing
     open to reorder; stop walking this chain, use the original ID as-is.
   - **Found** — recurse: check *that* task's own `status:` for another
     `Blocked by`, and keep walking. Cap the walk at **10 hops** and hard-stop
     with a report (don't silently truncate) if it's still chasing blockers —
     that's almost certainly a cycle or a data error, not a real dependency
     depth.
2. Replace the given ID with `[deepest-blocker, ..., immediate-blocker,
   original-id]` — the chain in dependency order, blocker-of-blocker first.

Only follow the structured `status: Blocked by T<id>` field — never the
free-text `related:` list. `related` links siblings, prior context, and soft
references (e.g. a closed task, a design doc); treating every `related:`
mention as a hard blocker would drag unrelated tasks to the top on every
`/top` call. `Blocked by` is the one field the lifecycle convention reserves
for "cannot proceed until this closes."

Worked example — `T-task`'s frontmatter reads `status: Blocked by
T-blocker`, and `T-blocker` resolves to an open task with no
further blocker. Running `/top T-task` expands the argument list
to `[T-blocker, T-task]` before step 3 runs. In `--before`
mode the same expansion happens first, so `/top T-task --before Y`
inserts both the blocker and the originally-requested task immediately above
`Y`, blocker first.

### 3. Reorder `queue.md`

Branch off `origin/main`, not whatever's checked out — a `/drive` call fires mid-feature-branch and would drag its commits in otherwise:

```bash
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch origin main -q
BRANCH="docs/top-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH" origin/main  # fails on conflicting local changes — commit first, retry
```

**Default mode.** Read `dev/TODO/queue.md`. Process the **expanded** ID list
from step 2 **in reverse order** — this is what makes first-listed end up
truly first:

```
for id in reversed(expanded_id_list):
    bash <skills-root>/_queue/queue.sh top dev/TODO/queue.md T{id} T{id}-{slug}.md "{title}"
```

`queue.sh top` removes the line if present and inserts it as the first entry (adds if new).

`{slug}.md` is the actual `dev/TODO/T{id}-*.md` filename — same relative-link format `/stage` uses.

Worked example — queue starts as `[X, Y, Z]`, running `/top A B` where
neither `A` nor `B` is blocked:

1. Process `B` (last-listed) first: remove if present, insert at top → `[B, X, Y, Z]`
2. Process `A`: remove if present, insert at top → `[A, B, X, Y, Z]`

Final order has `A` at #1, `B` at #2, exactly matching the order given on
the command line. If an ID wasn't already queued, this both adds and
promotes it in one step — no need to `/stage` first.

Continuing the blocker example from step 2 — `/top T-task` expands
to `[T-blocker, T-task]`, so the *blocker* lands at the very
top and the originally-requested task sits directly behind it: the queue now
tells whoever reads it next to work the blocker first, not the task that's
still stuck.

**`--before` mode.** Process the **expanded** ID list in **forward** order
(the opposite of default mode — each insert lands immediately above
`T<targetId>`, i.e. *below* everything inserted earlier in the batch, so
forward processing keeps the list's own order and the blocker stays ahead
of the task it blocks). Re-read `T<targetId>`'s position fresh each
iteration — an earlier insert in the same batch shifts it down by one:

```
for id in expanded_id_list:        # forward — NOT reversed
    bash <skills-root>/_queue/queue.sh insert-before dev/TODO/queue.md T{id} T{id}-{slug}.md "{title}" T<targetId>
```

`queue.sh insert-before` removes the line if present and re-finds the target's position each call.

Worked example — queue starts as `[W, X, Y, Z]`, running `/top A B --before Y`:

1. Process `A`: `Y` is at position 3 → insert above it → `[W, X, A, Y, Z]`
2. Process `B`: `Y` is now at position 4 → insert above it → `[W, X, A, B, Y, Z]`

Final order is `A, B, Y` — the given order, with the whole batch directly
ahead of `Y`. For a blocker chain `/top T --before Y` (expanded to
`[blocker, T]`) this yields `[..., blocker, T, Y, ...]`: blocker first.
`W` and `X` are untouched — this is the difference from plain `/top`,
which would have pushed them down too.

### 4. Commit, push, and merge

```bash
# Also pass any newly-untracked T<id> file (same fix as /stage) as an extra path.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).
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

### 5. Echo confirmation

**Default mode** — print the new head of the queue so the effect is
visible, not just claimed, including any blockers step 2 pulled up, so it's
clear *why* something besides the requested ID moved:

```
New queue order:
1. T<id1>: <title>  [blocker of T<id2>, pulled up]
2. T<id2>: <title>
3. T<id3>: <title>
4. <previous #1>: <title>
5. <previous #2>: <title>
Landed: PR #<n> merged
```

**`--before` mode** — print the local neighborhood around the target instead (the head of the queue didn't change, so showing it would be misleading); same blocker annotation applies if step 2 pulled anything up:

```
New order around T<targetId>:
N-1. <task now just above the inserted ones>: <title>
N.   T<id1>: <title>  [blocker of T<id2>, pulled up]
N+1. T<id2>: <title>
N+2. T<targetId>: <title>
Landed: PR #<n> merged
```

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
