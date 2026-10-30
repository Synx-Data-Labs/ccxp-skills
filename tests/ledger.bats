#!/usr/bin/env bats
# Tests for hud/scripts/ledger.sh (HUD jobs ledger).

bats_require_minimum_version 1.5.0
load test_helper
LEDGER="$REPO_ROOT/hud/scripts/ledger.sh"

setup() { export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/sub/ledger.json"; }

@test "start/finish track running jobs; lifetime is the highest number ever started" {
  bash "$LEDGER" start 229 "first"
  bash "$LEDGER" start 230 "second"
  bash "$LEDGER" finish 229
  run bash "$LEDGER" show
  [ "$(jq -c '.running | map(del(.started_at))' <<<"$output")" = '[{"job":230,"title":"second","context":""}]' ]
  [ "$(jq .lifetime_jobs <<<"$output")" = "230" ]
  [ "$(jq .next_job <<<"$output")" = "231" ]
  bash "$LEDGER" start 12 "older number"
  [ "$(bash "$LEDGER" show | jq .lifetime_jobs)" = "230" ]
}

@test "park/unpark are idempotent; parked is one array, set-parked is a no-op" {
  bash "$LEDGER" park k5; bash "$LEDGER" park 5; bash "$LEDGER" park k6
  [ "$(bash "$LEDGER" show | jq '.parked | length')" = "2" ]
  bash "$LEDGER" unpark k6; bash "$LEDGER" unpark k6
  run bash "$LEDGER" show
  [ "$(jq -c .parked <<<"$output")" = '[{"id":"k5","context":""}]' ]
  [ "$(jq 'has("parked_ids")' <<<"$output")" = "false" ]
  run bash "$LEDGER" set-parked 7
  [ "$status" -eq 0 ]
  [ "$(bash "$LEDGER" show | jq '.parked | length')" = "1" ]
}

@test "--context is stored for start, park and next add; a later start keeps it; park updates in place" {
  bash "$LEDGER" start 8 "job" --context /ctx/a.md
  bash "$LEDGER" start 8 "job again"
  [ "$(bash "$LEDGER" next add "q" --context /ctx/n.md)" = "n1" ]
  [ "$(bash "$LEDGER" next add "plain")" = "n2" ]
  bash "$LEDGER" park k3 --context /ctx/p.md --title "Parked thing"
  bash "$LEDGER" park k3 --context /ctx/p2.md
  run bash "$LEDGER" show
  [ "$(jq -c '.running | map(del(.started_at))' <<<"$output")" = '[{"job":8,"title":"job again","context":"/ctx/a.md"}]' ]
  [ "$(jq -c '[.next[] | [.ref, .context]]' <<<"$output")" = '[["n1","/ctx/n.md"],["n2",""]]' ]
  [ "$(jq -c .parked <<<"$output")" = '[{"id":"k3","context":"/ctx/p2.md","title":"Parked thing"}]' ]
  run bash "$LEDGER" next add "x" --context relative/path
  [ "$status" -ne 0 ]
  run bash "$LEDGER" park k4 --context
  [ "$status" -ne 0 ]
}

@test "every write renders ccxp-ledger.md with clickable context paths on their own lines" {
  bash "$LEDGER" start 8 "job" --context /ctx/a.md
  bash "$LEDGER" next add "q" --context /ctx/n.md
  bash "$LEDGER" park k3 --context /ctx/p.md --title "Parked thing"
  md="$(dirname "$CCXP_LEDGER_FILE")/ledger.md"
  [ -f "$md" ]
  grep -q '^## Running (1)$' "$md"
  grep -Eq '^- r8 \[[0-9]{2}:[0-9]{2}\] job$' "$md"
  grep -q '^  /ctx/a.md$' "$md"
  grep -q '^- n1 q$' "$md"
  grep -q '^  /ctx/n.md$' "$md"
  grep -q '^- k3 Parked thing$' "$md"
  grep -q '^  /ctx/p.md$' "$md"
  bash "$LEDGER" finish 8
  grep -q '^## Running (0)$' "$md"
}

@test "old file migrates on first write: backup kept, parked_ids become items, count discrepancy reported" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"lifetime_jobs":9,"parked":3,"parked_ids":["k5"],"running":[{"job":9,"title":"t"}]}' > "$CCXP_LEDGER_FILE"
  old=$(cat "$CCXP_LEDGER_FILE")
  run --separate-stderr bash "$LEDGER" next add "q"
  [[ "$stderr" == *"legacy parked count 3 > 1 ids"* ]]
  [ "$(jq -c .parked "$CCXP_LEDGER_FILE")" = '[{"id":"k5","context":""}]' ]
  [ "$(jq .schema "$CCXP_LEDGER_FILE")" = "3" ]
  bak=$(ls "$CCXP_LEDGER_FILE".bak-*)
  [ "$(cat "$bak")" = "$old" ]
  bash "$LEDGER" next add "again"
  [ "$(ls "$CCXP_LEDGER_FILE".bak-* | wc -l | tr -d ' ')" = "1" ]
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
  # no stray temp files left behind: json, md and the backup of the corrupt file
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "3" ]
}


