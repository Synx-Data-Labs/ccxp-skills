#!/usr/bin/env bats
# Tests for todo/scripts/todo-deps.sh (T20261125-366351): dependants + migrate.
# Hermetic: a throwaway board under $BATS_TEST_TMPDIR; never touches real dev/TODO.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$REPO_ROOT/todo/scripts/todo-deps.sh"
  BOARD="$BATS_TEST_TMPDIR/dev/TODO"
  mkdir -p "$BOARD"
}

task() { # id extra-frontmatter-lines
  { printf -- '---\nstatus: Open\nestimation: 1\n'; [ -n "${2:-}" ] && printf '%b\n' "$2"; printf -- '---\n\n# %s: t\n\nbody\n' "$1"; } > "$BOARD/$1-x.md"
}

fm() { sed -n '/^---$/,/^---$/p' "$BOARD/$1-x.md"; }

fixture() {
  task T20260101-000001 'blocks: [T20260101-000002, T20260101-000003]  # holds both'
  task T20260101-000002 'depends_on: [T20260101-000009]'
  task T20260101-000003 ''
  task T20260101-000004 'blocks:\n  - T20260101-000003\n  - T20260101-000777'
  task T20260101-000005 'blocks: [T20260101-000002]\ndepends_on: [T20260101-000001]'
  task T20260101-000009 ''
}

@test "dependants: derived from depends_on, legacy blocks read with a warning" {
  fixture
  run --separate-stderr bash "$SCRIPT" dependants T20260101-000001 --dir "$BOARD"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'T20260101-000005\nT20260101-000002\nT20260101-000003')" ]
  [[ "$stderr" == *"legacy blocks:"* ]]
}

@test "migrate --dry-run reports every relation and writes nothing" {
  fixture
  before="$(cat "$BOARD"/*.md | cksum)"
  run bash "$SCRIPT" migrate --dry-run --dir "$BOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"T20260101-000001 blocks T20260101-000002: added in T20260101-000002 depends_on"* ]]
  [[ "$output" == *"T20260101-000004 blocks T20260101-000777: unknown id"* ]]
  [[ "$output" == *"T20260101-000005 blocks T20260101-000002"* ]]
  [[ "$output" == *"SUMMARY files-with-blocks=3 relations=5 added=4 already=0 unknown=1 self=0 cannot=0 (nothing written)"* ]]
  [ "$before" = "$(cat "$BOARD"/*.md | cksum)" ]
}

@test "migrate rewrites blocks into depends_on on the other task, dedups, keeps notes" {
  fixture
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  # blocks keys are gone, except the entry that could not be placed
  run grep -c '^blocks:' "$BOARD/T20260101-000001-x.md"; [ "$output" = 0 ]
  run grep -c '^blocks:' "$BOARD/T20260101-000005-x.md"; [ "$output" = 0 ]
  grep -q '^blocks: \[T20260101-000777\]$' "$BOARD/T20260101-000004-x.md"
  # depends_on: existing flow list extended, created when absent, no duplicates
  grep -q '^depends_on: \[T20260101-000009, T20260101-000001, T20260101-000005\]$' "$BOARD/T20260101-000002-x.md"
  grep -q '^depends_on: \[T20260101-000001, T20260101-000004\]$' "$BOARD/T20260101-000003-x.md"
  # body untouched
  grep -q '^body$' "$BOARD/T20260101-000002-x.md"
}

@test "migrate is idempotent" {
  fixture
  bash "$SCRIPT" migrate --dir "$BOARD" >/dev/null
  after="$(cat "$BOARD"/*.md | cksum)"
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"files-with-blocks=1 relations=1 added=0 already=0 unknown=1 self=0 cannot=0"* ]]
  [ "$after" = "$(cat "$BOARD"/*.md | cksum)" ]
}

@test "migrate extends a block-list depends_on and keeps a trailing comment" {
  task T20260101-000001 'blocks: [T20260101-000002]'
  task T20260101-000002 'depends_on:\n  - T20260101-000009  # why'
  task T20260101-000009 ''
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  run fm T20260101-000002
  [[ "$output" == *"  - T20260101-000009  # why"* ]]
  [[ "$output" == *"  - T20260101-000001"* ]]
}

@test "migrate: usage errors exit 2" {
  run bash "$SCRIPT" nonsense
  [ "$status" -eq 2 ]
}

