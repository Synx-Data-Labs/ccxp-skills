#!/usr/bin/env bats
# Tests for todo/scripts/_lib.sh — shared parsing helpers for todo-list.sh
# and todo-next.sh (T20260914-359646).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
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
