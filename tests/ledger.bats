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


@test "next add/done allocate increasing n refs and never reuse one" {
  run bash "$LEDGER" next add "Nightly fix: which repo?"
  [ "$output" = "n1" ]
  [ "$(bash "$LEDGER" next add "second")" = "n2" ]
  bash "$LEDGER" next done n1
  bash "$LEDGER" next done 1
  run bash "$LEDGER" show
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["n2"]' ]
  [ "$(jq .next_open <<<"$output")" = "1" ]
  [ "$(jq .ref_counters.n <<<"$output")" = "2" ]
  [ "$(bash "$LEDGER" next add "third")" = "n3" ]
  [ "$(bash "$LEDGER" show | jq -r '.next[0].added_at | length')" = "20" ]
  run bash "$LEDGER" next done n99
  [ "$status" -eq 0 ]
}

@test "input/action are deprecated aliases writing into the same next list" {
  [ "$(bash "$LEDGER" action add "merge PR 5")" = "n1" ]
  [ "$(bash "$LEDGER" input add "q")" = "n2" ]
  bash "$LEDGER" action done N1
  run bash "$LEDGER" show
  [ "$(jq .next_open <<<"$output")" = "1" ]
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["n2"]' ]
  [ "$(jq .inputs_open <<<"$output")" = "0" ]
  [ "$(jq .actions_open <<<"$output")" = "0" ]
  bash "$LEDGER" input done 2
  [ "$(bash "$LEDGER" show | jq .next_open)" = "0" ]
}

@test "old-shape inputs/actions migrate into next on first write, legacy refs kept" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"lifetime_jobs":5,"parked":0,"parked_ids":[],"running":[],"inputs":[{"ref":"i3","text":"q","added_at":"x"}],"actions":[{"ref":"a2","text":"do","added_at":"y"}],"ref_counters":{"i":3,"a":2,"s":4,"k":1}}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" show
  [ "$(jq .next_open <<<"$output")" = "2" ]
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["i3","a2"]' ]
  [ "$(bash "$LEDGER" next add "new")" = "n1" ]
  [ "$(jq 'has("inputs") or has("actions")' "$CCXP_LEDGER_FILE")" = "false" ]
  [ "$(jq -c '[.next[].ref]' "$CCXP_LEDGER_FILE")" = '["i3","a2","n1"]' ]
  [ "$(jq -c .ref_counters "$CCXP_LEDGER_FILE")" = '{"n":1,"i":3,"a":2,"s":4,"k":1}' ]
  bash "$LEDGER" next done i3
  bash "$LEDGER" next done a2
  [ "$(jq -c '[.next[].ref]' "$CCXP_LEDGER_FILE")" = '["n1"]' ]
}

@test "ref next allocates n, s and k; ref bump n22 syncs the counter" {
  bash "$LEDGER" ref bump n22
  [ "$(bash "$LEDGER" ref next n)" = "n23" ]
  [ "$(bash "$LEDGER" next add "q")" = "n24" ]
  bash "$LEDGER" ref bump n3
  [ "$(bash "$LEDGER" show | jq .ref_counters.n)" = "24" ]
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
  bash "$LEDGER" next add "$long"
  bash "$LEDGER" next add "$(printf 'a\nb\tc')"
  run bash "$LEDGER" show
  [ "$(jq '.next[0].text | length' <<<"$output")" = "300" ]
  [ "$(jq -r '.next[1].text' <<<"$output")" = "abc" ]
}

@test "bad new-subcommand args fail without touching the file" {
  bash "$LEDGER" start 1 "t"
  before=$(cat "$CCXP_LEDGER_FILE")
  for args in "next add" "next add ''" "next done x" "next nope" "input add" "action done" "ref next r" "ref next" "ref bump x5" "ref bump n" "ref nope"; do
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
  [ "$(jq .next_open <<<"$output")" = "0" ]
  [ "$(jq .inputs_open <<<"$output")" = "0" ]
  [ "$(jq .actions_open <<<"$output")" = "0" ]
  [ "$(jq -c .ref_counters <<<"$output")" = '{"n":0,"i":0,"a":0,"s":0,"k":0}' ]
  bash "$LEDGER" start 347 "t"
  [ "$(bash "$LEDGER" next add "q")" = "n1" ]
  run bash "$LEDGER" show
  [ "$(jq -c .parked_ids <<<"$output")" = '["k5","k7","k8"]' ]
  [ "$(jq .next_job <<<"$output")" = "348" ]
}

@test "show --brief prints one summary line" {
  bash "$LEDGER" start 1 "t"; bash "$LEDGER" park 2; bash "$LEDGER" next add "q"
  run bash "$LEDGER" show --brief
  [ "$output" = "running=1 parked=1 next_open=1 inputs_open=0 actions_open=0" ]
}

@test "huge ref numbers are rejected and do not poison the counter" {
  run bash "$LEDGER" ref bump n99999999999999999999
  [ "$status" -ne 0 ]
  run bash "$LEDGER" park k99999999999999999999
  [ "$status" -ne 0 ]
  [ "$(bash "$LEDGER" ref next n)" = "n1" ]
}

@test "text is truncated by characters, not bytes" {
  bash "$LEDGER" next add "$(printf 'é%.0s' $(seq 1 400))"
  [ "$(bash "$LEDGER" show | jq '.next[0].text | length')" = "300" ]
}
