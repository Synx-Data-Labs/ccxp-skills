#!/usr/bin/env bats
# Tests for repo-conventions/scripts/migrate-estimation-to-points.sh — the
# one-time, idempotent duration-bucket -> Fibonacci-points migration
# (T20260924-232855 Migration §4).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/repo-conventions/scripts/migrate-estimation-to-points.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev/TODO" "$WORK/dev/JOURNAL"
}

# $1=path (repo-relative) $2=estimation-value $3=extra-frontmatter(optional)
mk_file() {
  local rel="$1" est="$2" extra="${3:-}"
  mkdir -p "$(dirname "$WORK/$rel")"
  {
    echo '---'
    echo "estimation: $est"
    echo 'status: Open'
    [ -n "$extra" ] && echo "$extra"
    echo '---'
    echo
    echo '# Demo task'
    echo
    echo 'Body mentioning estimation: 2h in prose — must NOT be touched.'
  } > "$WORK/$rel"
}

run_script() { run bash "$SCRIPT" --repo-root "$WORK" "$@"; }

@test "maps each legacy duration bucket to its Fibonacci point, including 2w -> 8" {
  mk_file dev/TODO/T20260101-000001-a.md '15m'
  mk_file dev/TODO/T20260101-000002-b.md '30m'
  mk_file dev/TODO/T20260101-000003-c.md '1h'
  mk_file dev/TODO/T20260101-000004-d.md '2h'
  mk_file dev/TODO/T20260101-000005-e.md '4h'
  mk_file dev/TODO/T20260101-000006-f.md '1d'
  mk_file dev/TODO/T20260101-000007-g.md '2d'
  mk_file dev/TODO/T20260101-000008-h.md '1w'
  mk_file dev/TODO/T20260101-000009-i.md '2w'

  run_script
  [ "$status" -eq 0 ]

  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000001-a.md"; [[ "$output" == "estimation: 1" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000002-b.md"; [[ "$output" == "estimation: 1" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000003-c.md"; [[ "$output" == "estimation: 1" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000004-d.md"; [[ "$output" == "estimation: 2" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000005-e.md"; [[ "$output" == "estimation: 2" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000006-f.md"; [[ "$output" == "estimation: 3" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000007-g.md"; [[ "$output" == "estimation: 5" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000008-h.md"; [[ "$output" == "estimation: 8" ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000009-i.md"; [[ "$output" == "estimation: 8" ]]
}

@test "migrates dev/JOURNAL/*.md files too" {
  mk_file dev/JOURNAL/2026-01-01-T20260101-000001-a.md '1d'
  run_script
  [ "$status" -eq 0 ]
  run grep '^estimation:' "$WORK/dev/JOURNAL/2026-01-01-T20260101-000001-a.md"
  [[ "$output" == "estimation: 3" ]]
}

@test "preserves trailing prose on the estimation line" {
  mk_file dev/TODO/T20260101-000001-a.md '2h (S)'
  run_script
  [ "$status" -eq 0 ]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000001-a.md"
  [[ "$output" == "estimation: 2 (S)" ]]
}

@test "idempotent: a second run makes no further changes" {
  mk_file dev/TODO/T20260101-000001-a.md '1d'
  run_script
  [ "$status" -eq 0 ]
  local before; before="$(cat "$WORK/dev/TODO/T20260101-000001-a.md")"

  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"0/"*"file(s) changed"* ]]
  local after; after="$(cat "$WORK/dev/TODO/T20260101-000001-a.md")"
  [ "$before" = "$after" ]
}

@test "already-migrated point value is left untouched" {
  mk_file dev/TODO/T20260101-000001-a.md '5'
  run_script
  [ "$status" -eq 0 ]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000001-a.md"
  [[ "$output" == "estimation: 5" ]]
}

@test "only estimation: changes — status, other frontmatter, and body are untouched" {
  mk_file dev/TODO/T20260101-000001-a.md '1d' 'source: Retro 2026-01-01'
  run_script
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/TODO/T20260101-000001-a.md"
  [[ "$output" == *"status: Open"* ]]
  [[ "$output" == *"source: Retro 2026-01-01"* ]]
  [[ "$output" == *"Body mentioning estimation: 2h in prose — must NOT be touched."* ]]
}

@test "--dry-run reports what would change without writing" {
  mk_file dev/TODO/T20260101-000001-a.md '1d'
  run_script --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) 1/1 file(s) would change"* ]]
  run grep '^estimation:' "$WORK/dev/TODO/T20260101-000001-a.md"
  [[ "$output" == "estimation: 1d" ]]
}

@test "a non-task file with no frontmatter (e.g. queue.md) is left alone" {
  echo '# TODO Queue' > "$WORK/dev/TODO/queue.md"
  run_script
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/TODO/queue.md"
  [[ "$output" == '# TODO Queue' ]]
}
