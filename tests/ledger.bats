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
  [ "$(jq -c '.running | map({job, title, context})' <<<"$output")" = '[{"job":230,"title":"second","context":""}]' ]
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
  [ "$(jq -c '.running | map({job, title, context})' <<<"$output")" = '[{"job":8,"title":"job again","context":"/ctx/a.md"}]' ]
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
  grep -q '^  context: file:///ctx/a.md$' "$md"
  grep -q '^- n1 q$' "$md"
  grep -q '^  context: file:///ctx/n.md$' "$md"
  grep -q '^- k3 Parked thing$' "$md"
  grep -q '^  context: file:///ctx/p.md$' "$md"
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
  # no stray temp files left behind: json, md, the start log and the backup of the corrupt file
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "4" ]
}


@test "next add/done allocate increasing n refs and never reuse one" {
  run bash "$LEDGER" next add "Nightly fix: which repo?" --context /c/q.md
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
  [ "$(ls "$(dirname "$CCXP_LEDGER_FILE")" | wc -l | tr -d ' ')" = "3" ]   # json, md, start log
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
  [ "${lines[2]}" = "  file:///c/n.md" ]
  [ "${lines[3]}" = "Running:" ]
  [[ "${lines[4]}" =~ ^r8\ \[[0-9]{2}:[0-9]{2}\]\ job\ eight$ ]]
  [ "${lines[5]}" = "  file:///c/8.md" ]
  [ "${lines[6]}" = "Parked:" ]
  [ "${lines[7]}" = "**k3** Parked thing" ]
  [ "${lines[8]}" = "  file:///c/p.md" ]
  [ "${lines[9]}" = "**k4**" ]
  [ "${lines[-1]}" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
}

@test "review fixes: empty file starts fresh, s/k refs rejected by next done, newer schema not overwritten, big numbers rejected" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"; : > "$CCXP_LEDGER_FILE"
  bash "$LEDGER" start 3 "t"
  [ "$(bash "$LEDGER" show | jq .lifetime_jobs)" = "3" ]
  bash "$LEDGER" next add "q" >/dev/null
  run bash "$LEDGER" next done k1
  [ "$status" -ne 0 ]
  run bash "$LEDGER" start 99999999999999999999 x
  [ "$status" -ne 0 ]
  echo '{"schema":4,"lifetime_jobs":1}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" start 5 x
  [ "$status" -ne 0 ]
  [ "$(cat "$CCXP_LEDGER_FILE")" = '{"schema":4,"lifetime_jobs":1}' ]
}

@test "start saves prompt, agent and flags; a repeated start keeps them; finish drops the prompt copy" {
  bash "$LEDGER" start 5 "five" --context /c/5.md --agent general-purpose/sonnet --flags autopilot --prompt-stdin <<<"do the thing"
  f="$(dirname "$CCXP_LEDGER_FILE")/ccxp-prompts/5.md"
  [ "$(cat "$f")" = "do the thing" ]
  [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]
  bash "$LEDGER" start 5 "five again"
  run bash "$LEDGER" show
  [ "$(jq -r '.running[0] | [.prompt, .agent, .flags, .context] | join("|")' <<<"$output")" = "$f|general-purpose/sonnet|autopilot|/c/5.md" ]
  bash "$LEDGER" finish 5
  [ ! -e "$f" ]
}

@test "start refuses a prompt that looks like a credential and bad flags" {
  fake="gh""p_$(printf 'a%.0s' {1..30})"
  run bash "$LEDGER" start 5 x --prompt-stdin <<<"token $fake"
  [ "$status" -eq 2 ]
  [ "$(bash "$LEDGER" show --brief)" = "running=0 parked=0 next=0" ]
  run bash "$LEDGER" start 5 x --flags bogus
  [ "$status" -eq 2 ]
}

@test "reconcile: lists only running rows that are not alive, as TSV" {
  bash "$LEDGER" start 531 "alive one" --context /c/531.md --prompt-stdin <<<"p531"
  bash "$LEDGER" start 532 "dead one" --context /c/532.md --agent general-purpose/sonnet --flags needs-confirmation --prompt-stdin <<<"p532"
  run bash "$LEDGER" reconcile --alive 531,533
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  IFS=$'\t' read -r job title ctx prompt started agent flags resumed check on <<<"$output"
  [ "$job" = "532" ]; [ "$title" = "dead one" ]; [ "$ctx" = "/c/532.md" ]
  [ "$prompt" = "$(dirname "$CCXP_LEDGER_FILE")/ccxp-prompts/532.md" ]
  [ "$agent" = "general-purpose/sonnet" ]; [ "$flags" = "needs-confirmation" ]; [ "$resumed" = "0" ]
  [ -n "$started" ]; [ "$check" = "ok" ]; [ "$on" = "$(date +%F)" ]
}

@test "reconcile: all alive prints nothing; none alive prints all; list from stdin; list is required" {
  bash "$LEDGER" start 1 "a"; bash "$LEDGER" start 2 "b"
  run bash "$LEDGER" reconcile --alive "1, 2"
  [ "$output" = "" ]
  run bash "$LEDGER" reconcile --alive ""
  [ "${#lines[@]}" -eq 2 ]
  run bash -c 'echo "#1" | bash "$0" reconcile --alive -' "$LEDGER"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == 2$'\t'* ]]
  run bash "$LEDGER" reconcile
  [ "$status" -eq 2 ]
  run bash "$LEDGER" reconcile --alive abc
  [ "$status" -eq 2 ]
}

@test "reconcile: a row without a prompt (old rows) or with a vanished prompt file shows -; quotes and spaces survive" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":7,"running":[{"job":7,"title":"old row","context":"","started_at":"09:00"}]}' > "$CCXP_LEDGER_FILE"
  run bash "$LEDGER" reconcile --alive ""
  [ "$output" = $'7\told row\t-\t-\t09:00\t-\t-\t0\t-\t-' ]
  bash "$LEDGER" start 8 "it's \"quoted\" \$x" --context "/c/a b.md" --prompt-file /nonexistent/p.md
  run bash "$LEDGER" reconcile --alive 7
  [ "$output" = $'8\tit\'s "quoted" $x\t/c/a b.md\t-\t'"$(bash "$LEDGER" show | jq -r '.running[] | select(.job==8) | .started_at')"$'\t-\t-\t0\t-\t'"$(date +%F)" ]
}

