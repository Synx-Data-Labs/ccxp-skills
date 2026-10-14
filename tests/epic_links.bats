#!/usr/bin/env bats
# Tests for _taskid/epic-links.sh — clickable epic member lines — and the
# dev/EPICS/E*.md support in ccxp/scripts/epic-status.sh.
# Hermetic: throwaway repo under $BATS_TEST_TMPDIR; no network, no gh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/_taskid/epic-links.sh"
  STATUS="$REPO_ROOT/ccxp/scripts/epic-status.sh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/dev/TODO" "$R/dev/PARKING" "$R/dev/JOURNAL" "$R/dev/EPICS"
  cd "$R"
  git init -q .
  git remote add origin git@github.com:o/r.git
  printf -- '---\nstatus: Open\n---\n\n# T20260101-000001: Open one\n' > dev/TODO/T20260101-000001-open.md
  printf -- '---\nstatus: Done\n---\n' > dev/JOURNAL/2026-02-02-T20260101-000002-done.md
  printf -- '---\nstatus: Parked\n---\n' > dev/PARKING/T20260101-000003-parked.md
  cat > dev/EPICS/E1-x.md <<'EOF'
### E1 — Thing

Goal: g

- T20260101-000001 — Open one
- [T20260101-000002](../TODO/T20260101-000002-done.md) — Done one
- T20260101-000003 (note)
- T20260101-999999 — ghost
EOF
}

@test "sync: converts plain, repoints moved, keeps title/notes, leaves missing plain + reports" {
  run bash "$SCRIPT" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260101-999999"* ]]
  grep -qF -- '- [T20260101-000001](../TODO/T20260101-000001-open.md) — Open one' dev/EPICS/E1-x.md
  grep -qF -- '- [T20260101-000002](../JOURNAL/2026-02-02-T20260101-000002-done.md) — Done one' dev/EPICS/E1-x.md
  grep -qF -- '- [T20260101-000003](../PARKING/T20260101-000003-parked.md) (note)' dev/EPICS/E1-x.md
  grep -qF -- '- T20260101-999999 — ghost' dev/EPICS/E1-x.md
}

@test "sync: idempotent" {
  bash "$SCRIPT" sync 2>/dev/null
  cp dev/EPICS/E1-x.md "$BATS_TEST_TMPDIR/once"
  bash "$SCRIPT" sync 2>/dev/null
  cmp "$BATS_TEST_TMPDIR/once" dev/EPICS/E1-x.md
}

@test "sync: follows a task moved TODO -> JOURNAL" {
  bash "$SCRIPT" sync 2>/dev/null
  mv dev/TODO/T20260101-000001-open.md dev/JOURNAL/2026-03-03-T20260101-000001-open.md
  bash "$SCRIPT" sync 2>/dev/null
  grep -qF '(../JOURNAL/2026-03-03-T20260101-000001-open.md)' dev/EPICS/E1-x.md
}

@test "lint: fails on a dangling link, passes after sync" {
  run bash "$SCRIPT" lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"T20260101-000002"* ]]
  bash "$SCRIPT" sync 2>/dev/null
  run bash "$SCRIPT" lint
  [ "$status" -eq 0 ]
}

@test "add: appends a linked line with the task H1 as title; no-op when already listed" {
  run bash "$SCRIPT" add E1 T20260101-000001
  [ "$status" -eq 0 ]
  n="$(grep -c 'T20260101-000001' dev/EPICS/E1-x.md)"
  [ "$n" -eq 1 ]   # already listed as plain: untouched
  printf -- '---\nstatus: Open\n---\n\n# T20260505-000009: New thing\n' > dev/TODO/T20260505-000009-new.md
  bash "$SCRIPT" add E1 T20260505-000009
  grep -qF -- '- [T20260505-000009](../TODO/T20260505-000009-new.md) — New thing' dev/EPICS/E1-x.md
  bash "$SCRIPT" add E1 T20260505-000009
  [ "$(grep -c 'T20260505-000009' dev/EPICS/E1-x.md)" -eq 1 ]
}

@test "add: unknown epic fails" {
  run bash "$SCRIPT" add E9 T20260101-000001
  [ "$status" -eq 1 ]
}

@test "epic-status: reads dev/EPICS/E*.md and parses both member-line forms" {
  bash "$SCRIPT" sync 2>/dev/null
  run bash -c "source '$STATUS'; epic_fetch; epic_parse_file dev/EPICS/E1-x.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "dev/EPICS/E1-x.md"* ]]
  [[ "$output" == *$'TASK\tE1\tT20260101-000001'* ]]
  [[ "$output" == *$'TASK\tE1\tT20260101-000002'* ]]
  [[ "$output" == *$'TASK\tE1\tT20260101-999999'* ]]
}
