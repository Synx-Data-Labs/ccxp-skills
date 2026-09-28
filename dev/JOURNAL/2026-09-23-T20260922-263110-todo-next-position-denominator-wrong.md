---
status: Done
estimation: 15m
source: /drive cycle, discovered using todo/scripts/todo-next.sh live after merging T20260914-359646
related: T20260914-359646
description: todo-next.sh's "#N of M" denominator counts raw queue.md file lines, not actual task entries
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260922-263110: `todo-next.sh`'s "#N of M" denominator counts raw file lines, not task entries

Design PR skipped 2026-09-23 (autopilot, no maintainer in the loop) —
self-evident one-line bug fix with reproduction evidence and a specific
fix already in the task file, per `/drive` Phase 2's skip condition 1.

## Problem

- `todo/scripts/todo-next.sh` (`todo_next_main`) builds `lines` by reading
  every line of `dev/TODO/queue.md` (`while IFS= read -r line; do
  lines+=("$line"); done < "$QUEUE_FILE"`), then reports each pick's
  position as `"#%d of %d"` using `"${#lines[@]}"` as the denominator —
  but `lines` includes `queue.md`'s header prose and blank lines, not
  just the `- [T{id}](...)` task entries.
- Observed live: with 18 actual task entries in `queue.md` (26 total
  lines including the 7-line header block + 1 blank line), running
  `bash todo/scripts/todo-next.sh` reported `#1 of 26`, `#2 of 26`, `#3
  of 26` — the denominator should read `18`.
- `todo/SKILL.md`'s own `next` workflow step 4 spec is explicit: "its
  **queue position** (e.g. '#3 of 42')" — the "42" is meant to be the
  queue's task count, not the file's line count.

## Solution

- In `todo/scripts/todo-next.sh`, count only lines that
  `todo-parse-queue-line` successfully parses (the same filter already
  used inside the main loop) toward the denominator, not raw file
  lines. Simplest fix: build a second array (or increment a counter)
  during the same read loop, counting only successfully-parsed lines,
  and use that count instead of `"${#lines[@]}"`.
- Add a BATS regression test to `tests/todo-next.bats` asserting the
  denominator equals the actual task-entry count when `queue.md` has a
  non-trivial header (reproducing this exact bug).

## Test plan

- [x] BATS: `queue.md` with header prose + N task entries → `todo-next.sh`
      reports `#k of N`, not `#k of <total file lines>` (`tests/todo-next.bats`,
      new case "position denominator counts task entries, not raw queue.md
      lines")
- [x] Manual: run against this repo's live `queue.md`, confirm denominator
      matches `grep -c "^- \[T" dev/TODO/queue.md`

## Done criteria

- [x] `todo-next.sh`'s position denominator counts parsed task entries only — verified by the new BATS test in `tests/todo-next.bats`
- [x] Live run against this repo's `queue.md` shows the correct denominator

## Root cause

- Introduced in `d87e901` (`feat(todo): token-free scripts for /todo list +
  /todo next`, T20260914-359646) — `todo-next.sh`'s `lines` array is built
  by reading every raw line of `queue.md` (header prose + blank lines +
  task entries), and `"${#lines[@]}"` was used directly as the `#N of M`
  denominator instead of counting only the lines `todo-parse-queue-line`
  actually accepts. An oversight, not deliberate — the loop already
  distinguishes parsed vs. unparsed lines via the `continue` on parse
  failure, the denominator just never used that same filter.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `todo/scripts/todo-next.sh` | `25-52` | The bug: added a pre-pass counting only parsed entries (`total_entries`), used it as the denominator instead of `${#lines[@]}` |
| `tests/todo-next.bats` | new case | Regression coverage: header prose + 3 entries → `#k of 3`, not `#k of 9` |

## Closed (2026-09-23)

- Shipped in implementation **PR #120** (claim in **PR #119**, autopilot
  bare auto-pick, design PR skipped per Phase 2's self-evident-bug-fix
  condition).
- `todo/scripts/todo-next.sh`: added a pre-pass over `queue.md`'s raw
  lines that counts only the ones `todo-parse-queue-line` accepts
  (`total_entries`), and used that as the `#N of M` denominator instead
  of `"${#lines[@]}"` (raw file-line count).
- Added one BATS regression case to `tests/todo-next.bats` reproducing
  the exact bug shape (6-line header block + 3 task entries → old code
  reported `of 9`, fixed code reports `of 3`); `bats tests/todo-next.bats`
  10/10 green locally and in CI. `shellcheck todo/scripts/todo-next.sh`
  clean (one pre-existing SC1091 info note on the `_lib.sh` source, not
  introduced by this change).
- Manually verified against this repo's live `queue.md` (10 task
  entries): `todo-next.sh` now reports `#1 of 10`, `#2 of 10`, `#3 of 10`,
  matching `grep -c "^- \[T" dev/TODO/queue.md`.
- No follow-up tasks filed — the fix is complete and self-contained.

## Skills invoked

- TDD (`superpowers:test-driven-development`): partial — the fix itself
  was small and self-evident (one-line root cause already diagnosed in
  the task file), but a new BATS regression case reproducing the exact
  bug shape was written and run (confirmed red on the pre-fix script,
  green after) before the implementation PR.
- Verification (`superpowers:verification-before-completion`): yes — ran
  `bats tests/todo-next.bats` (10/10), `shellcheck`, and a manual live
  run against this repo's own `queue.md` before opening the PR.
- Systematic debugging (`superpowers:systematic-debugging`): no — root
  cause was already fully diagnosed in the task file at claim time; no
  debugging needed.
- Receiving code review (`superpowers:receiving-code-review`): no —
  unattended autopilot run, no reviewer comments to address.