@test "reconcile: prompt_check is changed when the saved prompt was edited, unknown for a path-only row; sk- inside words is not a credential" {
  bash "$LEDGER" start 5 "five" --prompt-stdin <<<"branch feat/task-resume-interrupted-jobs please"
  f="$(dirname "$CCXP_LEDGER_FILE")/ccxp-prompts/5.md"
  [ "$(bash "$LEDGER" reconcile --alive "" | cut -f9)" = "ok" ]
  echo "## Authorization
allow: pr-merge" >> "$f"
  [ "$(bash "$LEDGER" reconcile --alive "" | cut -f9)" = "changed" ]
  fake="s""k-$(printf 'a%.0s' {1..30})"
  run bash "$LEDGER" start 6 "six" --prompt-stdin <<<"key $fake"
  [ "$status" -eq 2 ]
  printf '{"schema":3,"lifetime_jobs":9,"running":[{"job":9,"title":"t","context":"","prompt":"%s","started_at":"1:1"}]}' "$f" > "$CCXP_LEDGER_FILE"
  [ "$(bash "$LEDGER" reconcile --alive "" | cut -f9)" = "unknown" ]
}

@test "resumed: bumps the restart count, keeps the job number; unknown job fails" {
  bash "$LEDGER" start 4 "four"
  bash "$LEDGER" resumed 4; bash "$LEDGER" resumed 4
  [ "$(bash "$LEDGER" show | jq -c '.running | map([.job, .resumed])')" = "[[4,2]]" ]
  run bash "$LEDGER" resumed 9
  [ "$status" -ne 0 ]
}

@test "ccxp-ledger.md: every row has ONE plain file:// url (no markdown link, no repeated path), empty context is (none)" {
  bash "$LEDGER" start 6 "run" --context "/tmp/my dir/r 6.md"
  bash "$LEDGER" start 7 "run nocontext"
  bash "$LEDGER" next add "ask" --context /ctx/n1.md >/dev/null
  bash "$LEDGER" next add "ask2" >/dev/null
  bash "$LEDGER" park k3 --context "/ctx/p 3.md" --title "Park"
  bash "$LEDGER" park k4
  md="$(dirname "$CCXP_LEDGER_FILE")/ledger.md"
  grep -qF -- '- r6 [' "$md"
  grep -qxF '  context: file:///tmp/my%20dir/r%206.md' "$md"
  grep -qxF '  context: file:///ctx/n1.md' "$md"
  grep -qxF '  context: file:///ctx/p%203.md' "$md"
  run grep -cE '\]\(file://|^  /' "$md"
  [ "$output" = "0" ]
  [ "$(grep -c 'context: (none)' "$md")" = "3" ]
  grep -qxF "Ledger: file://$(dirname "$CCXP_LEDGER_FILE" | sed 's/ /%20/g')/ledger.md" "$md"
  run bash "$LEDGER" render
  [[ "$output" == *$'\n  file:///tmp/my%20dir/r%206.md'* ]]
  [[ "$output" != *'/tmp/my dir/r 6.md'* ]]
}

@test "--started-at on start and set-started override the start time; format is validated" {
  bash "$LEDGER" start 531 "old" --started-at 09:35
  [ "$(bash "$LEDGER" show | jq -r '.running[0].started_at')" = "09:35" ]
  bash "$LEDGER" start 531 "old again"
  [ "$(bash "$LEDGER" show | jq -r '.running[0].started_at')" = "09:35" ]
  bash "$LEDGER" start 533 "other"
  bash "$LEDGER" set-started 533 12:19
  [ "$(bash "$LEDGER" show | jq -r '.running[] | select(.job==533) | .started_at')" = "12:19" ]
  for bad in 9:35 24:00 12:60 noon ""; do
    run bash "$LEDGER" set-started 533 "$bad"; [ "$status" -eq 2 ]
  done
  run bash "$LEDGER" start 534 x --started-at 25:00; [ "$status" -eq 2 ]
  run bash "$LEDGER" set-started 999 10:00; [ "$status" -ne 0 ]
}

@test "reply prints Running, Next, Parked, Ledger in that order as plain text; --tldr goes first" {
  run bash "$LEDGER" reply
  [ "$output" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  bash "$LEDGER" start 8 "job eight" --context /c/8.md
  bash "$LEDGER" next add "ask me" --context /c/n.md
  bash "$LEDGER" park k3 --title "Parked thing" --context /c/p.md
  run bash "$LEDGER" reply --tldr "all good"
  [ "${lines[0]}" = "TL;DR: all good" ]
  [ "${lines[1]}" = "Running:" ]
  [[ "${lines[2]}" =~ ^r8\ \[[0-9:-]{5}\]\ job\ eight$ ]]
  [ "${lines[3]}" = "  file:///c/8.md" ]
  [ "${lines[4]}" = "Next:" ]
  [ "${lines[5]}" = "n1 ask me" ]
  [ "${lines[6]}" = "  file:///c/n.md" ]
  [ "${lines[7]}" = "Parked:" ]
  [ "${lines[8]}" = "k3 Parked thing" ]
  [ "${lines[9]}" = "  file:///c/p.md" ]
  [ "${lines[-1]}" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  [[ "$output" != *'**'* && "$output" != *'|'* ]]
  run bash "$LEDGER" reply --bogus
  [ "$status" -eq 2 ]
}

@test "check passes on the reply tail, and reports MISSING and EXTRA refs with exit 1" {
  bash "$LEDGER" start 8 "job eight" --context /c/8.md
  bash "$LEDGER" next add "ask me" --context /c/n.md
  bash "$LEDGER" park k3 --context /c/p.md
  bash "$LEDGER" reply > "$BATS_TEST_TMPDIR/ok.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/ok.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$LEDGER" check - < "$BATS_TEST_TMPDIR/ok.txt"
  [ "$status" -eq 0 ]
  # drop n1, add n9 (bold and list markers are tolerated), prose mentions are ignored
  { echo "see r8 and n1 in prose"; echo "- **r8** job"; echo "1. **n9** invented"; echo "k3"; } > "$BATS_TEST_TMPDIR/bad.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/bad.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING n1"* ]]
  [[ "$output" == *"EXTRA n9"* ]]
  [[ "$output" != *"r8"* && "$output" != *"k3"* ]]
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/none.txt"
  [ "$status" -eq 2 ]
}

