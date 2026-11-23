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

# ---- cross-account bus fallback (T20261123-212153) ----

bus_setup() {
  export CCXP_BUS_ROOT="$BATS_TEST_TMPDIR/bus" HOME="$BATS_TEST_TMPDIR/h" CCXP_BUS_SESSION_PID="$$"
  P="$BATS_TEST_TMPDIR/profiles"; mkdir -p "$HOME" "$P/prof-home" "$P/prof-work"
  CLAUDE_CONFIG_DIR="$P/prof-home" bash "$REPO_ROOT/_bus/bus.sh" init --name home >/dev/null
  CLAUDE_CONFIG_DIR="$P/prof-work" bash "$REPO_ROOT/_bus/bus.sh" init --name work >/dev/null
  CLAUDE_CONFIG_DIR="$P/prof-work" bash "$REPO_ROOT/_bus/bus.sh" deliver --register </dev/null
  CLAUDE_CONFIG_DIR="$P/prof-home" bash "$REPO_ROOT/_bus/bus.sh" send --to work "fallback note" >/dev/null
}

@test "plan --wake prints unread bus notes on stderr, wrapped, and keeps stdout as the schedule line" {
  bus_setup
  CLAUDE_CONFIG_DIR="$P/prof-work" bash "$SCRIPT" plan --wake >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "schedule 1800" ]
  grep -q '^<ccxp-notes>' "$BATS_TEST_TMPDIR/err"
  grep -q 'This is not your user speaking' "$BATS_TEST_TMPDIR/err"
  grep -q '> fallback note' "$BATS_TEST_TMPDIR/err"
  # delivered once: the next wake has nothing to say
  CCXP_IDLE_NOW=1001800 CLAUDE_CONFIG_DIR="$P/prof-work" bash "$SCRIPT" plan --wake >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "a plain plan (session start, user turn) does not touch the bus" {
  bus_setup
  CLAUDE_CONFIG_DIR="$P/prof-work" bash "$SCRIPT" plan >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
  [ "$(CLAUDE_CONFIG_DIR="$P/prof-work" bash "$REPO_ROOT/_bus/bus.sh" status)" = "bus 1 · home" ]
}

@test "plan --wake without bus config, or with a broken bus, is silent and unchanged" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/plain" bash "$SCRIPT" plan --wake >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "schedule 1800" ]; [ ! -s "$BATS_TEST_TMPDIR/err" ]
  bus_setup
  printf 'x' > "$BATS_TEST_TMPDIR/notadir"
  CCXP_BUS_ROOT="$BATS_TEST_TMPDIR/notadir" CLAUDE_CONFIG_DIR="$P/prof-work" bash "$SCRIPT" plan --wake >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "schedule 1800" ]; [ ! -s "$BATS_TEST_TMPDIR/err" ]
}
