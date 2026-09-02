#!/usr/bin/env bats
# Tests for _taskid/in-this-repo.sh — clone-locality guard (T20260626-298293).
#
# A task is "cross-repo for the current clone" iff dev/TODO/T<id>-*.md does not
# exist in the cwd repo. The guard is a purely-local file-presence check:
#   present in TODO/PARKING -> exit 0 (proceed here)
#   present only in JOURNAL -> closed here, distinct "file a new task" message
#   absent everywhere       -> cross-repo: warn (default) or refuse (strict)
#
# I/O is hermetic: a throwaway repo tree under $BATS_TEST_TMPDIR supplies the
# dev/ fixtures, an `origin` remote (for the owner/repo slug), and — for the
# sibling-discovery case — a parent dir holding a second clone. The production
# functions are exercised by sourcing the script (its CLI dispatch is guarded
# by BASH_SOURCE[0] == $0, so sourcing is side-effect-free).

ID="T20260626-190842"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Parent "workspace" dir so sibling-clone discovery has something to scan.
  WORKSPACE="$BATS_TEST_TMPDIR/workspace"
  CWD_REPO="$WORKSPACE/build-pipeline-repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"

  git init -q .
  git remote add origin https://github.com/your-org/build-pipeline-repo.git
  mkdir -p dev/TODO dev/PARKING dev/JOURNAL

  source "$REPO_ROOT/_taskid/in-this-repo.sh"
}

# --- present: proceed silently ----------------------------------------------

@test "present in dev/TODO -> exit 0, no warning" {
  touch "dev/TODO/${ID}-scheduled-stamper.md"
  run taskid-in-this-repo "$ID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "present in dev/PARKING -> exit 0, no warning" {
  touch "dev/PARKING/${ID}-scheduled-stamper.md"
  run taskid-in-this-repo "$ID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- closed here ------------------------------------------------------------

@test "present only in dev/JOURNAL -> non-zero + distinct closed message" {
  touch "dev/JOURNAL/2026-06-26-${ID}-scheduled-stamper.md"
  run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"closed"* ]]
  [[ "$output" == *"$ID"* ]]
}

# --- cross-repo: absent everywhere ------------------------------------------

@test "absent everywhere -> non-zero + warning naming the current owner/repo" {
  run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cross-repo"* ]]
  [[ "$output" == *"your-org/build-pipeline-repo"* ]]
}

@test "default (warn-only) cross-repo names DRIVE_STRICT_CLONE as the refuse knob" {
  run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"warn-only"* ]]
  [[ "$output" == *"DRIVE_STRICT_CLONE"* ]]
}

@test "DRIVE_STRICT_CLONE=1 cross-repo -> refuse (distinct exit, refusing message)" {
  DRIVE_STRICT_CLONE=1 run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"efusing"* ]]
}

# --- sibling-clone discovery (best-effort) ----------------------------------

@test "sibling-clone discovery names the right path when exactly one sibling has it" {
  # A second clone next to the cwd repo holds the task file.
  mkdir -p "$WORKSPACE/hub-repo/dev/TODO"
  touch "$WORKSPACE/hub-repo/dev/TODO/${ID}-scheduled-stamper.md"
  run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$WORKSPACE/hub-repo"* ]]
}

@test "silent about siblings when none has the task file" {
  run taskid-in-this-repo "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Found it in"* ]]
}

# --- CLI execution under set -e (the trailing-test trap) --------------------
# Sourcing disables set -e, so a function ending on a falsy `[ ] && cmd` passes
# the sourced tests yet aborts the set -e CLI mid-flight. Exercise the script as
# a SUBPROCESS so set -e is live — the warn-only / refusing banner must survive.

@test "CLI (set -e): cross-repo default prints the full warn-only banner, exit 2" {
  run bash "$REPO_ROOT/_taskid/in-this-repo.sh" "$ID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"warn-only"* ]]
  [[ "$output" == *"DRIVE_STRICT_CLONE"* ]]
}

@test "CLI (set -e): DRIVE_STRICT_CLONE=1 prints Refusing, exit 1" {
  DRIVE_STRICT_CLONE=1 run bash "$REPO_ROOT/_taskid/in-this-repo.sh" "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing"* ]]
}

# --- sourceability ----------------------------------------------------------

@test "sourcing the script has no side effects (functions only)" {
  run bash -c "source '$REPO_ROOT/_taskid/in-this-repo.sh'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}
