#!/usr/bin/env bats
# Tests for todo/scripts/todo-next.sh (T20260914-359646).
#
# Hermetic: builds a throwaway dev/TODO/ tree under $BATS_TEST_TMPDIR,
# points the script at it via TODO_QUEUE_DIR, and never touches this repo's
# real dev/TODO/.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/todo/scripts/todo-next.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/dev/TODO"
  cd "$WORK"
}

# Write one task file with the given status (and optional extra frontmatter
# lines) plus a matching queue.md line.
write_task() {
  local id="$1" title="$2" status="$3" extra="${4:-}"
  cat > "dev/TODO/${id}-slug.md" <<EOF
---
status: ${status}
estimation: 1h
${extra}
---

# ${id}: ${title}
EOF
}

append_queue_line() {
  local id="$1" title="$2"
  echo "- [${id}](${id}-slug.md): ${title}" >> dev/TODO/queue.md
}

# --- basic selection ----------------------------------------------------

@test "picks the top 3 non-skipped tasks, in queue order" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "first" "Open"
  write_task T2 "second" "Open"
  write_task T3 "third" "Open"
  write_task T4 "fourth" "Open"
  append_queue_line T1 "first"
  append_queue_line T2 "second"
  append_queue_line T3 "third"
  append_queue_line T4 "fourth"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T1"* ]]
  [[ "$output" == *"T2"* ]]
  [[ "$output" == *"T3"* ]]
  [[ "$output" != *"T4"* ]]
}

@test "skips Done, legacy Revisit, and Parked entries" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "done one" "Done"
  write_task T2 "revisit one" "Revisit"
  write_task T3 "parked one" "Parked"
  write_task T4 "open one" "Open"
  append_queue_line T1 "done one"
  append_queue_line T2 "revisit one"
  append_queue_line T3 "parked one"
  append_queue_line T4 "open one"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T4"* ]]
  [[ "$output" != *"T1"* ]]
  [[ "$output" != *"T2"* ]]
  [[ "$output" != *"T3"* ]]
}

@test "empty queue reports plainly instead of erroring" {
  echo "# TODO Queue" > dev/TODO/queue.md
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no"* || "$output" == *"No"* ]]
}

@test "all-skipped queue reports plainly instead of erroring" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "done one" "Done"
  append_queue_line T1 "done one"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no"* || "$output" == *"No"* ]]
}

@test "position denominator counts task entries, not raw queue.md lines" {
  {
    echo "# TODO Queue"
    echo ""
    echo "Ordered priority queue. Top = highest priority. One line per task, kept in"
    echo "sync with dev/TODO/ by /todo sweep (adds missing, strikes closed/parked)."
    echo "Reordered by /stage and /top."
    echo ""
  } > dev/TODO/queue.md
  write_task T1 "first" "Open"
  write_task T2 "second" "Open"
  write_task T3 "third" "Open"
  append_queue_line T1 "first"
  append_queue_line T2 "second"
  append_queue_line T3 "third"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # 6 header/blank lines + 3 task lines = 9 raw lines; the denominator must
  # be 3 (the task-entry count), not 9 (the old bug).
  [[ "$output" == *"#1 of 3"* ]]
  [[ "$output" == *"#2 of 3"* ]]
  [[ "$output" == *"#3 of 3"* ]]
  [[ "$output" != *"of 9"* ]]
}

# --- step 5: stale-blocker callout ---------------------------------------

@test "flags a top-3 task still Blocked by an open task, pointing at /todo sweep" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "blocked one" "Blocked by T2"
  write_task T2 "the blocker" "Open"
  append_queue_line T1 "blocked one"
  append_queue_line T2 "the blocker"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/todo sweep"* ]]
}

@test "does not flag a Blocked-by status whose blocker file is gone (stale, not this script's job)" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "blocked one" "Blocked by T99"
  append_queue_line T1 "blocked one"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"/todo sweep"* ]]
}

# --- peer mode ------------------------------------------------------------

@test "CCXP_PEER_MODE=0 disables claim filtering" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "peer-claimed" "Coding" "claimed_by: cc1-deadbeef:1234567890abcdef"
  append_queue_line T1 "peer-claimed"

  CCXP_PEER_MODE=0 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T1"* ]]
}

@test "skips a task with a live (non-reclaimable) peer claim, in default peer mode" {
  # A human-override claimed_by (doesn't match the session-shaped
  # cc1-<host>:<hash> or legacy <sid>@<machine> pattern) is NEVER
  # auto-reclaimable per task_claim.sh's own _tc_reclaim_decide — this lets
  # the test stay hermetic (no git/gh mocking needed to fake "recent
  # activity") while still exercising the genuine default-peer-mode path.
  git init -q .
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "live peer claim" "Coding" "claimed_by: Alex"
  write_task T2 "open one" "Open"
  append_queue_line T1 "live peer claim"
  append_queue_line T2 "open one"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T2"* ]]
  [[ "$output" != *"T1"* ]]
}

@test "includes a reclaimable stale peer claim, in default peer mode" {
  # A session-shaped claimed_by (cc1-<host>:<hash>) with no git/PR
  # activity for this id resolves to "reclaimable" by task_claim.sh's own
  # staleness-window logic (both activity signals default to "large" when
  # absent) — hermetic, no mocking needed.
  git init -q .
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T1 "reclaimable" "Coding" "claimed_by: cc1-deadbeef:1234567890abcdef"
  append_queue_line T1 "reclaimable"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T1"* ]]
  [[ "$output" == *"reclaimable"* ]]
}
