#!/usr/bin/env bats
# Tests for hud/scripts/ledger.sh (HUD jobs ledger).

load test_helper
LEDGER="$REPO_ROOT/hud/scripts/ledger.sh"

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


@test "input add/done allocate increasing refs and never reuse one" {
  run bash "$LEDGER" input add "Nightly fix: which repo?"
  [ "$output" = "i1" ]
  [ "$(bash "$LEDGER" input add "second")" = "i2" ]
  bash "$LEDGER" input done i1
  bash "$LEDGER" input done 1
  run bash "$LEDGER" show
  [ "$(jq -c '[.inputs[].ref]' <<<"$output")" = '["i2"]' ]
  [ "$(jq .inputs_open <<<"$output")" = "1" ]
  [ "$(jq .ref_counters.i <<<"$output")" = "2" ]
  [ "$(bash "$LEDGER" input add "third")" = "i3" ]
  [ "$(bash "$LEDGER" show | jq -r '.inputs[0].added_at | length')" = "20" ]
}

@test "action add/done keep their own counter" {
  [ "$(bash "$LEDGER" action add "merge PR 5")" = "a1" ]
  [ "$(bash "$LEDGER" input add "q")" = "i1" ]
  bash "$LEDGER" action done A1
  run bash "$LEDGER" show
  [ "$(jq .actions_open <<<"$output")" = "0" ]
  [ "$(jq .inputs_open <<<"$output")" = "1" ]
  [ "$(jq .ref_counters.a <<<"$output")" = "1" ]
  run bash "$LEDGER" action done a99
  [ "$status" -eq 0 ]
}

@test "ref next allocates s and k; ref bump only raises; park bumps k" {
  [ "$(bash "$LEDGER" ref next s)" = "s1" ]
  [ "$(bash "$LEDGER" ref next s)" = "s2" ]
  bash "$LEDGER" ref bump s10
  [ "$(bash "$LEDGER" ref next s)" = "s11" ]
  bash "$LEDGER" ref bump s3
  [ "$(bash "$LEDGER" show | jq .ref_counters.s)" = "11" ]
  bash "$LEDGER" park k20
  [ "$(bash "$LEDGER" ref next k)" = "k21" ]
  bash "$LEDGER" unpark k20
  [ "$(bash "$LEDGER" show | jq .ref_counters.k)" = "21" ]
}

@test "long text is truncated to 300 chars and control chars are stripped" {
  long=$(printf 'x%.0s' $(seq 1 400))
  bash "$LEDGER" input add "$long"
  bash "$LEDGER" action add "$(printf 'a\nb\tc')"
  run bash "$LEDGER" show
  [ "$(jq '.inputs[0].text | length' <<<"$output")" = "300" ]
  [ "$(jq -r '.actions[0].text' <<<"$output")" = "abc" ]
}

@test "bad new-subcommand args fail without touching the file" {
  bash "$LEDGER" start 1 "t"
  before=$(cat "$CCXP_LEDGER_FILE")
  for args in "input add" "input add ''" "input done x" "input nope" "action done" "ref next r" "ref next" "ref bump x5" "ref bump i" "ref nope"; do
    run bash -c "bash '$LEDGER' $args"
    [ "$status" -ne 0 ]
  done
  [ "$(cat "$CCXP_LEDGER_FILE")" = "$before" ]
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "1" ]
}

@test "old-shape file keeps working and gains the new fields on first write" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"lifetime_jobs":346,"parked":3,"parked_ids":["k5","k7","k8"],"running":[],"updated_at":"x","next_job":347}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" show
  [ "$(jq .lifetime_jobs <<<"$output")" = "346" ]
  [ "$(jq .inputs_open <<<"$output")" = "0" ]
  [ "$(jq .actions_open <<<"$output")" = "0" ]
  [ "$(jq -c .ref_counters <<<"$output")" = '{"i":0,"a":0,"s":0,"k":0}' ]
  bash "$LEDGER" start 347 "t"
  [ "$(bash "$LEDGER" input add "q")" = "i1" ]
  run bash "$LEDGER" show
  [ "$(jq -c .parked_ids <<<"$output")" = '["k5","k7","k8"]' ]
  [ "$(jq .next_job <<<"$output")" = "348" ]
}

@test "show --brief prints one summary line" {
  bash "$LEDGER" start 1 "t"; bash "$LEDGER" park 2; bash "$LEDGER" input add "q"
  run bash "$LEDGER" show --brief
  [ "$output" = "running=1 parked=1 inputs_open=1 actions_open=0" ]
}