@test "next add/done allocate increasing n refs and never reuse one" {
  run bash "$LEDGER" next add "Nightly fix: which repo?"
  [ "$output" = "n1" ]
  [ "$(bash "$LEDGER" next add "second")" = "n2" ]
  bash "$LEDGER" next done n1
  bash "$LEDGER" next done 1
  run bash "$LEDGER" show
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["n2"]' ]
  [ "$(jq '.next | length' <<<"$output")" = "1" ]
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
  [ "$(jq '.next | length' <<<"$output")" = "1" ]
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["n2"]' ]
  [ "$(jq 'has("inputs") or has("actions")' <<<"$output")" = "false" ]
  bash "$LEDGER" input done 2
  [ "$(bash "$LEDGER" show | jq '.next | length')" = "0" ]
}

@test "old-shape inputs/actions migrate into next on first write, legacy refs kept" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"lifetime_jobs":5,"parked":0,"parked_ids":[],"running":[],"inputs":[{"ref":"i3","text":"q","added_at":"x"}],"actions":[{"ref":"a2","text":"do","added_at":"y"}],"ref_counters":{"i":3,"a":2,"s":4,"k":1}}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" show
  [ "$(jq '.next | length' <<<"$output")" = "2" ]
  [ "$(jq -c '[.next[].ref]' <<<"$output")" = '["i3","a2"]' ]
  [ "$(bash "$LEDGER" next add "new")" = "n1" ]
  [ "$(jq 'has("inputs") or has("actions")' "$CCXP_LEDGER_FILE")" = "false" ]
  [ "$(jq -c '[.next[].ref]' "$CCXP_LEDGER_FILE")" = '["i3","a2","n1"]' ]
  [ "$(jq -c .ref_counters "$CCXP_LEDGER_FILE")" = '{"n":1,"s":4,"k":1}' ]
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
  for args in "next add" "next add ''" "next done x" "next nope" "input add" "action done" "ref next r" "ref next i" "ref next a" "park k1 --context rel" "start 1 t --context" "ref next" "ref bump x5" "ref bump n" "ref nope"; do
    run bash -c "bash '$LEDGER' $args"
    [ "$status" -ne 0 ]
  done
  [ "$(cat "$CCXP_LEDGER_FILE")" = "$before" ]
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "2" ]
}

@test "old-shape file keeps working and gains the new fields on first write" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"lifetime_jobs":346,"parked":3,"parked_ids":["k5","k7","k8"],"running":[],"updated_at":"x","next_job":347}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" show
  [ "$(jq .lifetime_jobs <<<"$output")" = "346" ]
  [ "$(jq '.next | length' <<<"$output")" = "0" ]
  [ "$(jq 'has("inputs") or has("actions")' <<<"$output")" = "false" ]
  [ "$(jq -c .ref_counters <<<"$output")" = '{"n":0,"s":0,"k":0}' ]
  bash "$LEDGER" start 347 "t"
  [ "$(bash "$LEDGER" next add "q")" = "n1" ]
  run bash "$LEDGER" show
  [ "$(jq -c '[.parked[].id]' <<<"$output")" = '["k5","k7","k8"]' ]
  [ "$(jq .next_job <<<"$output")" = "348" ]
}