@test "context is required: reply shows context: MISSING, check prints NO-CONTEXT refs, next add and park warn" {
  bash "$LEDGER" start 8 "job eight"
  run bash "$LEDGER" next add "ask me"
  [[ "$output" == *"warning: next add without --context"* ]]
  run bash "$LEDGER" park k3
  [[ "$output" == *"warning: k3 has no context"* ]]
  run bash "$LEDGER" next add "fine" --context /c/n.md
  [ "$output" = "n2" ]
  run bash "$LEDGER" park k3 --context /c/p.md
  [ -z "$output" ]
  run bash "$LEDGER" park k3
  [ -z "$output" ]
  bash "$LEDGER" unpark k3
  run bash "$LEDGER" reply
  [[ "$output" == *$'r8 '*$'\n  context: MISSING'* ]]
  [[ "$output" == *$'n1 ask me\n  context: MISSING'* ]]
  [[ "$output" == *$'n2 fine\n  file:///c/n.md'* ]]
  bash "$LEDGER" reply > "$BATS_TEST_TMPDIR/r.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO-CONTEXT r8"* && "$output" == *"NO-CONTEXT n1"* && "$output" != *"NO-CONTEXT n2"* ]]
}

@test "check only counts lowercase refs that open a line (prose like R2 is ignored)" {
  bash "$LEDGER" start 8 "j" --context /c/8.md
  printf 'R2 is a prose line\nr8 [10:00] j\n' > "$BATS_TEST_TMPDIR/p.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/p.txt"
  [ "$status" -eq 0 ]
}

# ---- decisions log (ledger.sh decision ...) ----

dj() { echo "$(dirname "$CCXP_LEDGER_FILE")/ccxp-decisions.json"; }
dmd() { echo "$(dirname "$CCXP_LEDGER_FILE")/ccxp-decisions.md"; }

@test "decision add prints d<n>, stores every field, writes json and md in mode 600 next to the ledger" {
  run bash "$LEDGER" decision add "Never merge on Fridays" --quote "no friday merges" --scope repo:foo --context /ctx/d.md --source r12
  [ "$status" -eq 0 ]; [ "$output" = "d1" ]
  [ "$(bash "$LEDGER" decision add "Plain one")" = "d2" ]
  [ "$(jq -c '.decisions[0] | [.ref,.text,.quote,.scope,.context,.source,.status]' "$(dj)")" = '["d1","Never merge on Fridays","no friday merges","repo:foo","/ctx/d.md","r12","active"]' ]
  [ "$(jq -r '.decisions[1].scope' "$(dj)")" = "global" ]
  [ "$(jq .counter "$(dj)")" = "2" ]
  [ "$(ls -l "$(dj)" | cut -c1-10)" = "-rw-------" ]
  [ "$(ls -l "$(dmd)" | cut -c1-10)" = "-rw-------" ]
  [ "$(ls "$(dirname "$(dj)")" | grep -c '^ccxp-decisions.json\.')" = "0" ]
}

