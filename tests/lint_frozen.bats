#!/usr/bin/env bats
# Tests for _session/lint_frozen.sh — the pick-path lint-frozen probe
# (T20260629-185057). The dispatch block is guarded by
# [ "${BASH_SOURCE[0]}" = "${0}" ], so sourcing is side-effect-free and the
# functions can be called directly.
#
# Contract under test: lint_frozen_is_frozen <file> [repo]
#   return 0 = FROZEN (exclude / refuse claim)
#   return 1 = CLAIMABLE (lint-clean, OR unclassifiable — the inverted fail-safe)
#
# The LINT_FROZEN_IDS cases are hermetic (no python, no real lint). The
# fixture cases exercise the REAL repo-conventions/scripts/lint_tasks.py and so
# pin LINT_TASKS_PY to the in-repo linter (CI has no ~/.claude/skills).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_session/lint_frozen.sh"
  LINT="$REPO_ROOT/repo-conventions/scripts/lint_tasks.py"
  export LINT_TASKS_PY="$LINT"
}

# Write a task file under <tmp>/dev/TODO so lint_tasks.py's is_task_file()
# accepts it ("dev" + "TODO" must be in the path parts). $1=tmp, $2=id,
# $3=estimation. Returns the file path on stdout.
_mk_task() {
  local tmp="$1" id="$2" est="$3" f
  mkdir -p "$tmp/dev/TODO"
  f="$tmp/dev/TODO/${id}-fixture.md"
  cat > "$f" <<EOF
---
status: Open
estimation: ${est}
priority: Low
---
# ${id} — fixture
EOF
  printf '%s\n' "$f"
}

# --- test hook (hermetic: no python, no real lint) --------------------------

@test "LINT_FROZEN_IDS: a listed id is classified frozen (return 0)" {
  LINT_FROZEN_IDS="T20260101-000001 T20260102-000002" \
    run lint_frozen_is_frozen "dev/TODO/T20260101-000001-foo.md"
  [ "$status" -eq 0 ]
}

@test "LINT_FROZEN_IDS: an unlisted id stays claimable (return 1)" {
  LINT_FROZEN_IDS="T20260101-000001" \
    run lint_frozen_is_frozen "dev/TODO/T20260102-000002-bar.md"
  [ "$status" -eq 1 ]
}

@test "LINT_FROZEN_IDS: a path with no T-id is claimable (fail-safe)" {
  LINT_FROZEN_IDS="T20260101-000001" run lint_frozen_is_frozen "notes.md"
  [ "$status" -eq 1 ]
}

# --- inverted fail-safe (unclassifiable ⇒ claimable) ------------------------

@test "fail-safe: a missing file is claimable (return 1)" {
  run lint_frozen_is_frozen "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 1 ]
}

@test "fail-safe: an empty path is claimable (return 1)" {
  run lint_frozen_is_frozen ""
  [ "$status" -eq 1 ]
}

@test "fail-safe: a missing linter is claimable (return 1)" {
  f="$(_mk_task "$BATS_TEST_TMPDIR" T20260101-000001 1-2h)"
  LINT_TASKS_PY="$BATS_TEST_TMPDIR/no-such-linter.py" run lint_frozen_is_frozen "$f"
  [ "$status" -eq 1 ]
}

# --- real lint (fixtures under dev/TODO) ------------------------------------

@test "real lint: a non-bucket estimation (1-2h) is frozen (return 0)" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  [ -f "$LINT" ] || skip "lint_tasks.py not found"
  f="$(_mk_task "$BATS_TEST_TMPDIR" T20260101-000001 1-2h)"
  run lint_frozen_is_frozen "$f" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "real lint: a bucket estimation (2h) is claimable (return 1)" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  [ -f "$LINT" ] || skip "lint_tasks.py not found"
  f="$(_mk_task "$BATS_TEST_TMPDIR" T20260102-000002 2h)"
  run lint_frozen_is_frozen "$f" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

# --- direct dispatch --------------------------------------------------------

@test "dispatch: is-frozen returns the probe exit code (claimable ⇒ 1)" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  [ -f "$LINT" ] || skip "lint_tasks.py not found"
  f="$(_mk_task "$BATS_TEST_TMPDIR" T20260102-000002 2h)"
  run bash "$REPO_ROOT/_session/lint_frozen.sh" is-frozen "$f" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "dispatch: an unknown verb exits 64" {
  run bash "$REPO_ROOT/_session/lint_frozen.sh" bogus-verb
  [ "$status" -eq 64 ]
}