@test "migrate parses a multi-line flow blocks list" {
  printf -- '---\nstatus: Open\nestimation: 1\nblocks: [\n  T20260101-000002,\n  T20260101-000003\n]\n---\n\n# t\n' > "$BOARD/T20260101-000001-x.md"
  task T20260101-000002 ''
  task T20260101-000003 ''
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relations=2 added=2"* ]]
  run cat "$BOARD/T20260101-000001-x.md"
  [[ "$output" != *"T20260101-000002,"* ]]
  [[ "$output" != *"]"* ]]
  grep -q '^depends_on: \[T20260101-000001\]$' "$BOARD/T20260101-000002-x.md"
}

@test "migrate leaves a multi-line flow depends_on target and a frontmatter-less target alone, reporting both" {
  task T20260101-000001 'blocks: [T20260101-000002, T20260101-000003]'
  printf -- '---\nstatus: Open\nestimation: 1\ndepends_on: [\n  T20260101-000009,\n  T20260101-000008\n]\n---\n\n# t\n' > "$BOARD/T20260101-000002-x.md"
  printf 'no frontmatter\n' > "$BOARD/T20260101-000003-x.md"
  before2="$(cat "$BOARD/T20260101-000002-x.md" "$BOARD/T20260101-000003-x.md" | cksum)"
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot=2"* ]]
  grep -q '^blocks: \[T20260101-000002, T20260101-000003\]$' "$BOARD/T20260101-000001-x.md"
  [ "$before2" = "$(cat "$BOARD/T20260101-000002-x.md" "$BOARD/T20260101-000003-x.md" | cksum)" ]
}

@test "migrate reports a trailing note on the blocks line and a duplicate id across dirs" {
  task T20260101-000001 'blocks: [T20260101-000002]  # because reasons'
  task T20260101-000002 ''
  mkdir -p "$BATS_TEST_TMPDIR/dev/PARKING"
  printf -- '---\nstatus: Open\nestimation: 1\n---\n' > "$BATS_TEST_TMPDIR/dev/PARKING/T20260101-000002-y.md"
  run bash "$SCRIPT" migrate --dir "$BOARD" --dir "$BATS_TEST_TMPDIR/dev/PARKING"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note on blocks line not carried over: because reasons"* ]]
  [[ "$output" == *"duplicate id T20260101-000002"* ]]
}

@test "migrate keeps CRLF line endings consistent" {
  printf -- '---\r\nstatus: Open\r\nestimation: 1\r\nblocks: [T20260101-000002]\r\n---\r\n# t\r\n' > "$BOARD/T20260101-000001-x.md"
  printf -- '---\r\nstatus: Open\r\nestimation: 1\r\n---\r\n# t\r\n' > "$BOARD/T20260101-000002-x.md"
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  [ -z "$(grep -L $'\r' "$BOARD/T20260101-000002-x.md")" ]
  [ "$(grep -c $'\r$' "$BOARD/T20260101-000002-x.md")" = "$(wc -l < "$BOARD/T20260101-000002-x.md" | tr -d ' ')" ]
}

@test "migrate keeps scalar depends_on ids, never overwrites free text, reports block-list notes" {
  task T20260101-000001 'blocks:\n  - T20260101-000002  # why b\n  - T20260101-000003  # why c\n  - T20260101-000004'
  task T20260101-000002 'depends_on: T20260101-000009, T20260101-000008'
  task T20260101-000003 'depends_on: waits on the vendor'
  task T20260101-000004 ''
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  grep -q '^depends_on: \[T20260101-000009, T20260101-000008, T20260101-000001\]$' "$BOARD/T20260101-000002-x.md"
  grep -q '^depends_on: waits on the vendor$' "$BOARD/T20260101-000003-x.md"
  grep -q '^blocks: \[T20260101-000003\]$' "$BOARD/T20260101-000001-x.md"
  [[ "$output" == *"not carried over: why b"* && "$output" == *"not carried over: why c"* ]]
}

@test "migrate: a trailing comma in a flow depends_on stays valid; an id-less blocks line is reported" {
  task T20260101-000001 'blocks: [T20260101-000002]'
  task T20260101-000002 'depends_on: [T20260101-000009,]'
  task T20260101-000003 'blocks: nothing yet'
  run bash "$SCRIPT" migrate --dir "$BOARD"
  [ "$status" -eq 0 ]
  grep -q '^depends_on: \[T20260101-000009, T20260101-000001\]$' "$BOARD/T20260101-000002-x.md"
  [[ "$output" == *"T20260101-000003: blocks line names no task id, removed: blocks: nothing yet"* ]]
}

@test "todo_deps_migrate.py: no directory argument is a usage error" {
  [ -f "$REPO_ROOT/todo/scripts/todo_deps_migrate.py" ]
  run python3 -I "$REPO_ROOT/todo/scripts/todo_deps_migrate.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: todo_deps_migrate.py"* ]]
}
