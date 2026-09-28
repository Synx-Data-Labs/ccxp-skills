#!/usr/bin/env bats
# Tests for _ipm/current.sh — the staging-aware "current committed IPM" selector.
#
# We test the pure selection logic by sourcing the lib (the dispatch block at the
# bottom is guarded by [ "${BASH_SOURCE[0]}" = "${0}" ], so sourcing is
# side-effect-free) and calling _ipm_current against a fixture JOURNAL dir.
#
# "today" is dependency-injected via the IPM_TODAY env var (per the guidelines'
# I/O-injection rule) so tests are deterministic without mocking the `date` tool.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_ipm/current.sh"
  JDIR="$BATS_TEST_TMPDIR/journal"
  mkdir -p "$JDIR"
}

# Write an IPM file. $1=date, $2=staging(yes/no)
mk_ipm() {
  local date="$1" staging="$2" f="$JDIR/$1-ipm-weekly.md"
  if [ "$staging" = "yes" ]; then
    printf '# IPM Weekly — %s\n\n**Status**: Pre-IPM staging — candidates accumulate here.\n' "$date" > "$f"
  else
    printf '# Weekly Focus: %s\n\n**Budget**: 20h focused-work\n' "$date" > "$f"
  fi
}

# --- core: staging-stub excluded even when its date == today -----------------

@test "2a.1.5 case: at Monday IPM the still-staged stub is skipped; previous commit wins" {
  mk_ipm 2026-06-01 no      # last week's committed IPM
  mk_ipm 2026-06-08 yes     # this week's stub (date == today, still staged)
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01-ipm-weekly.md" ]]
}

@test "2a.5b case: once the stub's staging header is dropped, it becomes current" {
  mk_ipm 2026-06-01 no
  mk_ipm 2026-06-08 no      # 2a.5 committed this week's IPM (header gone)
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-08-ipm-weekly.md" ]]
}

# --- rca / standup: newest committed wins ------------------------------------

@test "newest committed IPM wins when several are committed" {
  mk_ipm 2026-05-18 no
  mk_ipm 2026-05-25 no
  mk_ipm 2026-06-01 no
  run env IPM_TODAY=2026-06-05 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01-ipm-weekly.md" ]]
}

# --- guards ------------------------------------------------------------------

@test "non-date-prefixed *-ipm-weekly.md (a task journal) is NOT selected (T20260628-771630)" {
  mk_ipm 2026-06-22 no      # the real committed IPM
  # Decoy: a task journal whose filename ends in -ipm-weekly.md (the rename task's own
  # journal — created by T20260513-359694). It sorts AFTER the real IPM and is not a
  # staging stub, so without the date-prefix guard it wins. It must be skipped.
  printf '# T123: rename legacy weekly-focus to ipm-weekly\n\nclosed.\n' \
    > "$JDIR/2026-06-27-T20260513-359694-rename-legacy-weekly-focus-to-ipm-weekly.md"
  run env IPM_TODAY=2026-06-28 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-22-ipm-weekly.md" ]]
}

@test "future-dated committed file is excluded by the date guard" {
  mk_ipm 2026-06-01 no
  mk_ipm 2026-06-15 no      # committed but dated in the future (shouldn't happen, guard anyway)
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01-ipm-weekly.md" ]]
}

@test "empty journal dir yields empty output, exit 0" {
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "single committed file is selected" {
  mk_ipm 2026-06-01 no
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01-ipm-weekly.md" ]]
}

@test "only a staging stub present yields empty (no committed IPM yet)" {
  mk_ipm 2026-06-08 yes
  run env IPM_TODAY=2026-06-08 bash -c "source '$REPO_ROOT/_ipm/current.sh'; _ipm_current '$JDIR'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- executable dispatch -----------------------------------------------------

@test "executable form prints the current IPM path" {
  mk_ipm 2026-06-01 no
  mk_ipm 2026-06-08 yes
  run env IPM_TODAY=2026-06-08 bash "$REPO_ROOT/_ipm/current.sh" "$JDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01-ipm-weekly.md" ]]
}

@test "executable form defaults dir to dev/JOURNAL when no arg given" {
  # Run from a tmp cwd containing dev/JOURNAL so the default path resolves.
  mkdir -p "$BATS_TEST_TMPDIR/wd/dev/JOURNAL"
  printf '# Weekly Focus: 2026-06-01\n' > "$BATS_TEST_TMPDIR/wd/dev/JOURNAL/2026-06-01-ipm-weekly.md"
  run env IPM_TODAY=2026-06-08 bash -c "cd '$BATS_TEST_TMPDIR/wd' && bash '$REPO_ROOT/_ipm/current.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev/JOURNAL/2026-06-01-ipm-weekly.md" ]]
}