@test "show --brief prints one summary line" {
  bash "$LEDGER" start 1 "t"; bash "$LEDGER" park 2; bash "$LEDGER" next add "q"
  run bash "$LEDGER" show --brief
  [ "$output" = "running=1 parked=1 next=1" ]
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

@test "start stores HH:MM started_at and a re-start keeps it" {
  bash "$LEDGER" start 8 "job"
  at=$(bash "$LEDGER" show | jq -r '.running[0].started_at')
  [[ "$at" =~ ^[0-9]{2}:[0-9]{2}$ ]]
  bash "$LEDGER" start 8 "job again"
  [ "$(bash "$LEDGER" show | jq -r '.running[0].started_at')" = "$at" ]
}

@test "next add --ref picks a ref, bumps the counter, rejects a taken ref" {
  [ "$(bash "$LEDGER" next add "a" --ref n75)" = "n75" ]
  [ "$(bash "$LEDGER" show | jq .ref_counters.n)" = "75" ]
  [ "$(bash "$LEDGER" next add "b")" = "n76" ]
  run bash "$LEDGER" next add "dup" --ref n75
  [ "$status" -ne 0 ]
  [ "$(bash "$LEDGER" show | jq '.next | length')" = "2" ]
  [ "$(bash "$LEDGER" next add "low" --ref n3)" = "n3" ]
  [ "$(bash "$LEDGER" show | jq .ref_counters.n)" = "76" ]
  run bash "$LEDGER" next add "bad" --ref x3
  [ "$status" -ne 0 ]
}

@test "next done keeps a done history capped at 20 with closed_at" {
  for i in $(seq 1 22); do bash "$LEDGER" next add "t$i" >/dev/null; done
  for i in $(seq 1 22); do bash "$LEDGER" next done n$i; done
  run bash "$LEDGER" show
  [ "$(jq '.done | length' <<<"$output")" = "20" ]
  [ "$(jq -r '.done[0].ref' <<<"$output")" = "n3" ]
  [ "$(jq -r '.done[-1] | [.ref, .text, (.closed_at | length)] | join(",")' <<<"$output")" = "n22,t22,20" ]
  [ "$(jq '.next | length' <<<"$output")" = "0" ]
}

@test "next set edits text and context; unknown ref fails" {
  bash "$LEDGER" next add "old" --context /c/a.md
  bash "$LEDGER" next set n1 --text "new"
  bash "$LEDGER" next set 1 --context /c/b.md
  [ "$(bash "$LEDGER" show | jq -c '.next[0] | [.text, .context, .added_at != ""]')" = '["new","/c/b.md",true]' ]
  run bash "$LEDGER" next set n9 --text x
  [ "$status" -ne 0 ]
  run bash "$LEDGER" next set n1 --text ""
  [ "$status" -ne 0 ]
  run bash "$LEDGER" next set n1 --context rel
  [ "$status" -ne 0 ]
}

@test "set-counter sets n, s and k exactly; bad args fail" {
  bash "$LEDGER" set-counter n 75
  bash "$LEDGER" set-counter k 14
  [ "$(bash "$LEDGER" show | jq -c .ref_counters)" = '{"n":75,"s":0,"k":14}' ]
  [ "$(bash "$LEDGER" next add "q")" = "n76" ]
  [ "$(bash "$LEDGER" ref next k)" = "k15" ]
  bash "$LEDGER" set-counter n 5
  [ "$(bash "$LEDGER" show | jq .ref_counters.n)" = "5" ]
  run bash "$LEDGER" set-counter r 1
  [ "$status" -ne 0 ]
  run bash "$LEDGER" set-counter n x
  [ "$status" -ne 0 ]
}

@test "render prints Next, Running, Parked in reply format plus the Ledger line; empty sections are omitted" {
  run bash "$LEDGER" render
  [ "$output" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  bash "$LEDGER" start 8 "job eight" --context /c/8.md
  bash "$LEDGER" next add "ask me" --context /c/n.md
  bash "$LEDGER" park k3 --title "Parked thing" --context /c/p.md
  bash "$LEDGER" park k4
  run bash "$LEDGER" render
  [ "${lines[0]}" = "Next:" ]
  [ "${lines[1]}" = "**n1** ask me" ]
  [ "${lines[2]}" = "  /c/n.md" ]
  [ "${lines[3]}" = "Running:" ]
  [[ "${lines[4]}" =~ ^r8\ \[[0-9]{2}:[0-9]{2}\]\ job\ eight$ ]]
  [ "${lines[5]}" = "  /c/8.md" ]
  [ "${lines[6]}" = "Parked:" ]
  [ "${lines[7]}" = "**k3** Parked thing" ]
  [ "${lines[8]}" = "  /c/p.md" ]
  [ "${lines[9]}" = "**k4**" ]
  [ "${lines[-1]}" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
}