@test "decision: CCXP_DECISIONS_FILE overrides the location" {
  export CCXP_DECISIONS_FILE="$BATS_TEST_TMPDIR/elsewhere/dec.json"
  bash "$LEDGER" decision add "x"
  [ -f "$BATS_TEST_TMPDIR/elsewhere/dec.json" ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/dec.md" ]
  [ ! -f "$(dj)" ]
}

@test "decision: counter is never reused after retire, supersede, bump and set-counter" {
  bash "$LEDGER" decision add "a" >/dev/null
  bash "$LEDGER" decision retire d1
  [ "$(bash "$LEDGER" decision add "b")" = "d2" ]
  [ "$(bash "$LEDGER" decision supersede d2 "c")" = "d3" ]
  bash "$LEDGER" set-counter d 10
  [ "$(bash "$LEDGER" decision add "d")" = "d11" ]
  bash "$LEDGER" ref bump d20
  bash "$LEDGER" ref bump d5
  [ "$(bash "$LEDGER" ref next d)" = "d21" ]
  [ "$(bash "$LEDGER" decision add "e")" = "d22" ]
  [ "$(bash "$LEDGER" decision add "f" | head -1)" = "d23" ]
  # a zeroed counter is repaired from the highest remaining ref
  jq '.decisions |= map(select(.ref != "d23")) | .counter = 0' "$(dj)" > "$BATS_TEST_TMPDIR/t.json" && cp "$BATS_TEST_TMPDIR/t.json" "$(dj)"
  [ "$(bash "$LEDGER" decision add "g")" = "d23" ]
  run bash "$LEDGER" set-counter d x
  [ "$status" -ne 0 ]
  run bash "$LEDGER" ref next q
  [ "$status" -ne 0 ]
}

@test "decision: ledger refs and the decisions counter stay independent" {
  bash "$LEDGER" decision add "a" >/dev/null
  [ "$(bash "$LEDGER" next add "q")" = "n1" ]
  [ "$(bash "$LEDGER" show | jq -c .ref_counters)" = '{"n":1,"s":0,"k":0}' ]
}

@test "decision add rejects credentials, over-long text and quote, empty text, bad scope and relative context" {
  run bash "$LEDGER" decision add "token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 2 ]; [[ "$output" == *credential* ]]
  run bash "$LEDGER" decision add "fine" --quote "key AKIA""ABCDEFGHIJKLMNOP"
  [ "$status" -eq 2 ]
  run bash "$LEDGER" decision add "$(printf 'x%.0s' $(seq 401))"
  [ "$status" -eq 2 ]; [[ "$output" == *"max 400"* ]]
  [ "$(bash "$LEDGER" decision add "$(printf 'x%.0s' $(seq 400))")" = "d1" ]
  run bash "$LEDGER" decision add "fine" --quote "$(printf 'q%.0s' $(seq 601))"
  [ "$status" -eq 2 ]; [[ "$output" == *"max 600"* ]]
  run bash "$LEDGER" decision add ""
  [ "$status" -eq 2 ]
  run bash "$LEDGER" decision add "fine" --scope everywhere
  [ "$status" -eq 2 ]
  run bash "$LEDGER" decision add "fine" --context rel/path
  [ "$status" -eq 2 ]
  run bash "$LEDGER" decision add "fine" --quote
  [ "$status" -eq 2 ]
  [ "$(jq '.decisions | length' "$(dj)")" = "1" ]
}

@test "decision: control characters are stripped from text" {
  bash "$LEDGER" decision add $'one\nline\x01' >/dev/null
  [ "$(jq -r '.decisions[0].text' "$(dj)")" = "oneline" ]
}

@test "decision supersede keeps history, links old to new, inherits scope unless given" {
  bash "$LEDGER" decision add "use sonnet" --scope repo:foo >/dev/null
  run bash "$LEDGER" decision supersede d1 "use opus" --quote "opus from now on"
  [ "$status" -eq 0 ]; [ "$output" = "d2" ]
  [ "$(jq -c '.decisions | map([.ref,.status,.superseded_by,.scope])' "$(dj)")" = '[["d1","superseded","d2","repo:foo"],["d2","active","","repo:foo"]]' ]
  [ "$(jq -r '.decisions[0].closed_at | length' "$(dj)")" = "20" ]
  [ "$(bash "$LEDGER" decision supersede d2 "use haiku" --scope global)" = "d3" ]
  [ "$(jq -r '.decisions[2].scope' "$(dj)")" = "global" ]
  run bash "$LEDGER" decision supersede d1 "again"
  [ "$status" -eq 1 ]; [[ "$output" == *"already superseded"* ]]
  run bash "$LEDGER" decision supersede d99 "nope"
  [ "$status" -eq 1 ]; [[ "$output" == *"no decision d99"* ]]
  run bash "$LEDGER" decision supersede d3 "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 2 ]
  [ "$(bash "$LEDGER" decision list --json | jq 'length')" = "1" ]
}

@test "decision retire marks it retired with a reason; unknown or already closed refs error" {
  bash "$LEDGER" decision add "a" >/dev/null
  run bash "$LEDGER" decision retire D1 "no longer applies"
  [ "$status" -eq 0 ]; [ "$output" = "d1" ]
  [ "$(jq -c '.decisions[0] | [.status,.reason]' "$(dj)")" = '["retired","no longer applies"]' ]
  run bash "$LEDGER" decision retire d1
  [ "$status" -eq 1 ]
  run bash "$LEDGER" decision retire d7
  [ "$status" -eq 1 ]; [[ "$output" == *"no decision d7"* ]]
  run bash "$LEDGER" decision retire zz
  [ "$status" -eq 2 ]
}

@test "decision list: active only by default, newest first; --all, --scope, --json" {
  bash "$LEDGER" decision add "first" --scope repo:foo --quote "q1" --context /c/1.md >/dev/null
  bash "$LEDGER" decision add "second" >/dev/null
  bash "$LEDGER" decision add "third" --scope repo:foo >/dev/null
  bash "$LEDGER" decision retire d2 "gone"
  run bash "$LEDGER" decision list
  [[ "${lines[0]}" =~ ^d3\ \[[0-9-]{10}\]\ repo:foo:\ third$ ]]
  [[ "${lines[1]}" =~ ^d1\ \[ ]]
  [ "${lines[2]}" = '  quote: "q1"' ]
  [ "${lines[3]}" = "  context: /c/1.md" ]
  [ "${#lines[@]}" -eq 4 ]
  run bash "$LEDGER" decision list --all
  [[ "$output" == *"d2 "* && "$output" == *"status: retired (gone)"* ]]
  run bash "$LEDGER" decision list --scope global
  [ "$output" = "no decisions" ]
  run bash "$LEDGER" decision list --scope repo:foo --json
  [ "$(jq -c 'map(.ref)' <<<"$output")" = '["d3","d1"]' ]
  [ "$(bash "$LEDGER" decision list --all --json | jq 'length')" = "3" ]
}

@test "decision list on a missing file says no decisions and writes nothing" {
  run bash "$LEDGER" decision list
  [ "$status" -eq 0 ]; [ "$output" = "no decisions" ]
  [ ! -e "$(dj)" ]
}

@test "decision show prints one entry; unknown ref errors; bad usage prints usage" {
  bash "$LEDGER" decision add "keep it" --quote "q" --source r5 >/dev/null
  run bash "$LEDGER" decision show d1
  [ "$status" -eq 0 ]; [[ "${lines[0]}" =~ ^d1\ \[[0-9-]{10}\]\ global:\ keep\ it$ ]]
  [[ "$output" == *'quote: "q"'* && "$output" == *"source: r5"* ]]
  run bash "$LEDGER" decision show d2
  [ "$status" -eq 1 ]; [[ "$output" == *"no decision d2"* ]]
  run bash "$LEDGER" decision show
  [ "$status" -eq 2 ]
  run bash "$LEDGER" decision bogus
  [ "$status" -eq 2 ]; [[ "$output" == *usage* ]]
}

@test "decision: ccxp-decisions.md groups active by scope newest first, then one line per superseded/retired" {
  bash "$LEDGER" decision add "global old" --quote "owner said so" --context /ctx/a b.md >/dev/null
  bash "$LEDGER" decision add "repo rule" --scope repo:foo >/dev/null
  bash "$LEDGER" decision add "global new" >/dev/null
  bash "$LEDGER" decision supersede d1 "global older replaced" >/dev/null
  bash "$LEDGER" decision retire d2 "obsolete"
  md="$(dmd)"
  grep -q '^# CCXP decisions$' "$md"
  grep -q '^## Active (2)$' "$md"
  grep -q '^### global$' "$md"
  ! grep -q '^### repo:foo$' "$md"
  [ "$(grep -n '^- d4 \[' "$md" | cut -d: -f1)" -lt "$(grep -n '^- d3 \[' "$md" | cut -d: -f1)" ]
  grep -Eq '^- d3 \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] global new$' "$md"
  grep -q '^## Superseded / retired (2)$' "$md"
  grep -Eq '^- d1 \[[0-9-]{10}\] global old - superseded by d4 \([0-9-]{10}\)$' "$md"
  grep -Eq '^- d2 \[[0-9-]{10}\] repo rule - retired: obsolete \([0-9-]{10}\)$' "$md"
  bash "$LEDGER" decision add "with ctx" --quote "owner words" --context "/ctx/a b.md" >/dev/null
  grep -q '^  quote: "owner words"$' "$md"
  grep -q '^  context: file:///ctx/a%20b.md$' "$md"
}

@test "decision: archive moves old closed entries past 200 to ccxp-decisions-archive.json, keeps active and recent ones" {
  bash "$LEDGER" decision add "keep active" >/dev/null
  jq '.decisions += [range(2; 206) | {ref: ("d" + tostring), text: "old \(.)", quote: "", scope: "global", context: "", source: "",
        added_at: "2025-01-01T00:00:00Z", status: (if . % 2 == 0 then "retired" else "superseded" end), superseded_by: "", reason: "", closed_at: "2025-02-01T00:00:00Z"}]
      | .decisions[10].closed_at = "2999-01-01T00:00:00Z" | .counter = 205' "$(dj)" > "$BATS_TEST_TMPDIR/big.json"
  cp "$BATS_TEST_TMPDIR/big.json" "$(dj)"
  [ "$(bash "$LEDGER" decision add "trigger")" = "d206" ]
  af="$(dirname "$(dj)")/ccxp-decisions-archive.json"
  [ -f "$af" ]
  [ "$(ls -l "$af" | cut -c1-10)" = "-rw-------" ]
  [ "$(jq '.decisions | length' "$af")" = "203" ]
  [ "$(jq '.decisions | length' "$(dj)")" = "3" ]
  [ "$(jq -r '.decisions | map(.ref) | join(",")' "$(dj)")" = "d1,d11,d206" ]
  run bash "$LEDGER" decision show d50
  [ "$status" -eq 0 ]; [[ "${lines[0]}" == "(archived)" ]]
  [ "$(bash "$LEDGER" decision add "next")" = "d207" ]
  [ "$(jq '.decisions | length' "$af")" = "203" ]
}

