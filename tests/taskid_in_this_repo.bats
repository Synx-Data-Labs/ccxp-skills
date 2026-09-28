#!/usr/bin/env bats
# Tests for _taskid/in-this-repo.sh — clone-locality guard (T20260626-298293),
# reworked under T20260928-324939 so the cross-repo case points at a clonable
# slug instead of inviting reuse of the sibling's existing local clone (the
# "own clone, always" policy — synxdb-build-pipeline
# dev/JOURNAL/2026-05-13-T20260513-403409-focus-phase-1.5-ephemeral-clone.md).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_taskid/in-this-repo.sh"

  # Hermetic sandbox: cwd repo + one sibling repo, as peer dirs.
  cd "$BATS_TEST_TMPDIR"
  mkdir -p cwd-repo sibling-repo
  cd cwd-repo
  git init -q .
  git remote add origin https://github.com/your-org/build-pipeline-repo.git
  mkdir -p dev/TODO dev/PARKING dev/JOURNAL

  cd "$BATS_TEST_TMPDIR/sibling-repo"
  git init -q .
  git remote add origin https://github.com/your-org/hub-repo.git
  mkdir -p dev/TODO
  touch dev/TODO/T20260928-999999-cross-repo-task.md

  cd "$BATS_TEST_TMPDIR/cwd-repo"
}

@test "present in dev/TODO -> exit 0, no banner" {
  touch dev/TODO/T20260101-000001-here.md
  run taskid-in-this-repo T20260101-000001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "closed (JOURNAL only) -> exit 3, distinct message" {
  touch dev/JOURNAL/2026-01-01-T20260101-000002-closed.md
  run taskid-in-this-repo T20260101-000002
  [ "$status" -eq 3 ]
  [[ "$output" == *"already closed"* ]]
}

@test "cross-repo warn-only -> exit 2, banner names a clonable slug, not a cd instruction" {
  run taskid-in-this-repo T20260928-999999
  [ "$status" -eq 2 ]
  [[ "$output" != *"Switch to that clone before working it"* ]]
  [[ "$output" == *"clone it fresh"* ]]
  [[ "$output" == *"your-org/hub-repo"* ]]
  # The local path may still be surfaced as diagnostic info, but never as an
  # instruction to work from it directly.
  [[ "$output" != *"cd into it"* ]] || [[ "$output" == *"do not"*"cd"* ]]
}

@test "cross-repo strict mode -> exit 1, refuses" {
  DRIVE_STRICT_CLONE=1 run taskid-in-this-repo T20260928-999999
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing"* ]]
}

@test "in-this-repo--sibling-slug resolves owner/repo from the sibling's origin" {
  run in-this-repo--sibling-slug T20260928-999999
  [ "$status" -eq 0 ]
  [ "$output" = "your-org/hub-repo" ]
}

@test "in-this-repo--sibling-slug prints nothing on ambiguity (0 or >1 siblings)" {
  run in-this-repo--sibling-slug T20260101-999999-nonexistent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
