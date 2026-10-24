#!/usr/bin/env bats
# Tests for statusline-setup/scripts/ledger.sh (HUD jobs ledger).

load test_helper
LEDGER="$REPO_ROOT/statusline-setup/scripts/ledger.sh"

setup() { export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/sub/ledger.json"; }

@test "start/finish track running jobs; lifetime is the highest number ever started" {
  bash "$LEDGER" start 229 "first"
  bash "$LEDGER" start 230 "second"
  bash "$LEDGER" finish 229
  run bash "$LEDGER" show
  [ "$(jq -c '.running' <<<"$output")" = '[{"job":230,"title":"second"}]' ]
  [ "$(jq .lifetime_jobs <<<"$output")" = "230" ]
  [ "$(jq .next_job <<<"$output")" = "231" ]
  bash "$LEDGER" start 12 "older number"
  [ "$(bash "$LEDGER" show | jq .lifetime_jobs)" = "230" ]
}

@test "park/unpark are idempotent; set-parked overrides the count" {
  bash "$LEDGER" park k5; bash "$LEDGER" park 5; bash "$LEDGER" park k6
  [ "$(bash "$LEDGER" show | jq .parked)" = "2" ]
  bash "$LEDGER" unpark k6; bash "$LEDGER" unpark k6
  run bash "$LEDGER" show
  [ "$(jq .parked <<<"$output")" = "1" ]
  [ "$(jq -c .parked_ids <<<"$output")" = '["k5"]' ]
  bash "$LEDGER" set-parked 7
  [ "$(bash "$LEDGER" show | jq .parked)" = "7" ]
}

@test "missing file shows {}; corrupt file starts fresh; bad args fail without writing" {
  run bash "$LEDGER" show
  [ "$output" = "{}" ]
  run bash "$LEDGER" start abc "x"
  [ "$status" -ne 0 ]
  [ ! -e "$CCXP_LEDGER_FILE" ]
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"; echo '{{bad' > "$CCXP_LEDGER_FILE"
  bash "$LEDGER" start 3 "t"
  [ "$(bash "$LEDGER" show | jq .lifetime_jobs)" = "3" ]
  # no stray temp files left behind
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "1" ]
}

@test "statusline text line shows the ledger section, hidden without a ledger" {
  run bash -c "source '$REPO_ROOT/statusline-setup/scripts/statusline-command.sh'; sl-ledger-part"
  [ -z "$output" ]
  bash "$LEDGER" start 230 "x"; bash "$LEDGER" park 1
  run bash -c "source '$REPO_ROOT/statusline-setup/scripts/statusline-command.sh'; sl-ledger-part"
  [ "$output" = "jobs run 1 · total 230 · parked 1" ]
}
