#!/usr/bin/env bats
# Tests for the Slack-alerts-check staleness cell of the ccxp-hud data helper (hud/scripts/hud-alerts.sh, also
# reached through hud-data.sh --json). Local files only: a fake plugin root and a throwaway alerts dir.

load test_helper
ALERTS="$REPO_ROOT/hud/scripts/hud-alerts.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"

setup() {
  export CCXP_ALERTS_DIR="$BATS_TEST_TMPDIR/ccxp-alerts"
  unset CCXP_ALERTS
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN/agent-pairing/scripts"
  : > "$PLUGIN/agent-pairing/scripts/alerts-due.sh"
}

_alerts() { ( source "$ALERTS"; hud-alerts-json "${1:-$PLUGIN}" "${2:-1}" ); }

@test "a recorded check is reported as its epoch, held false" {
  mkdir -p "$CCXP_ALERTS_DIR"; echo "$(( $(date +%s) - 700 ))" > "$CCXP_ALERTS_DIR/last-check"
  run _alerts
  [ "$(jq -r .held <<<"$output")" = false ]
  [ "$(jq -r '$n - .checked_at' --argjson n "$(date +%s)" <<<"$output")" -ge 700 ]
}

@test "no state dir or no last-check means never checked (checked_at 0), not an error" {
  run _alerts; [ "$output" = '{"checked_at":0,"held":false}' ]
  mkdir -p "$CCXP_ALERTS_DIR"
  run _alerts; [ "$output" = '{"checked_at":0,"held":false}' ]
}

@test "a non-empty hold file means alerts are held back; an empty one does not" {
  mkdir -p "$CCXP_ALERTS_DIR"; echo "$(date +%s)" > "$CCXP_ALERTS_DIR/last-check"
  : > "$CCXP_ALERTS_DIR/hold"
  run _alerts; [ "$(jq -r .held <<<"$output")" = false ]
  echo "1763640000.000000" > "$CCXP_ALERTS_DIR/hold"
  run _alerts; [ "$(jq -r .held <<<"$output")" = true ]
}

@test "garbage or a future stamp in last-check counts as never checked" {
  mkdir -p "$CCXP_ALERTS_DIR"
  echo '12; echo pwned' > "$CCXP_ALERTS_DIR/last-check"
  run _alerts; [ "$output" = '{"checked_at":0,"held":false}' ]
  echo "$(( $(date +%s) + 99999 ))" > "$CCXP_ALERTS_DIR/last-check"
  run _alerts; [ "$output" = '{"checked_at":0,"held":false}' ]
}

@test "degrades to null: switched off, CCXP_ALERTS=0, or a plugin without alerts-due.sh" {
  run _alerts "$PLUGIN" 0; [ "$output" = null ]
  CCXP_ALERTS=0 run _alerts; [ "$output" = null ]
  run _alerts "$BATS_TEST_TMPDIR/old-plugin"; [ "$output" = null ]
}

@test "hud-data.sh carries alerts; show_alerts false turns it to null; it runs no gh or network" {
  local repo="$BATS_TEST_TMPDIR/r"; mkdir -p "$repo"; git -C "$repo" init -q -b main
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hq" HUD_HWM_SYNC=1 HUD_NIGHTLY_OFF=1 HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hv" HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/none"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/li" CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/l.json" HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hc"
  run bash -c "printf '%s' '{\"cwd\":\"$repo\"}' | bash '$HUD' --json"
  [ "$(jq -r '.alerts | type' <<<"$output")" = object ] # the real plugin has alerts-due.sh
  run bash -c "printf '%s' '{\"cwd\":\"$repo\",\"show_alerts\":false}' | bash '$HUD' --json"
  [ "$(jq -r .alerts <<<"$output")" = null ]
  ! grep -nE '\bgh |curl|wget|https?://' "$ALERTS"
}