@test "decision: no archiving at or below 200 entries" {
  bash "$LEDGER" decision add "a" >/dev/null
  jq '.decisions += [range(2; 201) | {ref: ("d" + tostring), text: "old", quote: "", scope: "global", context: "", source: "",
        added_at: "2025-01-01T00:00:00Z", status: "retired", superseded_by: "", reason: "", closed_at: "2025-02-01T00:00:00Z"}] | .counter = 200' "$(dj)" > "$BATS_TEST_TMPDIR/b.json"
  cp "$BATS_TEST_TMPDIR/b.json" "$(dj)"
  bash "$LEDGER" decision retire d1 >/dev/null
  [ ! -e "$(dirname "$(dj)")/ccxp-decisions-archive.json" ]
  [ "$(jq '.decisions | length' "$(dj)")" = "200" ]
}

@test "decision: a corrupt decisions file is never overwritten; a newer schema is refused" {
  mkdir -p "$(dirname "$(dj)")"; echo "not json {" > "$(dj)"
  run bash "$LEDGER" decision add "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"not overwriting"* ]]
  [ "$(cat "$(dj)")" = "not json {" ]
  echo '{"schema":2,"decisions":[]}' > "$(dj)"
  run bash "$LEDGER" decision add "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"newer schema"* ]]
}

