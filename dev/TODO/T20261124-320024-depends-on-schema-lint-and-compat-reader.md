---
status: In Progress
estimation: 2
blocks: [T20261124-419462]
source: owner request 2026-11-24 (decision d158), epic E3
description: Define the depends_on and needs frontmatter fields, update lint, add a compat reader for legacy Blocked by
claimed_by: cc1-50ac6891:86d2310edcae5b32
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-320024: Spec, depends_on schema, lint and compat reader

## TLDR

- **Type**: feature
- **Problem**: a task that discovers a dependency must be marked `status: Blocked by T..`, which hides it from auto-pick; the owner wants the real status kept and the dependency shown (epic E3, d158).
- **Solution**: add `depends_on:` and `needs:` frontmatter, teach `lint_tasks.py` and a `todo-deps` compat reader about them, and mark `Blocked by` deprecated (still read); no behavior change for existing files.

## Problem

- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Today `Blocked by T<id>` is both a status and the only dependency record: `repo-conventions/scripts/lint_tasks.py:392` (`check_blocked_by`) reads it, `todo/scripts/_lib.sh:40` (`todo-gated`) skips it, sweep and `/top` walk it.
- Verified: `depends_on` and `needs` are not in the lint allowlist (`lint_tasks.py:20`), so a file using them fails CI today.

## Context

- Scope is schema and tolerance only (sub-task a of five); `todo-deps.sh chain` is T20261124-419462, migration T20261124-177980, drive/autopilot T20261124-112157, HUD and sweep T20261124-158321.
- Constraints: no edits under `hud/` (other jobs), no version bump, no persona edit, SKILL.md prose net-zero; detail goes to `lifecycle.md` and scripts.
- The plugin is used by several repos at different versions, so old and new files must read the same (compat reader).

## Solution

- Schema: `depends_on: [T..]` (inverse of `blocks:`; the task keeps its real status) and `needs: [human|vpn|owner-decision|person:<alias>|ext:<text>]`; both in `ALLOWED` (`lint_tasks.py`).
- Lint: `check_depends_on` (well-formed ids, never self), `check_needs` (slug tokens, typed forms follow the `Blocked by person:` rules), board-wide `lint_depends_on` (unknown id and cycles fail; an id already Done only warns, so closing a dependency never fails an unrelated PR), `warn_blocked_by` (deprecation warning, not an error).
- Compat reader: `todo-deps <file>` in `todo/scripts/_lib.sh` prints `depends_on` ids plus legacy `Blocked by` ids, de-duplicated; `todo-gated` is unchanged, so a task with only `depends_on` is never gated.
- Docs: `lifecycle.md`, `todo/SKILL.md` (one bullet, net size +~200 B), `repo-conventions/templates/task.md` and `guidelines.md`.
- Alternatives rejected: reusing the legacy `blocked-by:` key (free text in the wild, prose and strikethrough notes); making a Done dependency a lint failure (would fail unrelated PRs until sweep learns to drop it in T20261124-158321).

## Root cause

- Introduced with the original status model (`lifecycle.md` status table, deliberate): dependency was folded into `status:` because the board then had one place to look. The cost is that a task discovering a dependency stops looking In Progress, and `todo-gated` (`todo/scripts/_lib.sh:40`) skips it. Verified by reading both files; not an oversight, a design the owner now reverses (d158).

## Repo file references

| File | Change |
|------|--------|
| `repo-conventions/scripts/lint_tasks.py` | allowlist, `check_depends_on`, `check_needs`, `lint_depends_on`, `warn_blocked_by`, `dependency_ids` |
| `todo/scripts/_lib.sh` | `todo-deps` compat reader |
| `lifecycle.md`, `todo/SKILL.md`, `repo-conventions/templates/task.md`, `repo-conventions/templates/guidelines.md` | document the fields, deprecate `Blocked by` |
| `repo-conventions/scripts/test_lint_tasks.py`, `tests/todo-lib.bats`, `tests/todo-next.bats` | tests |

## Test plan

- [x] unit: `repo-conventions/scripts/test_lint_tasks.py` (allowlist, list forms, bad entry, self, needs rules, cycle, chain, Done warns, missing fails, deprecation warning)
- [x] bats: `tests/todo-lib.bats` (`todo-deps` flow list, block list, legacy merge, none, gate), `tests/todo-next.bats` (`--skip-gated` keeps a `depends_on`-only task)
- [x] local: `python3 repo-conventions/scripts/lint_tasks.py --all .` shows the same pre-existing violations as main, none new
- [ ] CI: all required checks green on the PR

## Done criteria

- [x] `depends_on` and `needs` accepted by lint: `test_depends_on_and_needs_are_allowed_keys`
- [x] `depends_on` ids must exist and not cycle; Done only warns: `test_depends_on_live_passes_done_warns_missing_fails`, `test_depends_on_cycle_fails`
- [x] `Blocked by` still valid but warns: `test_blocked_by_warns_deprecated_but_passes`
- [x] compat reader merges old and new: `tests/todo-lib.bats` "todo-deps reads a legacy Blocked by status and merges without duplicates"
- [x] a `depends_on`-only task is not gated: `tests/todo-next.bats` "--skip-gated keeps a task that only records depends_on"
- [x] docs updated: `lifecycle.md` (Optional metadata fields), `todo/SKILL.md` (`blocks` bullet), templates
- [x] no version bump, no `hud/` edit, persona untouched: `git diff --stat` of the PR
