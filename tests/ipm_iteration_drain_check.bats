#!/usr/bin/env bats
#
# Unit tests for _ipm/ipm-iteration-drain-check.sh (T20260622-147834; made
# file-only by T20261005-554581 — no GitHub Project board, no `gh`, no
# network; reads dev/TODO/*.md frontmatter directly).
#
# Strategy: the gate is a pure transformation over a directory of task files —
# resolve the previous iteration's Monday by calendar (or --prev-start), then
# find non-terminal `scheduled:` matches. Every test builds a throwaway
# --todo-dir under $BATS_TEST_TMPDIR so nothing touches this repo's own
# dev/TODO/, and pins "today" with --today (or --prev-start) so the gate never
# depends on the wall clock.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_ROOT/_ipm/ipm-iteration-drain-check.sh"

setup() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
  TODO_DIR="$BATS_TEST_TMPDIR/dev-todo"
  mkdir -p "$TODO_DIR"
}

_task() {
  # _task <file> <status> <scheduled>
  cat > "$TODO_DIR/$1" <<EOF
---
status: $2
scheduled: $3
estimation: 1
---

# $1
EOF
}

@test "clean previous iteration (all terminal) -> exit 0" {
  _task "t1.md" "Done" "2026-06-15"
  _task "t2.md" "In Progress" "2026-06-22"   # current iteration, irrelevant
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-15"* ]]
}

@test "non-terminal task scheduled into the previous iteration -> exit 1 and lists it" {
  _task "t1.md" "Done" "2026-06-15"
  _task "stranded.md" "In Progress" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stranded.md"* ]]
  [[ "$output" == *"In Progress"* ]]
}

@test "previous = current Monday minus 7 days, not an older iteration" {
  # today 2026-06-23 -> current Monday 2026-06-22, previous 2026-06-15. A task
  # scheduled two weeks back (2026-06-08) must NOT be treated as an offender.
  _task "old.md" "Open" "2026-06-08"
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"old.md"* ]]
}

@test "--prev-start override targets a specific Monday" {
  _task "stranded.md" "Open" "2026-06-15"
  # Force previous=2026-06-08: the 06-15 offender is now irrelevant.
  run ipm-iteration-drain-check --prev-start 2026-06-08 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-08"* ]]
}

@test "future-dated tasks are excluded by the today window" {
  # today 2026-06-16 -> current Monday 2026-06-15, previous 2026-06-08. A task
  # scheduled 2026-06-15 is the *current* iteration, not the previous one.
  _task "current-iter.md" "Open" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-16 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-08"* ]]
  [[ "$output" != *"current-iter.md"* ]]
}

@test "Parked task on the previous iteration is terminal (not an offender)" {
  _task "set-aside.md" "Parked" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"set-aside.md"* ]]
}

@test "--terminal override can make Parked an offender (strict mode)" {
  _task "set-aside.md" "Parked" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-23 --terminal "Done" --todo-dir "$TODO_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"set-aside.md"* ]]
}

@test "a compound 'Blocked by T...' status is non-terminal" {
  _task "blocked.md" "Blocked by T20260101-000001" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked.md"* ]]
}

@test "Review status is non-terminal (an empty-claim Review would still be an offender)" {
  _task "review.md" "Review" "2026-06-15"
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"review.md"* ]]
}

@test "empty --todo-dir (no task files) -> exit 0" {
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 0 ]
}

@test "missing --todo-dir -> exit 2 with a clear error" {
  run ipm-iteration-drain-check --today 2026-06-23 --todo-dir "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "unknown argument -> exit 2 with usage" {
  run ipm-iteration-drain-check --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* || "$output" == *"unknown arg"* ]]
}

@test "--help prints usage and exits 0" {
  run ipm-iteration-drain-check --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "sourceable without side effects" {
  run source "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no --home-repo/--owner/board flags remain, and gh need not be on PATH" {
  ! grep -qE -- "--home-repo|--owner|--project\b|ROADMAP_TARGET_REPO|GH_TOKEN" "$SCRIPT"
  # Functional guarantee: the check runs correctly with no `gh` binary
  # reachable at all (a bare, empty PATH plus coreutils, no gh/jq).
  _task "stranded.md" "Open" "2026-06-15"
  run env -i PATH="/usr/bin:/bin" HOME="$HOME" \
    bash "$SCRIPT" --today 2026-06-23 --todo-dir "$TODO_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stranded.md"* ]]
}
