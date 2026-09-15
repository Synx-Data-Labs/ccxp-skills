---
name: migrate-task
description: Use when the user explicitly asks to move a task file from one repo's dev/TODO/ to another repo's — e.g. a mis-scoped target-repo: task, or a task filed in the wrong hub before a repo split
disable-model-invocation: false
argument-hint: "T<id> <target-repo> [--dry-run]"
---

Move a task file — and its `dev/TODO/queue.md` entry — from the current
repo's `dev/TODO/` to another repo's, landing the destination first and
removing the source second (see [`## Solution`](../../dev/TODO/T20260827-201400-migrate-task-skill.md#solution)
of the design task for full rationale). Distilled from
T20260827-420045's by-hand migration (3 tasks, `synxdb-team` → `ccxp-skills`).

## Argument

`/migrate-task <task-id> <target-repo> [--dry-run]` — positional, no flag
soup beyond the one optional preview flag.

- `<task-id>`: a `T<id>` that resolves to exactly one `dev/TODO/T<id>-*.md`
  in the **current working repo** (found via `bash ../_taskid/in-this-repo.sh
  <id>`, same as `/stage`/`/drive`).
- `<target-repo>`: a local sibling directory path, or a
  `Synx-Data-Labs/<repo>` slug (resolved to a clone URL via `gh repo view
  --json url`). **Never read from the task's own `target-repo:` frontmatter
  field** — that field can go stale across a repo split (T20260827-420045's
  3 files all pointed at the wrong repo by the time they were migrated). The
  caller re-verifies the current-correct destination and supplies it
  explicitly.
- `--dry-run`: runs the resolve/clone/collision-check/blocking-check steps
  against the real clones, then prints the two diffs that would be
  committed (target addition, source removal) and exits — no branch, no
  push, no PR, no mutation of either remote.

## Workflow

1. **Resolve source and target.** Confirm `dev/TODO/T<id>-*.md` exists in
   the current repo (hard-fail with the same diagnosis `/stage` uses
   otherwise). Resolve `<target-repo>` to a clone URL.
2. **Clone both fresh under `/tmp/`** — never the caller's interactive
   sibling clones (`/drive` Phase 1.5's ephemeral-clone pattern; mutating an
   interactive clone directly hit a hard block during the worked example).
3. **Collision-check** the id against target's
   `dev/{TODO,PARKING,JOURNAL}/` (`mt-collision-check` in `scripts/migrate.sh`
   — mirrors `_taskid/new.sh --check`'s loop). Should never collide (IDs are
   timestamp-random) — hard-fail loudly if it does.
4. **Bidirectional-blocking check** (`mt-blocking-check`): hard-fail if the
   migrated task's own `blocks:` is non-empty, or if another source-repo
   task's `status:` reads `Blocked by T<id>` for this task — per
   `lifecycle.md`'s "Blocking: Bidirectional Links" cascade-unblock
   invariant. A human resolves the relationship first; this skill doesn't
   guess.
5. **Claimed-task guard**: hard-fail if `claimed_by:` is non-empty — release
   the claim before migrating, don't silently carry or drop it.
6. **Land the destination first** (add before remove — a task existing in
   both repos briefly is safe; existing in neither is not): copy the file
   into target's `dev/TODO/`, strip `target-repo:`/`target-path:`, run
   target's `repo-conventions/scripts/lint_tasks.py --changed <file>` if
   present, insert into target's `queue.md` via `mt-queue-insert` — append,
   unless a task **already in the target queue** reads `status: Blocked by
   T<id>` (`mt-target-blocked-by`), in which case insert immediately before
   it. (The migrated task's own `blocks:` can't trigger this branch — step 4
   already hard-failed if it were non-empty; this is the *other* direction,
   where the task becomes someone else's blocker only once it lands in the
   target queue.) Branch `t<id>-migrate-in`, commit, push, open PR, drive to
   merge via `/address-pr`.
7. **Then remove from source**: `git mv` the file to
   `dev/JOURNAL/<today>-T<id>-<slug>.md`, set `status: Done` (matching
   `lifecycle.md`'s Status Flow enum — no `Closed` value exists), stamp
   `scheduled:` to the JOURNAL-date's Monday if empty, add a
   `## Migrated (<date>)` section linking the new location. Remove its
   `queue.md` line. Branch `t<id>-migrate-out`, commit, push, open PR,
   drive to merge via `/address-pr`.
8. If step 6's PR fails to merge, stop before step 7 — source is untouched,
   safe to retry or abort.
9. Clean up both ephemeral clones (`trap EXIT`).

## Important Notes

- **Sequential, not atomic.** These are independent git repos — no
  cross-repo transaction exists. Add-then-remove is the safe ordering;
  remove-then-add risks losing the task if the destination PR fails.
- **`--dry-run` is the regression-check mechanism**, not a general preview
  toy — it's what validates this skill against T20260827-420045's
  already-merged diffs ([#28](https://github.com/Synx-Data-Labs/ccxp-skills/pull/28), [#564](https://github.com/Synx-Data-Labs/synxdb-team/pull/564))
  without re-migrating anything.
- **Pure logic lives in `scripts/migrate.sh`**, sourceable and BATS-tested
  (`tests/migrate_task.bats`, repo root): frontmatter get/delete, the
  collision check, the bidirectional-blocking check, and the
  append-or-insert-before queue algorithm (mirrors `/stage`'s insertion
  logic — `/stage` has no shared script of its own to call, so the
  algorithm is reimplemented here, not invoked). The live push/PR-opening
  path is integration surface, not unit-tested — same convention as
  `_session/task_claim.sh`'s thin `gh`/git I/O wrappers.