@test "decision: reply and render print a Decisions line and md path before the Ledger line, only with active decisions" {
  run bash "$LEDGER" reply
  [ "$output" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  bash "$LEDGER" decision add "retired one" >/dev/null
  bash "$LEDGER" decision retire d1
  run bash "$LEDGER" reply
  [ "$output" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  bash "$LEDGER" decision add "first" >/dev/null
  bash "$LEDGER" decision add "second rule" >/dev/null
  bash "$LEDGER" next add "q" --context /c/n.md >/dev/null
  run bash "$LEDGER" reply
  [ "${lines[-1]}" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  [ "${lines[-3]}" = "Decisions: 2 active (latest: d3 second rule)" ]
  [ "${lines[-2]}" = "  $(dmd)" ]
  run bash "$LEDGER" reply --no-decisions --tldr "hi"
  [[ "$output" != *Decisions* ]]
  [ "${lines[0]}" = "TL;DR: hi" ]
  run bash "$LEDGER" render
  [ "${lines[-1]}" = "Ledger: $(dirname "$CCXP_LEDGER_FILE")/ledger.md" ]
  [[ "$output" == *"Decisions: 2 active (latest: d3 second rule)"* ]]
  mv "$(dmd)" "$BATS_TEST_TMPDIR/old.md"
  bash "$LEDGER" render >/dev/null
  [ -f "$(dmd)" ]
}

@test "decision: the reply tail with a Decisions line still passes check, and check flags malformed entries only" {
  bash "$LEDGER" start 4 "job" --context /c/4.md
  bash "$LEDGER" decision add "rule" >/dev/null
  bash "$LEDGER" reply > "$BATS_TEST_TMPDIR/r.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  jq '.decisions += [{"ref":"x1","text":"bad"}, {"ref":"d2","text":""}]' "$(dj)" > "$BATS_TEST_TMPDIR/m.json"; cp "$BATS_TEST_TMPDIR/m.json" "$(dj)"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^MALFORMED' <<<"$output")" = "2" ]
  [[ "$output" != *MISSING* && "$output" != *EXTRA* ]]
}

@test "decision: show and show --brief include a decisions summary only when the file exists" {
  bash "$LEDGER" start 3 "j" >/dev/null
  [ "$(bash "$LEDGER" show --brief)" = "running=1 parked=0 next=0" ]
  [ "$(bash "$LEDGER" show | jq 'has("decisions")')" = "false" ]
  bash "$LEDGER" decision add "one" >/dev/null
  bash "$LEDGER" decision add "two" >/dev/null
  [ "$(bash "$LEDGER" show --brief)" = "running=1 parked=0 next=0 decisions=2" ]
  [ "$(bash "$LEDGER" show | jq -c .decisions)" = '{"active":2,"latest":{"ref":"d2","text":"two"}}' ]
}

@test "decision: writes refuse while the file has malformed entries or a non-array decisions; nothing is dropped" {
  bash "$LEDGER" decision add "keep" >/dev/null
  jq '.decisions += [{"ref":"bad","text":"x","extra":"keep"}]' "$(dj)" > "$BATS_TEST_TMPDIR/m.json"; cp "$BATS_TEST_TMPDIR/m.json" "$(dj)"
  run bash "$LEDGER" decision add "more"
  [ "$status" -eq 1 ]; [[ "$output" == *"not writing"* ]]
  [ "$(jq -r '.decisions[1].extra' "$(dj)")" = "keep" ]
  echo '{"schema":1,"decisions":{"a":1}}' > "$(dj)"
  run bash "$LEDGER" decision add "more"
  [ "$status" -eq 1 ]; [[ "$output" == *"not an array"* ]]
  [ "$(jq -c .decisions "$(dj)")" = '{"a":1}' ]
}

@test "decision: set-counter d never lowers the counter; --source is checked for credentials; archived refs are named as such" {
  bash "$LEDGER" decision add "a" >/dev/null; bash "$LEDGER" decision add "b" >/dev/null
  bash "$LEDGER" set-counter d 0
  [ "$(bash "$LEDGER" decision add "c")" = "d3" ]
  run bash "$LEDGER" decision add "d" --source "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 2 ]
  printf '%s\n' '{"schema":1,"decisions":[{"ref":"d9","text":"old","status":"retired"}]}' > "$(dirname "$(dj)")/ccxp-decisions-archive.json"
  run bash "$LEDGER" decision retire d9
  [ "$status" -eq 1 ]; [[ "$output" == *archived* ]]
}

@test "decision: a corrupt archive file is never overwritten; archiving is skipped" {
  bash "$LEDGER" decision add "keep" >/dev/null
  jq '.decisions += [range(2; 206) | {ref: ("d" + tostring), text: "old", quote: "", scope: "global", context: "", source: "",
        added_at: "2025-01-01T00:00:00Z", status: "retired", superseded_by: "", reason: "", closed_at: "2025-02-01T00:00:00Z"}] | .counter = 205' "$(dj)" > "$BATS_TEST_TMPDIR/b.json"
  cp "$BATS_TEST_TMPDIR/b.json" "$(dj)"
  af="$(dirname "$(dj)")/ccxp-decisions-archive.json"; echo garbage > "$af"
  run bash "$LEDGER" decision add "trigger"
  [ "$status" -eq 0 ]; [[ "$output" == *"not a valid archive"* ]]
  [ "$(cat "$af")" = "garbage" ]
  [ "$(jq '.decisions | length' "$(dj)")" = "206" ]
  run bash "$LEDGER" decision add "x" --context "/tmp/ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 2 ]
}

@test "decision: an empty archive file blocks archiving (nothing lost); supersede also checks --context" {
  bash "$LEDGER" decision add "keep" >/dev/null
  jq '.decisions += [range(2; 206) | {ref: ("d" + tostring), text: "old", quote: "", scope: "global", context: "", source: "",
        added_at: "2025-01-01T00:00:00Z", status: "retired", superseded_by: "", reason: "", closed_at: "2025-02-01T00:00:00Z"}] | .counter = 205' "$(dj)" > "$BATS_TEST_TMPDIR/b.json"
  cp "$BATS_TEST_TMPDIR/b.json" "$(dj)"
  af="$(dirname "$(dj)")/ccxp-decisions-archive.json"; : > "$af"
  run bash "$LEDGER" decision add "trigger"
  [[ "$output" == *"not a valid archive"* ]]
  [ ! -s "$af" ]
  [ "$(jq '.decisions | length' "$(dj)")" = "206" ]
  run bash "$LEDGER" decision supersede d1 "b" --context "/tmp/ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.decisions[0].status' "$(dj)")" = "active" ]
}

@test "decision: concurrent adds are serialized (no lost entries, no duplicate refs); the lock is released" {
  for i in 1 2 3 4 5 6 7 8; do bash "$LEDGER" decision add "c$i" >/dev/null & done
  wait
  [ "$(jq '.decisions | length' "$(dj)")" = "8" ]
  [ "$(jq '[.decisions[].ref] | unique | length' "$(dj)")" = "8" ]
  [ ! -e "$(dj).lock" ]
  mkdir "$(dj).lock"; touch -t 202001010000 "$(dj).lock"
  [ "$(bash "$LEDGER" decision add "after stale lock")" = "d9" ]
}

@test "decision: the counter is capped at 8 digits so refs always stay valid" {
  run bash "$LEDGER" set-counter d 999999999
  [ "$status" -eq 2 ]
  run bash "$LEDGER" ref bump d999999999
  [ "$status" -eq 2 ]
  bash "$LEDGER" set-counter d 99999999
  [ "$(bash "$LEDGER" decision add "edge")" = "d100000000" ]
}

# ---- authorization list ----

Q="At this moment, I trust you to do the customer visible posts, tagging, and pushing artifacts, and updating/closing github issues and gitlab issues. You can leave the rest of the items (e.g. delete data, secret handling, etc.) to me."

@test "authz: unknown, unlisted and unset capabilities default to no; reads write no file" {
  [ "$(bash "$LEDGER" authz show tagging)" = "no" ]
  [ "$(bash "$LEDGER" authz show never_heard_of_it)" = "no" ]
  [ "$(bash "$LEDGER" authz list | wc -l | tr -d ' ')" = "13" ]
  [ "$(bash "$LEDGER" authz list | cut -f2 | sort -u)" = "no" ]
  [ ! -e "$BATS_TEST_TMPDIR/sub/ccxp-authz.json" ]
}

