#!/usr/bin/env bats
# Lint tests for `routine-due.sh check` (T20261114-144275): each rule has a failing and a passing fixture.

bats_require_minimum_version 1.5.0
load test_helper
RT="$REPO_ROOT/agent-pairing/scripts/routine-due.sh"

setup() {
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers"
  export CCXP_ROUTINES_PROFILE_FILE="$BATS_TEST_TMPDIR/profile.yml"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dev/TODO"
  git -C "$REPO" init -q
}

check() { printf '%s\n' "$1" >"$REPO/dev/.routines.yml"; run --separate-stderr bash "$RT" --repo "$REPO" check; }

@test "no config: the built-ins pass" {
  run bash "$RT" --repo "$REPO" check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a valid file passes" {
  check $'routines:\n  inbox:\n    schedule: {days: weekdays, at: "07:30"}\n    steps: [{skill: "/email-triage"}]\nhere: [office]'
  [ "$status" -eq 0 ]
}

@test "unquoted at (the integer 630) is rejected with the line" {
  check $'routines:\n  standup:\n    schedule: {at: 10:30}'
  [ "$status" -eq 1 ]
  [[ "$output" == *".routines.yml:2:"*"bad at"* ]]
}

@test "unknown routine key, schedule key and top-level key are rejected" {
  check $'routines:\n  standup: {colour: red}'
  [[ "$output" == *"unknown key 'colour'"* ]]
  check $'routines:\n  standup:\n    schedule: {often: 1}'
  [[ "$output" == *"unknown schedule key 'often'"* ]]
  check $'extra: 1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown top-level key 'extra'"* ]]
}

@test "unknown skill name is rejected; a known one and another plugin's skill pass" {
  check $'routines:\n  r:\n    steps: [{skill: "/no-such-skill"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown skill '/no-such-skill'"* ]]
  check $'routines:\n  r:\n    steps: [{skill: "ccxp-skills:rca"}, {skill: "superpowers:brainstorming"}]'
  [ "$status" -eq 0 ]
}

@test "empty steps is rejected" {
  check $'routines:\n  r:\n    schedule: {days: daily}\n    steps: []'
  [ "$status" -eq 1 ]
  [[ "$output" == *"steps must be a non-empty list"* ]]
}

@test "duplicate routine names are rejected" {
  check $'routines:\n  r:\n    steps: [{skill: "/rca"}]\n  r:\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate routine name 'r'"* ]]
}

@test "bad every, bad days, every with at, bad once_per, bad on_failure" {
  check $'routines:\n  r:\n    schedule: {every: soon}\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"bad every"* ]]
  check $'routines:\n  r:\n    schedule: {days: [funday]}\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"bad days"* ]]
  check $'routines:\n  r:\n    schedule: {every: 5m, at: "07:30"}\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"every or at, not both"* ]]
  check $'routines:\n  r:\n    schedule: {once_per: year}\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"once_per must be day or week"* ]]
  check $'routines:\n  r:\n    on_failure: explode\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"on_failure"* ]]
}

@test "a once_per week window wrapping sun to mon is rejected" {
  check $'routines:\n  r:\n    schedule: {days: [sun, mon], once_per: week}\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot wrap"* ]]
}

@test "allow is honored only from the profile file" {
  check $'routines:\n  r:\n    allow: [slack-post]\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"allow is honored only from the profile file"* ]]
  rm -f "$REPO/dev/.routines.yml"
  printf 'routines:\n  r:\n    allow: [slack-post]\n    steps: [{skill: "/rca"}]\n' >"$CCXP_ROUTINES_PROFILE_FILE"
  run bash "$RT" --repo "$REPO" check
  [ "$status" -eq 0 ]
}

@test "routines-file: is rejected in the tracked file; unparsable YAML is reported" {
  check $'routines-file: /x'
  [ "$status" -eq 1 ]
  check $'routines: [unclosed'
  [ "$status" -eq 1 ]
  [[ "$output" == *"file skipped"* ]]
}

@test "a block scalar with a trailing newline is not a valid time or interval" {
  check $'routines:\n  r:\n    schedule:\n      at: |\n        09:00\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad at"* ]]
  check $'routines:\n  r:\n    schedule:\n      every: |\n        5m\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"bad every"* ]]
}

@test "bad routine names and also_claims entries are rejected" {
  check $'routines:\n  "../x":\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad routine name"* ]]
  check $'routines:\n  r:\n    also_claims: ["*"]\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"bad also_claims entry"* ]]
  check $'routines:\n  r:\n    also_claims: [r]\n    steps: [{skill: "/rca"}]'
  [[ "$output" == *"bad also_claims entry"* ]]
}

@test "at or not_before later than not_after is rejected" {
  check $'routines:\n  r:\n    schedule: {at: "12:00", not_after: "10:00"}\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"later than not_after"* ]]
}

@test "an unknown tz is rejected" {
  check $'routines:\n  r:\n    tz: Foo/Bar\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown tz"* ]]
  check $'routines:\n  r:\n    tz: Asia/Shanghai\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 0 ]
}

@test "an unhashable key or non-UTF-8 file is skipped whole, not a crash" {
  check $'? [a, b]\n: 1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"file skipped"* ]]
  printf 'routines:\n  r: \xff\xfe\n' >"$REPO/dev/.routines.yml"
  run --separate-stderr bash "$RT" --repo "$REPO" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"file skipped"* ]]
}

@test "null in a brand-new routine is treated as unset" {
  check $'routines:\n  r:\n    schedule: {days: weekdays, at: ~}\n    steps: [{skill: "/rca"}]'
  [ "$status" -eq 0 ]
}
