#!/usr/bin/env bats
# Tests for agent-pairing/scripts/ci-job-cap.sh: the CI failure response per-turn job cap.

load test_helper
CAP="$REPO_ROOT/agent-pairing/scripts/ci-job-cap.sh"

setup() {
  unset CCXP_CI_JOB_CAP
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

@test "default is 6 with no env and no file" {
  run bash "$CAP"
  [ "$status" -eq 0 ]; [ "$output" = 6 ]
}

@test "env wins over the file" {
  echo '{"ciJobCap": 9}' >"$CLAUDE_CONFIG_DIR/ccxp-hud.json"
  CCXP_CI_JOB_CAP=2 run bash "$CAP"
  [ "$output" = 2 ]
}

@test "invalid env falls back to the file, then the default" {
  echo '{"ciJobCap": 9}' >"$CLAUDE_CONFIG_DIR/ccxp-hud.json"
  for bad in 0 -1 abc 1.5 "" " 3"; do
    CCXP_CI_JOB_CAP="$bad" run bash "$CAP"
    [ "$output" = 9 ]
  done
  rm "$CLAUDE_CONFIG_DIR/ccxp-hud.json"
  CCXP_CI_JOB_CAP=abc run bash "$CAP"
  [ "$output" = 6 ]
}

@test "config file ciJobCap (number or string) is read from the profile dir" {
  echo '{"enabled": true, "ciJobCap": 4}' >"$CLAUDE_CONFIG_DIR/ccxp-hud.json"
  run bash "$CAP"; [ "$output" = 4 ]
  echo '{"ciJobCap": "8"}' >"$CLAUDE_CONFIG_DIR/ccxp-hud.json"
  run bash "$CAP"; [ "$output" = 8 ]
}

@test "invalid or malformed config file means the default" {
  for body in '{"ciJobCap": 0}' '{"ciJobCap": -2}' '{"ciJobCap": "x"}' '{"ciJobCap": 2.5}' '{"ciJobCap": null}' '[1]' 'not json'; do
    printf '%s' "$body" >"$CLAUDE_CONFIG_DIR/ccxp-hud.json"
    run bash "$CAP"
    [ "$status" -eq 0 ]; [ "$output" = 6 ]
  done
}

@test "writes nothing" {
  run bash "$CAP"
  [ -z "$(ls -A "$CLAUDE_CONFIG_DIR")" ]
}