@test "authz set/list: stores value, quote, note and date; the owner's seed list reads back" {
  for k in customer_visible_posts tagging pushing_artifacts github_issues_update_close gitlab_issues_update_close; do
    run bash "$LEDGER" authz set "$k" yes --quote "$Q"; [ "$status" -eq 0 ]; [ "$output" = "$k: yes" ]
  done
  for k in delete_data secret_handling spend_money third_party_messages admin_or_bypass install_software_outside_repo owner_accounts_credentials unlisted_other; do
    bash "$LEDGER" authz set "$k" no --quote "$Q" --note "owner keeps this"
  done
  [ "$(bash "$LEDGER" authz show tagging)" = "yes" ]
  [ "$(bash "$LEDGER" authz show secret_handling)" = "no" ]
  [ "$(bash "$LEDGER" authz list | cut -f2 | grep -c yes)" = "5" ]
  run bash "$LEDGER" authz list --json
  [ "$(jq -r '.[] | select(.key == "tagging") | .quote' <<<"$output")" = "$Q" ]
  [ "$(jq -r '.[] | select(.key == "delete_data") | .note' <<<"$output")" = "owner keeps this" ]
  [ "$(jq -r '.[] | select(.key == "tagging") | .date' <<<"$output")" != "" ]
}

@test "authz set: validates key and value, requires a quote for yes, rejects credentials, keeps custom keys" {
  run bash "$LEDGER" authz set Bad yes; [ "$status" -eq 2 ]
  run bash "$LEDGER" authz set tagging maybe; [ "$status" -eq 2 ]
  run bash "$LEDGER" authz set tagging; [ "$status" -eq 2 ]
  run bash "$LEDGER" authz set tagging yes --quote "$(printf 'gh%s' 'p_abcdefghijklmnopqrstuvwxyz0123456789')"; [ "$status" -eq 2 ]
  run --separate-stderr bash "$LEDGER" authz set tagging yes; [ "$status" -eq 2 ]
  [[ "$stderr" == *"needs --quote"* ]]
  [ "$(bash "$LEDGER" authz show tagging)" = "no" ]
  run bash "$LEDGER" authz set k1 no; [ "$status" -eq 2 ]
  run bash "$LEDGER" authz set k1_x yes --quote q; [ "$status" -eq 2 ]
  run bash "$LEDGER" authz set zz yes --quote " "; [ "$status" -eq 2 ]
  bash "$LEDGER" authz set my_custom yes --quote x
  [ "$(bash "$LEDGER" authz show my_custom)" = "yes" ]
  [ "$(bash "$LEDGER" authz list | tail -1 | cut -f1)" = "my_custom" ]
  run bash "$LEDGER" authz bogus; [ "$status" -eq 2 ]
}

@test "authz: file is mode 600, atomic (no temp or lock left), valid JSON; setting again replaces in place" {
  bash "$LEDGER" authz set tagging yes --quote a
  bash "$LEDGER" authz set tagging no --quote b
  f="$BATS_TEST_TMPDIR/sub/ccxp-authz.json"
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = "600" ]
  jq -e '.schema == 1 and (.entries | length) == 1 and .entries.tagging.value == "no" and .entries.tagging.quote == "b"' "$f"
  [ -z "$(ls "$BATS_TEST_TMPDIR/sub" | grep -E 'ccxp-authz\.json\.')" ]
}

@test "authz: a corrupt file is never overwritten; CCXP_AUTHZ_FILE overrides the location" {
  mkdir -p "$BATS_TEST_TMPDIR/sub"; echo 'not json' > "$BATS_TEST_TMPDIR/sub/ccxp-authz.json"
  run bash "$LEDGER" authz set tagging yes --quote x; [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/sub/ccxp-authz.json")" = "not json" ]
  [ "$(bash "$LEDGER" authz show tagging)" = "no" ]
  export CCXP_AUTHZ_FILE="$BATS_TEST_TMPDIR/other/az.json"
  bash "$LEDGER" authz set tagging yes --quote x
  [ -f "$BATS_TEST_TMPDIR/other/az.json" ]
}

@test "authz: reply, render and ccxp-ledger.md show an Authorization section after Parked, only once a list exists" {
  bash "$LEDGER" park k1 --context /c/p.md
  run bash "$LEDGER" reply; [[ "$output" != *Authorization* ]]
  bash "$LEDGER" authz set tagging yes --quote x
  for cmd in reply render; do
    run bash "$LEDGER" $cmd
    [[ "$output" == *"Parked:"*"Authorization:"*"  tagging: yes"*"  delete_data: no"*"Ledger: "* ]]
  done
  md="$BATS_TEST_TMPDIR/sub/ledger.md"
  [ "$(grep -c '^- .*: \(yes\|no\)$' "$md")" = "13" ]
  grep -q '^- tagging: yes$' "$md"
  [ "$(grep -n '^## Parked' "$md" | cut -d: -f1)" -lt "$(grep -n '^## Authorization (13)' "$md" | cut -d: -f1)" ]
  printf 'k1 parked\n' > "$BATS_TEST_TMPDIR/r.txt"
  run bash "$LEDGER" check "$BATS_TEST_TMPDIR/r.txt"; [ "$status" -eq 0 ]
}

# --- start log + stats (jobs started in the rolling last 24 h vs the lifetime average per day) ---

LOG() { printf '%s' "${CCXP_LEDGER_FILE%.json}-starts.log"; }

@test "start appends '<epoch><TAB><n>' to the start log once per job (a re-start or a second start of a running job adds nothing)" {
  export LEDGER_NOW=1800000000
  bash "$LEDGER" start 5 "five"
  bash "$LEDGER" start 5 "five again"
  LEDGER_NOW=1800000100 bash "$LEDGER" start 6 "six"
  [ "$(cat "$(LOG)")" = $'1800000000\t5\n1800000100\t6' ]
  [ "$(stat -c %a "$(LOG)" 2>/dev/null || stat -f %Lp "$(LOG)")" = 600 ]
  # no titles or prompts in the log
  ! grep -q five "$(LOG)"
  # a finished job that is started again is not counted twice
  bash "$LEDGER" finish 5
  LEDGER_NOW=1800000200 bash "$LEDGER" start 5 "five reopened"
  [ "$(wc -l < "$(LOG)" | tr -d ' ')" -eq 2 ]
}

