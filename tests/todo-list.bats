#!/usr/bin/env bats
# Tests for todo/scripts/todo-list.sh (T20260914-359646).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/todo/scripts/todo-list.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/dev/TODO" "$WORK/dev/PARKING"
  cd "$WORK"
}

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

@test "renders the 8-column table with a header row" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "first" "Open"
  append_queue_line T20260914-100001 "first"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#"*"ID"*"Title"*"Status"*"Est"*"Deadline"*"Scheduled"*"Claimed"* ]]
  [[ "$output" == *"T20260914-100001"* ]]
}

@test "shows total and by-status counts" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "first" "Open"
  write_task T20260914-100002 "second" "Done"
  append_queue_line T20260914-100001 "first"
  append_queue_line T20260914-100002 "second"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total: 2"* ]]
}

@test "shows the parking-lot count" {
  echo "# TODO Queue" > dev/TODO/queue.md
  echo "---" > dev/PARKING/T20260914-100009-slug.md
  echo "status: Parked" >> dev/PARKING/T20260914-100009-slug.md
  echo "---" >> dev/PARKING/T20260914-100009-slug.md

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parking lot: 1 parked"* ]]
}

@test "detects an untracked task file not in queue.md" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "untracked" "Open"
  # Deliberately not appended to queue.md

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"untracked"* ]]
  [[ "$output" == *"T20260914-100001"* ]]
}

@test "detects a stale queue.md line with no matching file" {
  echo "# TODO Queue" > dev/TODO/queue.md
  append_queue_line T20260914-100099 "ghost"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"T20260914-100099"* ]]
}

@test "detects a stale Blocked-by reference" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "blocked" "Blocked by T20260914-100099"
  append_queue_line T20260914-100001 "blocked"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260914-100001"* ]]
  [[ "$output" == *"T20260914-100099"* ]]
}

@test "correctly counts a task scheduled for THIS week's Monday as committed, on a mid-week run" {
  # Regression test for a real bug: `date -d 'monday'` resolves to NEXT
  # Monday on any non-Monday day, undercounting "committed to active
  # iteration" 6 days out of 7 (caught by an independent PR #73 review).
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "this week" "Open" "scheduled: 2026-09-21"
  append_queue_line T20260914-100001 "this week"

  SESSION_TODAY=2026-09-22 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 committed to active iteration"* ]]
}

@test "marks a past-deadline row with a warning marker" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "overdue" "Open" "deadline: 2026-01-01"
  append_queue_line T20260914-100001 "overdue"

  SESSION_TODAY=2026-09-22 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠"* ]]
}

@test "appends a checkmark to a Scheduled date landed in the active iteration" {
  echo "# TODO Queue" > dev/TODO/queue.md
  write_task T20260914-100001 "scheduled" "Open" "scheduled: 2026-09-21"
  append_queue_line T20260914-100001 "scheduled"

  SESSION_TODAY=2026-09-22 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-09-21 ✓"* ]]
}

@test "detects a stale Blocked-by reference inside a body ## Dependencies section" {
  echo "# TODO Queue" > dev/TODO/queue.md
  cat > "dev/TODO/T20260914-100001-slug.md" <<'EOF'
---
status: Open
estimation: 1h
---

# T20260914-100001: title

## Dependencies

- **T20260914-100099** — some prerequisite
EOF
  append_queue_line T20260914-100001 "title"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260914-100001"* ]]
  [[ "$output" == *"T20260914-100099"* ]]
}

@test "empty queue still renders a header and zero counts, no error" {
  echo "# TODO Queue" > dev/TODO/queue.md

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total: 0"* ]]
}
