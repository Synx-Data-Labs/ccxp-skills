#!/usr/bin/env bats
# Tests for agent-pairing/scripts/idle-wake.sh (T20261120-105513): the persona's idle-wake bookkeeping.

load test_helper
SCRIPT="$REPO_ROOT/agent-pairing/scripts/idle-wake.sh"

setup() {
  export CCXP_IDLE_DIR="$BATS_TEST_TMPDIR/ccxp-idle"
  export AUTOPILOT_STATE_FILE="$BATS_TEST_TMPDIR/no-autopilot.json"
  export CCXP_IDLE_NOW=1000000
  unset CCXP_IDLE_WAKE CCXP_IDLE_MINUTES
}

_iw() { bash "$SCRIPT" "$@"; }

@test "plan schedules a 30-minute wake and records it; a second plan while it is pending prints nothing (exit 1)" {
  run _iw plan; [ "$status" -eq 0 ]; [ "$output" = "schedule 1800" ]
  [ "$(cat "$CCXP_IDLE_DIR/next-at")" = 1001800 ]
  CCXP_IDLE_NOW=1000500 run _iw plan; [ "$status" -eq 1 ]; [ -z "$output" ]
  CCXP_IDLE_NOW=1001900 run _iw plan; [ "$status" -eq 1 ] # due + 100 s: inside the 2-minute grace
}

@test "plan --wake (the [idle-wake] wake itself) ignores the pending record and schedules the next wake: the chain continues" {
  _iw plan >/dev/null
  CCXP_IDLE_NOW=1001800 run _iw plan; [ "$status" -eq 1 ] # a plain plan at the due time sees the pending wake
  CCXP_IDLE_NOW=1001800 run _iw plan --wake; [ "$status" -eq 0 ]; [ "$output" = "schedule 1800" ]
  [ "$(cat "$CCXP_IDLE_DIR/next-at")" = 1003600 ]
  CCXP_IDLE_NOW=1001810 run _iw plan; [ "$status" -eq 1 ] # and the new one is pending
  CCXP_IDLE_WAKE=0 CCXP_IDLE_NOW=1003600 run _iw plan --wake; [ "$status" -eq 1 ] # opt-out still wins
}

@test "after the wake is due plus the grace (it fired, or the session died) the next plan schedules again" {
  _iw plan >/dev/null
  CCXP_IDLE_NOW=1001921 run _iw plan; [ "$status" -eq 0 ]; [ "$output" = "schedule 1800" ]
  [ "$(cat "$CCXP_IDLE_DIR/next-at")" = 1003721 ]
}

@test "autopilot on means no idle wake (its own wakes carry the checks); off, paused or no state file schedules" {
  printf '%s' '{"status":"on","schema":2,"started_at":"2026-10-28T10:00:00Z","end_time":"2099-01-01T00:00:00Z"}' > "$AUTOPILOT_STATE_FILE"
  [ "$(bash "$REPO_ROOT/autopilot/scripts/autopilot-state.sh" status)" = on ] # the fixture really is autopilot on
  run _iw plan; [ "$status" -eq 1 ]; [ -z "$output" ]
  rm -f "$AUTOPILOT_STATE_FILE"
  run _iw plan; [ "$status" -eq 0 ]
}

@test "opt-out: CCXP_IDLE_WAKE=0 or config.json enabled=false schedules nothing and writes nothing" {
  CCXP_IDLE_WAKE=0 run _iw plan; [ "$status" -eq 1 ]; [ ! -e "$CCXP_IDLE_DIR/next-at" ]
  mkdir -p "$CCXP_IDLE_DIR"; echo '{"enabled": false}' > "$CCXP_IDLE_DIR/config.json"
  run _iw plan; [ "$status" -eq 1 ]; [ ! -e "$CCXP_IDLE_DIR/next-at" ]
  run _iw status; [[ "$output" == "disabled config.json enabled=false"* ]]
}

@test "interval: config minutes or CCXP_IDLE_MINUTES, never below 5 minutes, garbage falls back to 30" {
  mkdir -p "$CCXP_IDLE_DIR"; echo '{"minutes": 45}' > "$CCXP_IDLE_DIR/config.json"
  run _iw plan; [ "$output" = "schedule 2700" ]
  rm -f "$CCXP_IDLE_DIR/next-at"
  CCXP_IDLE_MINUTES=1 run _iw plan; [ "$output" = "schedule 300" ]
  rm -f "$CCXP_IDLE_DIR/next-at"
  echo '{"minutes": "soon"}' > "$CCXP_IDLE_DIR/config.json"
  CCXP_IDLE_MINUTES='x;ls' run _iw plan; [ "$output" = "schedule 1800" ]
}

@test "garbage in next-at counts as nothing pending; an unwritable state dir exits 3" {
  mkdir -p "$CCXP_IDLE_DIR"; echo 'abc; echo pwned' > "$CCXP_IDLE_DIR/next-at"
  run _iw plan; [ "$status" -eq 0 ]; [ "$output" = "schedule 1800" ]
  CCXP_IDLE_DIR="$BATS_TEST_TMPDIR/file-not-dir/x" run bash -c "touch '$BATS_TEST_TMPDIR/file-not-dir'; bash '$SCRIPT' plan"
  [ "$status" -eq 3 ]
}

@test "status reports enabled with the interval and the recorded next wake; usage errors exit 2" {
  run _iw status; [ "$output" = "enabled minutes=30 next=0" ]
  _iw plan >/dev/null
  run _iw status; [ "$output" = "enabled minutes=30 next=1001800" ]
  run _iw bogus; [ "$status" -eq 2 ]
}

@test "network-free and token-free: no gh, curl, wget or URLs in the script" {
  ! grep -nE '\bgh |curl|wget|https?://' "$SCRIPT"
}
