---
status: Open
estimation: 15m
source: /drive cycle, discovered using todo/scripts/todo-next.sh live after merging T20260914-359646
related: T20260914-359646
description: todo-next.sh's "#N of M" denominator counts raw queue.md file lines, not actual task entries
---

# T20260922-263110: `todo-next.sh`'s "#N of M" denominator counts raw file lines, not task entries

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

- [ ] BATS: `queue.md` with header prose + N task entries → `todo-next.sh`
      reports `#k of N`, not `#k of <total file lines>` (`tests/todo-next.bats`)
- [ ] Manual: run against this repo's live `queue.md`, confirm denominator
      matches `grep -c "^- \[T" dev/TODO/queue.md`

## Done criteria

- [ ] `todo-next.sh`'s position denominator counts parsed task entries only — verified by the new BATS test in `tests/todo-next.bats`
- [ ] Live run against this repo's `queue.md` shows the correct denominator
