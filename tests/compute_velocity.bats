#!/usr/bin/env bats
# Tests for retro/scripts/compute-velocity.sh — computes rolling XP velocity
# (points_per_week, hours_per_point) from dev/JOURNAL/ completion history
# into dev/velocity.json (T20260924-232855).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/retro/scripts/compute-velocity.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev/JOURNAL" "$WORK/dev/TODO"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name tester
}

commit_dated() {
  local d="$1" msg="$2"
  git -C "$WORK" add -A
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" \
    git -C "$WORK" commit -q -m "$msg"
}

# $1=id $2=points $3=claimant
mk_claimed_todo() {
  local id="$1" points="$2" claimant="$3"
  cat > "$WORK/dev/TODO/${id}-x.md" <<EOF
---
status: In Progress
estimation: $points
claimed_by: $claimant
---

# ${id}: X
EOF
}

# Move a TODO file to JOURNAL with a given close date, as its own commit.
# Mirrors the REAL _session/task_claim.sh release contract (_tc_release,
# called by /drive Phase 4 at close): claimed_by is cleared to empty as
# part of closing, same commit as the journal move — so by the time a
# task lives in dev/JOURNAL/, its claimed_by is ALWAYS empty (verified:
# every dev/JOURNAL/*.md in this repo has an empty claimed_by). A fixture
# that left claimed_by populated after close would never exercise the
# real "derive start time from history, not from the current frontmatter
# value" code path.
# $1=id $2=close-date(YYYY-MM-DD) $3=close-commit-time(ISO8601)
close_task() {
  local id="$1" close_date="$2" close_time="$3"
  sed -i.bak -e 's/^claimed_by:.*/claimed_by:/' -e 's/^status:.*/status: Done/' \
    "$WORK/dev/TODO/${id}-x.md"
  rm -f "$WORK/dev/TODO/${id}-x.md.bak"
  git -C "$WORK" mv "dev/TODO/${id}-x.md" "dev/JOURNAL/${close_date}-${id}-x.md"
  GIT_AUTHOR_DATE="$close_time" GIT_COMMITTER_DATE="$close_time" \
    git -C "$WORK" commit -q -m "close $id"
}

run_script() { run bash "$SCRIPT" --repo-root "$WORK" "$@"; }

@test "zero-sample window writes flat bootstrap defaults" {
  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/velocity.json" ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"bootstrap": true'* ]]
  [[ "$output" == *'"hours_per_point": 1'* ]]
  [[ "$output" == *'"points_per_week": 10'* ]]
  [[ "$output" == *'"sample_size": 0'* ]]
}

@test "single completed task: hours_per_point and points_per_week match hand-computed values" {
  mk_claimed_todo T20260101-000001 2 cc1-abc:1111
  commit_dated "2026-01-05T09:00:00+00:00" "claim"
  close_task T20260101-000001 2026-01-07 "2026-01-07T09:00:00+00:00"
  # claim 2026-01-05T09:00 -> close (the real close-commit timestamp,
  # 2026-01-07T09:00) = exactly 48 hours
  # hours_per_point = 48 / 2 points = 24.0
  # points_per_week = 2 points / 4-week window = 0.5

  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"hours_per_point": 24.0'* ]]
  [[ "$output" == *'"points_per_week": 0.5'* ]]
  [[ "$output" == *'"sample_size": 1'* ]]
  [[ "$output" == *'"bootstrap": false'* ]]
}

@test "median resists an outlier task skewing hours_per_point" {
  # Two normal-pace 1-point tasks (claimed midnight, closed exactly 24h
  # later) and one wildly slow 1-point task (claimed 11+ days earlier) —
  # the median must land on the normal-pace value, not be dragged toward
  # the mean by the outlier.
  mk_claimed_todo T20260101-000001 1 cc1-a:1
  commit_dated "2026-01-01T00:00:00+00:00" "claim 1"
  close_task T20260101-000001 2026-01-02 "2026-01-02T00:00:00+00:00"

  mk_claimed_todo T20260101-000002 1 cc1-b:2
  commit_dated "2026-01-01T00:00:00+00:00" "claim 2"
  close_task T20260101-000002 2026-01-02 "2026-01-02T00:00:00+00:00"

  mk_claimed_todo T20260101-000003 1 cc1-c:3
  commit_dated "2025-12-22T00:00:00+00:00" "claim 3 (slow)"
  close_task T20260101-000003 2026-01-02 "2026-01-02T00:00:00+00:00"

  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"hours_per_point": 24.0'* ]]
}

@test "a task closed outside the trailing window is excluded" {
  mk_claimed_todo T20260101-000001 3 cc1-a:1
  commit_dated "2025-11-01T00:00:00+00:00" "claim long ago"
  close_task T20260101-000001 2025-11-03 "2025-11-03T00:00:00+00:00"

  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"bootstrap": true'* ]]   # excluded -> zero-sample
}

@test "a non-Fibonacci / unmigrated estimation value is skipped, not fatal" {
  cat > "$WORK/dev/TODO/T20260101-000001-x.md" <<'EOF'
---
status: In Progress
estimation: 2h
claimed_by: cc1-a:1
---

# T20260101-000001: X
EOF
  commit_dated "2026-01-05T00:00:00+00:00" "claim (legacy duration)"
  close_task T20260101-000001 2026-01-07 "2026-01-07T00:00:00+00:00"

  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"bootstrap": true'* ]]
}

@test "a task with no claimed_by contributes to points_per_week but not hours_per_point" {
  cat > "$WORK/dev/TODO/T20260101-000001-x.md" <<'EOF'
---
status: In Progress
estimation: 3
claimed_by:
---

# T20260101-000001: X
EOF
  commit_dated "2026-01-05T00:00:00+00:00" "file (no claim, CCXP_PEER_MODE=0 style)"
  close_task T20260101-000001 2026-01-07 "2026-01-07T00:00:00+00:00"

  run_script --today 2026-01-10
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"bootstrap": true'* ]]            # no resolvable sample for hours_per_point
  [[ "$output" == *'"hours_per_point": 1'* ]]         # ...so hours_per_point IS the bootstrap default
  [[ "$output" == *'"points_per_week": 0.75'* ]]      # but points_per_week is real: 3 points / 4-week window
}

@test "window-weeks override changes the points_per_week denominator" {
  mk_claimed_todo T20260101-000001 8 cc1-a:1
  commit_dated "2026-01-05T00:00:00+00:00" "claim"
  close_task T20260101-000001 2026-01-07 "2026-01-07T00:00:00+00:00"

  run_script --today 2026-01-10 --window-weeks 1
  [ "$status" -eq 0 ]
  run cat "$WORK/dev/velocity.json"
  [[ "$output" == *'"points_per_week": 8.0'* ]]
  [[ "$output" == *'"window_weeks": 1'* ]]
}
