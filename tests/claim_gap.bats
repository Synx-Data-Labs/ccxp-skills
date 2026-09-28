#!/usr/bin/env bats
# Tests for _session/claim_gap.sh — the unclaimed-active-task detector that
# complements reclaim_sweep.sh (which finds the opposite: a claim gone stale).
#
# Pure file-enumeration logic — no gh/git I/O to stub, unlike reclaim_sweep.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Sourcing is side-effect-free (guarded dispatch). Pulls in task_claim.sh +
  # _lib.sh transitively.
  source "$REPO_ROOT/_session/claim_gap.sh"

  export TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/TODO"
  mkdir -p "$TASK_CLAIM_DIR"

  export CLAIM_GAP_STATE_FILE="$BATS_TEST_TMPDIR/state/claim-gap-last.json"
}

_mk_task() {
  # $1 id  $2 status  $3 claimed_by (may be empty) → write $TASK_CLAIM_DIR/<id>-demo.md
  cat > "$TASK_CLAIM_DIR/$1-demo.md" <<EOF
---
name: Demo task
estimation: 1h
status: $2
owner: Alex
claimed_by: $3
priority: Low
---

# $1

## Notes
status: this BODY line must never be touched
claimed_by: nor this BODY line
EOF
}

@test "does NOT flag a Design task with no claimed_by (never-claimed backlog design is normal)" {
  # T20260809-310724: verified live that 3 of 4 Design-status tasks flagged by
  # this detector had simply never been claimed at all -- claimed_by empty
  # since the seed-migration commit, untouched since. /todo next's peer-claim
  # filter only skips on a NON-empty claimed_by, so nothing is actually
  # invisible to claim-based coordination here. Flagging this as a "gap" was
  # the actual bug.
  _mk_task T20260101-111111 Design ""
  run claim_gap
  [ "$status" -eq 0 ]
  [[ "$output" != *"T20260101-111111"* ]]
}

@test "flags a Coding task with no claimed_by" {
  _mk_task T20260101-222222 Coding ""
  run claim_gap
  [[ "$output" == *"unclaimed T20260101-222222"* ]]
}

@test "flags an \"In Progress\" task with no claimed_by identically to the legacy Coding alias (T20260809-355059)" {
  _mk_task T20260101-234567 "In Progress" ""
  run claim_gap
  [[ "$output" == *"unclaimed T20260101-234567"* ]]
}

@test "does NOT flag a Review task with no claimed_by (same reasoning as Design)" {
  _mk_task T20260101-333333 Review ""
  run claim_gap
  [[ "$output" != *"T20260101-333333"* ]]
}

@test "silent on a claimed active task" {
  _mk_task T20260101-444444 Coding cdw:/home/ci/repo
  run claim_gap
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "silent on an Open task" {
  _mk_task T20260101-555555 Open ""
  run claim_gap
  [ -z "$output" ]
}

@test "silent on a Done task" {
  _mk_task T20260101-666666 Done ""
  run claim_gap
  [ -z "$output" ]
}

@test "never mutates the task file" {
  _mk_task T20260101-777777 Design ""
  local before after
  before="$(cat "$TASK_CLAIM_DIR/T20260101-777777-demo.md")"
  run claim_gap
  after="$(cat "$TASK_CLAIM_DIR/T20260101-777777-demo.md")"
  [ "$before" = "$after" ]
}

@test "handles multiple gaps in one pass, only flagging Coding" {
  _mk_task T20260101-888888 Design ""
  _mk_task T20260101-999999 Coding ""
  run claim_gap
  [[ "$output" != *"T20260101-888888"* ]]
  [[ "$output" == *"unclaimed T20260101-999999"* ]]
}

# --- claim_gap_changed (dedup wrapper, T20260809-310724 root cause C) ------

@test "claim_gap_changed posts on the first call (no prior state)" {
  _mk_task T20260101-101010 Coding ""
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclaimed T20260101-101010"* ]]
  [ -f "$CLAIM_GAP_STATE_FILE" ]
}

_cgc_stdout_only() { claim_gap_changed 2>/dev/null; }

@test "claim_gap_changed stays silent on a second call with an unchanged list" {
  # claim_gap's own per-line _session_log (stderr) still fires every call by
  # design (local log visibility is never suppressed) — only stdout (the
  # Slack-post signal) goes quiet on a repeat, so check stdout specifically.
  # Redirect stderr inside a plain shell function (not via `run`'s own
  # flags) to stay portable across bats versions.
  _mk_task T20260101-101010 Coding ""
  claim_gap_changed >/dev/null 2>/dev/null   # first call records state
  run _cgc_stdout_only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claim_gap_changed posts again once the flagged list actually changes" {
  _mk_task T20260101-101010 Coding ""
  claim_gap_changed >/dev/null           # records {T20260101-101010}
  _mk_task T20260101-202020 Coding ""    # a second gap appears
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclaimed T20260101-101010"* ]]
  [[ "$output" == *"unclaimed T20260101-202020"* ]]
}

@test "claim_gap_changed posts again once the list shrinks back to empty" {
  _mk_task T20260101-101010 Coding ""
  claim_gap_changed >/dev/null                       # records {T20260101-101010}
  rm "$TASK_CLAIM_DIR/T20260101-101010-demo.md"       # the gap is resolved
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # nothing flagged this time...
  run claim_gap_changed
  [ -z "$output" ]   # ...and correctly stays silent on the next unchanged (empty) call
}

@test "claim_gap_changed re-posts the SAME gap if it reappears after a clean tick" {
  # Not just "did output change" -- clearing state on the clean tick means a
  # later reappearance of the exact same task is reported again, rather than
  # silently matching the stale pre-clean hash still sitting on disk.
  _mk_task T20260101-101010 Coding ""
  claim_gap_changed >/dev/null                        # records {T20260101-101010}
  rm "$TASK_CLAIM_DIR/T20260101-101010-demo.md"
  claim_gap_changed >/dev/null                        # clean tick -- clears state
  _mk_task T20260101-101010 Coding ""                 # the SAME gap reappears
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclaimed T20260101-101010"* ]]
}

@test "claim_gap_changed treats a missing state file as no prior state" {
  [ ! -e "$CLAIM_GAP_STATE_FILE" ]
  _mk_task T20260101-101010 Coding ""
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclaimed T20260101-101010"* ]]
}

@test "claim_gap_changed treats a corrupt state file as no prior state" {
  mkdir -p "$(dirname "$CLAIM_GAP_STATE_FILE")"
  echo "not valid json" > "$CLAIM_GAP_STATE_FILE"
  _mk_task T20260101-101010 Coding ""
  run claim_gap_changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"unclaimed T20260101-101010"* ]]
}

@test "claim_gap_changed produces truly empty stdout (not a bare newline) on a first-ever clean run" {
  # bats' `run`/command-substitution capture strips a trailing newline, so
  # `[ -z "$output" ]` alone can't catch a real "prints one blank line"
  # regression (sha256sum of empty input is a real, non-empty hash, not
  # "no gaps" — an unguarded comparison against prev="" would look "changed"
  # on every first-ever clean run). Check the raw byte count on disk instead.
  local outfile="$BATS_TEST_TMPDIR/stdout.txt"
  claim_gap_changed > "$outfile" 2>/dev/null
  [ ! -s "$outfile" ]
}

@test "claim_gap_changed produces truly empty stdout on a repeat clean run too" {
  local outfile="$BATS_TEST_TMPDIR/stdout.txt"
  claim_gap_changed >/dev/null 2>/dev/null   # first clean call records state
  claim_gap_changed > "$outfile" 2>/dev/null
  [ ! -s "$outfile" ]
}
