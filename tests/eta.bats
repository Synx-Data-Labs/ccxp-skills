#!/usr/bin/env bats
# Tests for eta/scripts/eta.sh — projects a finish time for the current (or
# an explicit) task from its estimation: points (points * hours_per_point,
# read from dev/velocity.json — T20260924-232855) and the git-log-S-derived
# start time of its claimed_by: line (T20260922-453135).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/eta/scripts/eta.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  export CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$WORK/dev/TODO"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name tester
  source "$REPO_ROOT/_session/claimant-id.sh"
}

# commit everything with an injected author/committer date. $1=ISO8601 $2=msg
commit_dated() {
  local d="$1" msg="$2"
  git -C "$WORK" add -A
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" \
    git -C "$WORK" commit -q -m "$msg"
}

# $1=path-rel $2=estimation $3=claimed_by (may be empty)
mk_task() {
  {
    echo '---'
    echo 'status: In Progress'
    echo "estimation: $2"
    echo "claimed_by: $3"
    echo '---'
    echo
    echo '# Task'
  } > "$WORK/$1"
}

run_script() { run bash "$SCRIPT" --repo-root "$WORK" "$@"; }

@test "resolves current task via claimed_by auto-detection" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '1' "$me"
  commit_dated "2026-01-01T00:00:00+00:00" 'claim task'

  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260101-000001"* ]]
}

@test "resolves explicit T<id> even when a different task is claimed" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '1' "$me"
  mk_task dev/TODO/T20260101-000002-y.md '2' ''
  commit_dated "2026-01-01T00:00:00+00:00" 'claim first task'

  run_script T20260101-000002
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260101-000002"* ]]
}

@test "no current task: exit 1 with a clear message when nothing is claimed" {
  mk_task dev/TODO/T20260101-000001-x.md '1' ''
  commit_dated "2026-01-01T00:00:00+00:00" 'file task'

  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"no current task"* ]]
}

@test "duration mapping covers all 5 Fibonacci point values (bootstrap hours_per_point=1)" {
  local me; me="$(claimant_id "$WORK")"
  local i=1
  for pts in 1 2 3 5 8; do
    mk_task "dev/TODO/T2026010${i}-00000${i}-x.md" "$pts" "$me"
    commit_dated "2026-01-0${i}T00:00:00+00:00" "claim $pts-point task"
    run_script "T2026010${i}-00000${i}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"estimation: $pts"* ]]
    i=$((i+1))
  done
}

@test "unrecognized estimation value errors clearly" {
  mk_task dev/TODO/T20260101-000001-x.md '3h' ''
  commit_dated "2026-01-01T00:00:00+00:00" 'file task'

  run_script T20260101-000001
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized estimation value"* ]]
}

@test "non-Fibonacci integer (4) is rejected" {
  mk_task dev/TODO/T20260101-000001-x.md '4' ''
  commit_dated "2026-01-01T00:00:00+00:00" 'file task'

  run_script T20260101-000001
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized estimation value"* ]]
}

@test "missing dev/velocity.json falls back to hours_per_point=1 bootstrap" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '2' "$me"
  commit_dated "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" 'claim task'

  run_script T20260101-000001
  [ "$status" -eq 0 ]
  # 2 points * 1h/point bootstrap = 2h total; near-zero elapsed → ~1h59m remaining
  [[ "$output" == *"remaining:  1h59m"* || "$output" == *"remaining:  2h0m"* ]]
}

@test "dev/velocity.json's hours_per_point scales the projected duration" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '2' "$me"
  cat > "$WORK/dev/velocity.json" <<'JSON'
{"hours_per_point": 3, "points_per_week": 9, "computed_at": "2026-01-01", "window_weeks": 4, "sample_size": 14, "bootstrap": false}
JSON
  commit_dated "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" 'claim task'

  run_script T20260101-000001
  [ "$status" -eq 0 ]
  # 2 points * 3h/point = 6h total; near-zero elapsed → ~5h59m remaining
  [[ "$output" == *"remaining:  5h59m"* || "$output" == *"remaining:  6h0m"* ]]
}

@test "start-time-unknown fallback when git log -S finds no claimed_by commit" {
  # claimed_by is set but was NEVER introduced via a commit that added this
  # exact line (simulates the CCXP_PEER_MODE=0 bypass this task's design
  # calls out) — mk_task + commit_dated below writes it in the FIRST commit,
  # so git log -S (which only matches commits that CHANGE the occurrence
  # count of the string) finds no match for a string present since the file's
  # birth with no prior absence to diff against... to force the "truly no
  # match" path, use a claimed_by value that never appears in any commit.
  mk_task dev/TODO/T20260101-000001-x.md '1' 'cc1-deadbeef:0000000000000000'
  commit_dated "2026-01-01T00:00:00+00:00" 'file task'
  # Rewrite claimed_by to a DIFFERENT value WITHOUT committing the change, so
  # the frontmatter (read off disk) carries a value no commit ever introduced
  # — git log -S finds no match, forcing the fallback path.
  sed -i 's/cc1-deadbeef:0000000000000000/cc1-neverseen:1111111111111111/' \
    "$WORK/dev/TODO/T20260101-000001-x.md"

  run_script T20260101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == *"start time unknown"* ]]
}

@test "--tz override changes the rendered finish time" {
  # A CI/dev sandbox commonly defaults its own TZ to UTC, so asserting only
  # "output contains UTC" after --tz UTC wouldn't distinguish "the override
  # worked" from "the override was silently ignored and the default branch
  # happened to also print UTC." Force the process TZ to something else so
  # the override is the ONLY thing that can make America/New_York's
  # abbreviation (EST/EDT) appear.
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '1' "$me"
  commit_dated "2026-01-01T00:00:00+00:00" 'claim task'

  TZ="Asia/Tokyo" run bash "$SCRIPT" --repo-root "$WORK" --tz America/New_York T20260101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == *"ES"* || "$output" == *"ED"* ]]   # EST or EDT, never JST
  [[ "$output" != *"JST"* ]]
}

@test "--tz with an invalid zone exits 2 with a clear error" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '1' "$me"
  commit_dated "2026-01-01T00:00:00+00:00" 'claim task'

  run_script --tz Not/AZone T20260101-000001
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid timezone"* ]]
}

@test "overdue task reports 'overdue by' instead of a negative remaining" {
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '1' "$me"
  commit_dated "2020-01-01T00:00:00+00:00" 'claim task long ago'

  run_script T20260101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == *"overdue by"* ]]
}

@test "estimation: 8 (top of the Fibonacci scale) is recognized, not rejected" {
  # Commit "now" so elapsed is near-zero and this exercises the "remaining"
  # (not overdue) branch, confirming the top-end point value maps to a real
  # duration rather than failing "unrecognized estimation value" — same
  # saturation-boundary regression class as the old 2w-bucket check
  # (T20260922-270158), now against the points enum's own top value.
  local me; me="$(claimant_id "$WORK")"
  mk_task dev/TODO/T20260101-000001-x.md '8' "$me"
  commit_dated "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" 'claim 8-point task'

  run_script T20260101-000001
  [ "$status" -eq 0 ]
  [[ "$output" != *"unrecognized estimation value"* ]]
  [[ "$output" == *"estimation: 8"* ]]
  [[ "$output" == *"remaining:"* ]]
}

@test "a malformed T<id> argument is rejected before any file lookup (regression, T20260922-270158)" {
  run_script 'T../../PARKING/x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a valid task id"* ]]
}