@test "the first start on a ledger that already counts jobs writes a one-time seed (first-job estimate from the oldest migration backup)" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":782,"running":[]}' > "$CCXP_LEDGER_FILE"
  touch "$CCXP_LEDGER_FILE.bak-20261030T172334Z-1" "$CCXP_LEDGER_FILE.bak-20261101T000000Z-2"
  LEDGER_NOW=1793834380 bash "$LEDGER" start 783 "x"
  LEDGER_NOW=1793834400 bash "$LEDGER" start 784 "y"
  [ "$(cat "$(LOG)")" = $'#seed\t1793381014\t1793834380\n1793834380\t783\n1793834400\t784' ]
}

@test "a fresh ledger (no jobs yet) gets no seed: the first logged start is the first job" {
  LEDGER_NOW=1800000000 bash "$LEDGER" start 1 "x"
  [ "$(cat "$(LOG)")" = $'1800000000\t1' ]
}

@test "stats: 24h count is starts in (now-86400, now]; the average is lifetime jobs over max(1, days since the first job); trend vs the 1-decimal average" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":100,"running":[]}' > "$CCXP_LEDGER_FILE"
  local now=1800000000 d=86400
  # exact log (no seed): first start 10 days ago; 100 jobs / 10 days = 10.0 per day
  printf '%s\t1\n%s\t98\n%s\t99\n%s\t100\n' $((now - 10 * d)) $((now - d)) $((now - 3600)) $((now - 60)) > "$(LOG)"
  LEDGER_NOW=$now run bash "$LEDGER" stats --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '{approx, avg_approx, jobs_24h, avg_jobs_day, trend}' <<<"$output")" = '{"approx":false,"avg_approx":false,"jobs_24h":2,"avg_jobs_day":10,"trend":"down"}' ]
  # the start exactly 24 h ago is outside the window; a future-dated or malformed line is skipped
  printf '%s\t101\nnonsense\n%s\t102\n' $((now - 10)) $((now + 500)) >> "$(LOG)"
  echo '{"schema":3,"lifetime_jobs":102,"running":[]}' > "$CCXP_LEDGER_FILE"
  LEDGER_NOW=$now run bash "$LEDGER" stats --json
  [ "$(jq .jobs_24h <<<"$output")" -eq 3 ]
  [ "$(jq .trend <<<"$output")" = '"down"' ]
  # busy day: up
  printf '%s\t103\n%s\t104\n%s\t105\n%s\t106\n%s\t107\n%s\t108\n%s\t109\n%s\t110\n%s\t111\n%s\t112\n%s\t113\n' $(for k in $(seq 1 11); do echo $((now - 100 - k)); done) >> "$(LOG)"
  LEDGER_NOW=$now run bash "$LEDGER" stats --json
  [ "$(jq .trend <<<"$output")" = '"up"' ]
  # the plain form
  LEDGER_NOW=$now run bash "$LEDGER" stats
  [[ "$output" == "24h: 14 jobs started · lifetime "* ]]
}

@test "stats: equal at one decimal is flat; days are at least 1" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":3,"running":[]}' > "$CCXP_LEDGER_FILE"
  local now=1800000000
  printf '%s\t1\n%s\t2\n%s\t3\n' $((now - 600)) $((now - 500)) $((now - 400)) > "$(LOG)"
  LEDGER_NOW=$now run bash "$LEDGER" stats --json
  [ "$(jq -c '{jobs_24h, lifetime_days, avg_jobs_day, trend}' <<<"$output")" = '{"jobs_24h":3,"lifetime_days":1,"avg_jobs_day":3,"trend":"flat"}' ]
}

@test "stats: a seeded log is approximate (avg estimated; the 24h count too while the log is under 24 h old)" {
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":782,"running":[]}' > "$CCXP_LEDGER_FILE"
  local now=1800000000 d=86400
  printf '#seed\t%s\t%s\n%s\t783\n' $((now - 5 * d)) $((now - 3600)) $((now - 60)) > "$(LOG)"
  LEDGER_NOW=$now run bash "$LEDGER" stats --json
  [ "$(jq -c '{approx, avg_approx, jobs_24h, avg_jobs_day}' <<<"$output")" = '{"approx":true,"avg_approx":true,"jobs_24h":1,"avg_jobs_day":156.4}' ]
  # a day later the log covers the whole window: the count is exact, the average stays an estimate
  LEDGER_NOW=$((now + 2 * d)) run bash "$LEDGER" stats --json
  [ "$(jq -c '{approx, avg_approx}' <<<"$output")" = '{"approx":false,"avg_approx":true}' ]
}

@test "stats: no log yet on a ledger with jobs is an approximate zero; an empty ledger prints nothing; stats never writes" {
  LEDGER_NOW=1800000000 run bash "$LEDGER" stats --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$(dirname "$CCXP_LEDGER_FILE")"
  echo '{"schema":3,"lifetime_jobs":50,"running":[]}' > "$CCXP_LEDGER_FILE"
  LEDGER_NOW=1800000000 run bash "$LEDGER" stats --json
  [ "$(jq -c '{approx, jobs_24h}' <<<"$output")" = '{"approx":true,"jobs_24h":0}' ]
  [ ! -e "$(LOG)" ]
}

@test "reply url-encodes a context path with spaces and non-ascii; decisions md header is a plain file:// url" {
  bash "$LEDGER" start 8 "job" --context "/c/a b/é%.md"
  run bash "$LEDGER" reply
  [[ "$output" == *$'\n  file:///c/a%20b/%C3%A9%25.md'* ]]
  bash "$LEDGER" decision add "d" --context "/ctx/x.md" >/dev/null
  run grep -c "^Decisions: file://" "$(dj | sed "s/\.json\$/.md/")"
  [ "$output" = "1" ]
}
