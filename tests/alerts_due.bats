#!/usr/bin/env bats
# Tests for agent-pairing/scripts/alerts-due.sh (T20261113-631854): the persona's Slack alerts check state.
# Fake clock via CCXP_ALERTS_NOW; no network, no model.

bats_require_minimum_version 1.5.0
load test_helper
AD="$REPO_ROOT/agent-pairing/scripts/alerts-due.sh"

NOW=1794247200

setup() {
  export CCXP_ALERTS_DIR="$BATS_TEST_TMPDIR/alerts"
  export CCXP_CONTEXT_DIR="$BATS_TEST_TMPDIR/ctx"
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  unset CCXP_ALERTS CCXP_ALERTS_MIN_GAP CCXP_ALERTS_OVERLAP CCXP_ALERTS_CAP
  mkdir -p "$CCXP_CONTEXT_DIR"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in gh curl wget claude ssh; do printf '#!/bin/sh\necho "NETWORK CALL: %s" >&2\nexit 99\n' "$t" >"$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

at() { CCXP_ALERTS_NOW="$1" bash "$AD" "${@:2}"; }

@test "check: first call has no window ('-'), a second within 5 minutes is not due" {
  run at "$NOW" check
  [ "$status" -eq 0 ]
  [ "$output" = "-" ]
  run at $((NOW + 299)) check
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run at $((NOW + 300)) check
  [ "$status" -eq 0 ]
}

@test "marker: done moves last-seen forward and check prints it minus the 10 minute overlap" {
  at "$NOW" check >/dev/null
  run at "$NOW" done 1794240000.250000
  [ "$status" -eq 0 ]
  run at $((NOW + 400)) check
  [ "$output" = "1794239400.000000" ]
}

@test "marker: done never moves back, and exact microsecond comparison holds" {
  at "$NOW" done 1794240000.250000
  at "$NOW" done 1794230000.100000
  [ "$(cat "$CCXP_ALERTS_DIR/last-seen")" = "1794240000.250000" ]
  at "$NOW" done 1794240000.25001
  [ "$(cat "$CCXP_ALERTS_DIR/last-seen")" = "1794240000.25001" ]
  at "$NOW" done 1794240000.2500
  [ "$(cat "$CCXP_ALERTS_DIR/last-seen")" = "1794240000.25001" ]
}

@test "marker: overlap and gap are configurable; a bad ts is refused" {
  at "$NOW" done 1794240000.000001
  CCXP_ALERTS_OVERLAP=60 run at "$NOW" check
  [ "$output" = "1794239940.000000" ]
  run at "$NOW" done notats
  [ "$status" -eq 2 ]
}

@test "off switch: CCXP_ALERTS=0 makes check not due and writes nothing" {
  CCXP_ALERTS=0 run at "$NOW" check
  [ "$status" -eq 1 ]
  [ ! -e "$CCXP_ALERTS_DIR" ]
}

@test "plan: an unanswered alert is dispatched, a thread with a reply is handled" {
  run at "$NOW" plan <<<$'1794240000.000100\t0\t0\t5\n1794240100.000200\t2\t0\t5'
  [ "$status" -eq 0 ]
  [ "$output" = "dispatch 1794240000.000100" ]
}

@test "plan: handled by a context file carrying the ts, even when old" {
  echo "alert ts 1794240000.000100 run 123" >"$CCXP_CONTEXT_DIR/job1-rca.md"
  touch -t 202001010000 "$CCXP_CONTEXT_DIR/job1-rca.md"
  run at "$NOW" plan <<<$'1794240000.000100\t0\t0\t300'
  [ -z "$output" ]
}

@test "plan: handled by a ledger row carrying the ts" {
  echo '{"running":[{"job":5,"title":"RCA run 1 ts 1794240000.000100"}]}' >"$CCXP_LEDGER_FILE"
  run at "$NOW" plan <<<$'1794240000.000100\t0\t0\t5'
  [ -z "$output" ]
}

@test "plan: a run id alone does not count (only the ts does)" {
  echo "bare /rca job for run 987654" >"$CCXP_CONTEXT_DIR/job2-rca.md"
  run at "$NOW" plan <<<$'1794240000.000100\t0\t0\t5'
  [ "$output" = "dispatch 1794240000.000100" ]
}

@test "plan: ack-only thread older than 60 minutes with no live job is dispatched again" {
  run at "$NOW" plan <<<$'1794240000.000100\t1\t1\t90'
  [ "$output" = "dispatch 1794240000.000100" ]
}

@test "plan: ack-only thread stays handled when younger than 60 minutes or a live job exists" {
  run at "$NOW" plan <<<$'1794240000.000100\t1\t1\t30'
  [ -z "$output" ]
  echo "ts 1794240000.000100" >"$CCXP_CONTEXT_DIR/job3.md"
  run at "$NOW" plan <<<$'1794240000.000100\t1\t1\t90'
  [ -z "$output" ]
}

@test "plan: cap of 3 dispatches, the rest listed as next, oldest first" {
  run at "$NOW" plan <<<$'1794240400.000000\t0\t0\t1\n1794240100.000000\t0\t0\t9\n1794240300.000000\t0\t0\t2\n1794240200.000000\t0\t0\t3\n1794240500.000000\t0\t0\t1'
  [ "$output" = $'dispatch 1794240100.000000\ndispatch 1794240200.000000\ndispatch 1794240300.000000\nnext 1794240400.000000\nnext 1794240500.000000' ]
}

@test "plan: fixture channel history dispatches exactly the unanswered alerts, none twice" {
  input=$'1794240000.000100\t0\t0\t50\n1794240100.000200\t3\t0\t49\n1794240200.000300\t0\t0\t48'
  run at "$NOW" plan <<<"$input"
  [ "$output" = $'dispatch 1794240000.000100\ndispatch 1794240200.000300' ]
  # the persona writes a context file per dispatched ts; a re-run dispatches nothing
  echo "ts 1794240000.000100" >"$CCXP_CONTEXT_DIR/j1.md"
  echo "ts 1794240200.000300" >"$CCXP_CONTEXT_DIR/j2.md"
  run at "$NOW" plan <<<"$input"
  [ -z "$output" ]
}

@test "plan: a bad ts line is skipped with a warning, not dispatched" {
  run --separate-stderr at "$NOW" plan <<<$'oops\t0\t0\t1\n1794240000.000100\t0\t0\t1'
  [ "$output" = "dispatch 1794240000.000100" ]
  [[ "$stderr" == *"bad ts"* ]]
}

@test "usage: unknown verb exits 2" {
  run bash "$AD" frobnicate
  [ "$status" -eq 2 ]
}

@test "plan: space separated input works, leading zeros do not break arithmetic, duplicate ts dispatched once" {
  run at "$NOW" plan <<<$'1794240000.000100 0 0 5\n1794240000.000100 0 0 5\n1794240100.000200 1 1 08'
  [ "$output" = "dispatch 1794240000.000100" ]
  run at "$NOW" plan <<<$'1794240100.000200 1 1 090'
  [ "$output" = "dispatch 1794240100.000200" ]
}

@test "cap: done after held-back alerts pins the marker before the oldest next, so they are re-read" {
  at "$NOW" check >/dev/null
  run at "$NOW" plan <<<$'1794240100.000000 0 0 1\n1794240200.000000 0 0 1\n1794240300.000000 0 0 1\n1794240400.000000 0 0 1'
  [[ "$output" == *"next 1794240400.000000"* ]]
  at "$NOW" done 1794240500.000000
  [ "$(cat "$CCXP_ALERTS_DIR/last-seen")" = "1794240399.999999" ]
  [ ! -e "$CCXP_ALERTS_DIR/hold" ]
  # a later plan with nothing held back clears the hold; done then takes the newest ts
  at "$NOW" plan <<<$'1794240400.000000 0 0 1' >/dev/null
  at "$NOW" done 1794240500.000000
  [ "$(cat "$CCXP_ALERTS_DIR/last-seen")" = "1794240500.000000" ]
}

@test "state failure: unwritable state dir exits 3 with a message, not 1" {
  touch "$BATS_TEST_TMPDIR/file"
  CCXP_ALERTS_DIR="$BATS_TEST_TMPDIR/file/sub" run --separate-stderr at "$NOW" check
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"cannot write"* ]]
  unset CCXP_ALERTS_DIR CLAUDE_CONFIG_DIR
  CCXP_PROFILE_DIR="" HOME="" run --separate-stderr env -u CCXP_ALERTS_DIR CCXP_PROFILE_DIR= bash -c 'CCXP_ALERTS_NOW=1 bash "$0" check' "$AD"
  [ "$status" -ne 0 ]
}
