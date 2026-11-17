#!/usr/bin/env bats
# nightly-check/scripts/nightly-check.sh plan: filter, one line per run, alert-thread routing, nothing when green.
# Fixture run lists only; the script never calls gh or Slack.

load test_helper

NC="$REPO_ROOT/nightly-check/scripts/nightly-check.sh"
NOW=1800000000   # fixed clock

# run-json <id> <event> <workflow> <age-hours> [conclusion]: one gh run list element
run_json() {
  local at
  at="$(date -u -r $((NOW - $4 * 3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((NOW - $4 * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"databaseId":%s,"event":"%s","workflowName":"%s","headBranch":"main","conclusion":"%s","createdAt":"%s","url":"https://github.com/example-org/example-repo/actions/runs/%s"}' \
    "$1" "$2" "$3" "${5:-failure}" "$at" "$1"
}

plan() { run bash -c 'bash "$1" plan --now "$2" "${@:3}"' _ "$NC" "$NOW" "$@"; }

@test "filter: schedule runs and nightly-named dispatch runs only" {
  json="[$(run_json 11111111111 schedule "Nightly Build" 2),$(run_json 22222222222 workflow_dispatch "Nightly Test" 3),$(run_json 33333333333 workflow_dispatch "Release" 3),$(run_json 44444444444 push "Nightly Build" 3),$(run_json 55555555555 pull_request "CI" 1)]"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3"' _ "$json" "$NC" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$output" == *$'\t11111111111\t'* ]]
  [[ "$output" == *$'\t22222222222\t'* ]]
  [[ "$output" != *33333333333* ]]
  [[ "$output" != *44444444444* ]]
}

@test "window: runs older than the window are dropped, oldest first" {
  json="[$(run_json 11111111111 schedule "Nightly" 2),$(run_json 22222222222 schedule "Nightly" 30),$(run_json 33333333333 schedule "Nightly" 10)]"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3"' _ "$json" "$NC" "$NOW"
  [ "$status" -eq 0 ]
  [[ "$output" != *22222222222* ]]
  first="$(printf '%s\n' "$output" | head -1 | cut -f3)"
  [ "$first" = 33333333333 ]
}

@test "green: nothing printed when no run failed" {
  json="[$(run_json 11111111111 schedule "Nightly" 2 success)]"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3"' _ "$json" "$NC" "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c 'printf "[]" | bash "$1" plan --now "$2"' _ "$NC" "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "one RCA line per failed run, rca route without alerts" {
  json="[$(run_json 11111111111 schedule "Nightly A" 2),$(run_json 22222222222 schedule "Nightly B" 3)]"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3"' _ "$json" "$NC" "$NOW"
  [ "$(printf '%s\n' "$output" | grep -c $'^run\trca\t')" -eq 2 ]
}

@test "alert routing: a run named in an alert goes to labrun-rca with its ts" {
  json="[$(run_json 11111111111 schedule "Nightly A" 2),$(run_json 22222222222 schedule "Nightly B" 3)]"
  printf '1799990000.000100\tNightly A failed https://github.com/example-org/example-repo/actions/runs/11111111111\n1799990001.000100\tunrelated run 111111111110\n' > "$BATS_TEST_TMPDIR/alerts"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3" --alerts "$4"' _ "$json" "$NC" "$NOW" "$BATS_TEST_TMPDIR/alerts"
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep $'^run\tlabrun-rca\t11111111111\t')"
  [ "$(printf '%s' "$line" | cut -f6)" = 1799990000.000100 ]
  [[ "$output" == *$'run\trca\t22222222222\t'* ]]
}

@test "handled: a run id found in the handled file is skipped" {
  json="[$(run_json 11111111111 schedule "Nightly A" 2),$(run_json 22222222222 schedule "Nightly B" 3)]"
  printf 'task mentions run 11111111111\n' > "$BATS_TEST_TMPDIR/handled"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3" --handled "$4"' _ "$json" "$NC" "$NOW" "$BATS_TEST_TMPDIR/handled"
  [[ "$output" != *11111111111* ]]
  [[ "$output" == *22222222222* ]]
}

@test "cap: runs beyond --max print as next" {
  json="[$(run_json 11111111111 schedule "N" 5),$(run_json 22222222222 schedule "N" 4),$(run_json 33333333333 schedule "N" 3)]"
  run bash -c 'printf "%s" "$1" | bash "$2" plan --now "$3" --max 2' _ "$json" "$NC" "$NOW"
  [ "$(printf '%s\n' "$output" | grep -c '^run')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c '^next')" -eq 1 ]
  [[ "$output" == *$'next\trca\t33333333333'* ]]
}

@test "errors: bad usage exits 2, non-array stdin exits 3" {
  run bash "$NC" bogus
  [ "$status" -eq 2 ]
  run bash -c 'printf "%s" "{}" | bash "$1" plan --now 1' _ "$NC"
  [ "$status" -eq 3 ]
  run bash -c 'printf "[]" | bash "$1" plan --max x' _ "$NC"
  [ "$status" -eq 2 ]
}
