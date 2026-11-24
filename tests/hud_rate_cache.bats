#!/usr/bin/env bats
# Tests for hud/scripts/hud-rate-cache.sh: the rate-limit snapshot the HUD writes for the autopilot (T20261124-168446).

load test_helper
RC="$REPO_ROOT/hud/scripts/hud-rate-cache.sh"

setup() {
  export CCXP_HUD_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  export HUD_RATE_NOW=1800000000
  F="$CCXP_HUD_CACHE_DIR/rate-limits.json"
}

both='{"five_hour":{"used_percentage":23.5,"resets_at":1800004000},"seven_day":{"used_percentage":41.2,"resets_at":1800300000}}'

@test "write: both windows land in a mode-600 file with the write time" {
  run bash -c "printf '%s' '$both' | bash '$RC' write"
  [ "$status" -eq 0 ]
  [ -f "$F" ]
  [ "$(stat -c %a "$F" 2>/dev/null || stat -f %Lp "$F")" = 600 ]
  run jq -c . "$F"
  [ "$output" = '{"version":1,"written_at":1800000000,"five_hour":{"used_percentage":23.5,"resets_at":1800004000},"seven_day":{"used_percentage":41.2,"resets_at":1800300000}}' ]
}

@test "write: one window missing is just absent, never null" {
  run bash -c "printf '%s' '{\"seven_day\":{\"used_percentage\":10,\"resets_at\":1800300000}}' | bash '$RC' write"
  [ "$status" -eq 0 ]
  run jq -r 'has("five_hour"), .seven_day.used_percentage' "$F"
  [ "${lines[0]}" = false ]
  [ "${lines[1]}" = 10 ]
}

@test "write: no usable window writes nothing and keeps an older file" {
  run bash -c "printf '%s' '{}' | bash '$RC' write"
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
  printf '%s' "$both" | bash "$RC" write
  before=$(cat "$F")
  run bash -c "printf '%s' 'not json' | bash '$RC' write"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '{\"five_hour\":{\"used_percentage\":\"high\"}}' | bash '$RC' write"
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$before" ]
}

@test "write: out-of-range percentages and bad reset times are dropped, not stored" {
  run bash -c "printf '%s' '{\"five_hour\":{\"used_percentage\":120,\"resets_at\":5},\"seven_day\":{\"used_percentage\":50,\"resets_at\":\"soon\"}}' | bash '$RC' write"
  [ "$status" -eq 0 ]
  run jq -c . "$F"
  [ "$output" = '{"version":1,"written_at":1800000000,"seven_day":{"used_percentage":50}}' ]
}

@test "write: no leftover temp files after repeated writes" {
  for i in 1 2 3; do printf '%s' "$both" | bash "$RC" write; done
  [ "$(ls "$CCXP_HUD_CACHE_DIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "read: fresh file prints the snapshot; no file is exit 1" {
  run bash "$RC" read
  [ "$status" -eq 1 ]
  printf '%s' "$both" | bash "$RC" write
  run bash "$RC" read --max-age 300
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.five_hour.used_percentage')" = 23.5 ]
}

@test "read: older than --max-age is exit 2 and prints nothing" {
  printf '%s' "$both" | bash "$RC" write
  HUD_RATE_NOW=1800000301 run bash "$RC" read --max-age 300
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  HUD_RATE_NOW=1800000300 run bash "$RC" read --max-age 300
  [ "$status" -eq 0 ]
}

@test "read: a window past its reset time is removed; none left is exit 3" {
  printf '%s' "$both" | bash "$RC" write
  HUD_RATE_NOW=1800004001 run bash "$RC"  read
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'has("five_hour"), has("seven_day")' | tr '\n' ' ')" = "false true " ]
  HUD_RATE_NOW=1800300001 run bash "$RC" read
  [ "$status" -eq 3 ]
}

@test "read: a corrupt file is exit 1; bad arguments are 64" {
  mkdir -p "$CCXP_HUD_CACHE_DIR"
  echo 'garbage' > "$F"
  run bash "$RC" read
  [ "$status" -eq 1 ]
  run bash "$RC" read --max-age soon
  [ "$status" -eq 64 ]
  run bash "$RC" frob
  [ "$status" -eq 64 ]
}

@test "path: the cache dir override, else the profile's state/hud-cache" {
  run bash "$RC" path
  [ "$output" = "$CCXP_HUD_CACHE_DIR/rate-limits.json" ]
  unset CCXP_HUD_CACHE_DIR
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/prof" run bash "$RC" path
  [ "$output" = "$BATS_TEST_TMPDIR/prof/state/hud-cache/rate-limits.json" ]
}
