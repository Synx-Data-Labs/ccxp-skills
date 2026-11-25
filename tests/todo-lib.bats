#!/usr/bin/env bats
# Tests for todo/scripts/_lib.sh — shared parsing helpers for todo-list.sh
# and todo-next.sh (T20260914-359646).

load test_helper
setup() {
  source "$REPO_ROOT/todo/scripts/_lib.sh"
}

# --- todo-parse-queue-line ---------------------------------------------------

@test "parses a well-formed queue.md line" {
  run todo-parse-queue-line '- [T20260702-947261](T20260702-947261-registry-token-rotation-baked-images.md): Container images with a token baked in'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'T20260702-947261\tT20260702-947261-registry-token-rotation-baked-images.md\tContainer images with a token baked in')" ]
}

@test "rejects a non-matching line (header/prose)" {
  run todo-parse-queue-line 'Ordered priority queue. Top = highest priority.'
  [ "$status" -eq 1 ]
}

@test "rejects a blank line" {
  run todo-parse-queue-line ''
  [ "$status" -eq 1 ]
}

# --- todo-fm-get --------------------------------------------------------------

@test "reads a present frontmatter field" {
  local f="$BATS_TEST_TMPDIR/t1.md"
  cat > "$f" <<'EOF'
---
status: Open
estimation: 2h
deadline: 2026-06-30
---

# T1: title
EOF
  run todo-fm-get "$f" status
  [ "$status" -eq 0 ]
  [ "$output" = "Open" ]
}

@test "reads a numeric-looking field (deadline) as a plain string" {
  local f="$BATS_TEST_TMPDIR/t2.md"
  cat > "$f" <<'EOF'
---
status: Open
deadline: 2026-06-30
---

# T2: title
EOF
  run todo-fm-get "$f" deadline
  [ "$output" = "2026-06-30" ]
}

@test "prints empty for an absent field" {
  local f="$BATS_TEST_TMPDIR/t3.md"
  cat > "$f" <<'EOF'
---
status: Open
---

# T3: title
EOF
  run todo-fm-get "$f" deadline
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- todo-claim-state ---------------------------------------------------------

# --- todo-current-monday -------------------------------------------------

@test "returns the same date when today is already a Monday" {
  SESSION_TODAY=2026-09-21 run todo-current-monday
  [ "$status" -eq 0 ]
  [ "$output" = "2026-09-21" ]
}

@test "returns THIS week's Monday (in the past), not next Monday, on a Tuesday" {
  # The bug this test guards against: `date -d 'monday'` (no last/next
  # qualifier) resolves to the NEXT occurrence of that weekday on any day
  # that isn't itself Monday — one week too late for "this week's Monday"
  # (caught by an independent PR #73 review, 2026-09-22).
  SESSION_TODAY=2026-09-22 run todo-current-monday
  [ "$status" -eq 0 ]
  [ "$output" = "2026-09-21" ]
}

@test "returns this week's Monday on a Sunday (end of the ISO week)" {
  SESSION_TODAY=2026-09-27 run todo-current-monday
  [ "$status" -eq 0 ]
  [ "$output" = "2026-09-21" ]
}

@test "CCXP_PEER_MODE=0 always reports unclaimed, regardless of actual claim state" {
  CCXP_PEER_MODE=0 run todo-claim-state T4
  [ "$status" -eq 0 ]
  [ "$output" = "unclaimed" ]
}

# --- todo-tier ----------------------------------------------------------------

@test "todo-tier: reads 1..4, defaults to 3 when absent or invalid" {
  d="$BATS_TEST_TMPDIR"
  for t in 1 2 3 4; do printf -- '---\nstatus: Open\ntier: %s\n---\n' "$t" > "$d/t$t.md"; [ "$(todo-tier "$d/t$t.md")" = "$t" ]; done
  printf -- '---\nstatus: Open\n---\n' > "$d/none.md"; [ "$(todo-tier "$d/none.md")" = 3 ]
  printf -- '---\nstatus: Open\ntier: 9\n---\n' > "$d/bad.md"; [ "$(todo-tier "$d/bad.md")" = 3 ]
  printf -- '---\nstatus: Open\ntier: 2  # urgent\n---\n' > "$d/c.md"; [ "$(todo-tier "$d/c.md")" = 2 ]
}

# --- todo-deps (compat reader, T20261124-320024) ------------------------------

mk_dep_task() {
  # $1 = file, rest = frontmatter lines
  local f="$1"; shift
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n\n# T20260611-000001: x\n'; } > "$f"
}

@test "todo-deps reads a flow-list depends_on" {
  mk_dep_task "$BATS_TEST_TMPDIR/t.md" "status: In Progress" "estimation: 1" "depends_on: [T20260611-000010, T20260611-000020]"
  run todo-deps "$BATS_TEST_TMPDIR/t.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'T20260611-000010\nT20260611-000020')" ]
}

@test "todo-deps reads a block-list depends_on and stops at the next key" {
  mk_dep_task "$BATS_TEST_TMPDIR/t.md" "status: Open" "depends_on:" "  - T20260611-000010" "  - T20260611-000020" "blocks: [T20260611-000099]"
  run todo-deps "$BATS_TEST_TMPDIR/t.md"
  [ "$output" = "$(printf 'T20260611-000010\nT20260611-000020')" ]
}

@test "todo-deps reads a legacy Blocked by status and merges without duplicates" {
  mk_dep_task "$BATS_TEST_TMPDIR/t.md" "status: Blocked by T20260611-000020 and T20260611-000030 - waiting" "depends_on: [T20260611-000010, T20260611-000020]"
  run todo-deps "$BATS_TEST_TMPDIR/t.md"
  [ "$output" = "$(printf 'T20260611-000010\nT20260611-000020\nT20260611-000030')" ]
}

@test "todo-deps prints nothing for a task with no dependencies" {
  mk_dep_task "$BATS_TEST_TMPDIR/t.md" "status: Open" "estimation: 1" "blocks: [T20260611-000099]"
  run todo-deps "$BATS_TEST_TMPDIR/t.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a task with only depends_on is not gated; the legacy status word still is" {
  run todo-gated "In Progress"
  [ "$status" -ne 0 ]
  run todo-gated "Blocked by T20260611-000010"
  [ "$status" -eq 0 ]
  run todo-gated "Blocked by person:person-a"
  [ "$status" -eq 0 ]
}

@test "todo-gated: BLOCKED, SUPERVISED, needs manual and sign-off words are no gate (d174)" {
  local s
  for s in "In Progress — SUPERVISED (needs VPN)" "Open — BLOCKED upstream" "Review — needs manual QA" "Open — sign-off pending" "Open — UNBLOCKED now"; do
    run todo-gated "$s"
    [ "$status" -ne 0 ]
  done
}

@test "todo-deps reads an unindented block list, CRLF files and ignores comments" {
  printf -- '---\r\nstatus: Open\r\ndepends_on:\r\n- T20260611-000010 # was T20260611-000099\r\n# note\r\n- T20260611-000020\r\nblocks: []\r\n---\r\n' > "$BATS_TEST_TMPDIR/t.md"
  run todo-deps "$BATS_TEST_TMPDIR/t.md"
  [ "$output" = "$(printf 'T20260611-000010\nT20260611-000020')" ]
}
