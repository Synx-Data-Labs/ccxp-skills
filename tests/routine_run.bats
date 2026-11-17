#!/usr/bin/env bats
# Tests for routine/scripts/run-routine.sh (T20261114-400715): run records, rollup, claim and retry arithmetic.

bats_require_minimum_version 1.5.0
load test_helper
RR="$REPO_ROOT/routine/scripts/run-routine.sh"
RT="$REPO_ROOT/agent-pairing/scripts/routine-due.sh"
FRI_NOON=1794592800   # 2026-11-13 Fri 12:00 CST

setup() {
  python3 -I -c 'import yaml' 2>/dev/null || skip "PyYAML missing"
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers"
  export CCXP_ROUTINES_RUN_DIR="$BATS_TEST_TMPDIR/runs"
  export CCXP_RITUAL_TZ="America/Chicago"
  export CCXP_ROUTINES_PROFILE_FILE="$BATS_TEST_TMPDIR/profile.yml"
  export CCXP_RITUAL_NOW=$FRI_NOON
  unset CCXP_RITUALS CCXP_RITUAL_TTL
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dev/TODO"
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin git@example.com:acme/widgets.git
  cat >"$REPO/dev/.routines.yml" <<'YML'
routines:
  standup: {enabled: false}
  ipm: {enabled: false}
  retro: {enabled: false}
  stopper:
    schedule: {days: daily, at: "00:00", once_per: day}
    steps: [{skill: "/todo"}, {skill: "/top", args: "--x"}, {skill: "/stage"}]
    on_failure: stop
  keeper:
    schedule: {days: daily, at: "00:00", once_per: day}
    steps: [{skill: "/todo"}, {skill: "/top"}, {skill: "/stage"}]
    on_failure: continue
    allow: [archive]
YML
}

rr() { bash "$RR" --repo "$REPO" "$@" 2>/dev/null; }
due() { bash "$RT" --repo "$REPO" "$@" 2>/dev/null; }
field() { python3 -I -c 'import json,sys,glob;r=json.load(open(glob.glob(sys.argv[1])[0]));print(eval(sys.argv[2]))' "$CCXP_ROUTINES_RUN_DIR/*/$1.json" "$2"; }

@test "plan prints the steps and writes nothing" {
  run rr plan stopper
  [ "$status" -eq 0 ]
  [ "$output" = $'1\t/todo\t\n2\t/top\t--x\n3\t/stage\t' ]
  [ ! -e "$CCXP_ROUTINES_RUN_DIR" ]
}

@test "plan of an unknown routine exits 3" {
  run rr plan nosuch
  [ "$status" -eq 3 ]
}

@test "stop: a failed step skips the rest, the run is partial and the claim is released" {
  run due claim
  [ "$output" = "stopper 2026-11-13" ]
  rr begin stopper --key 2026-11-13
  run rr step stopper 2026-11-13 1 ok
  [ "$output" = continue ]
  run rr step stopper 2026-11-13 2 failed "boom"
  [ "$output" = stop ]
  run rr finish stopper 2026-11-13 "one step failed"
  [ "$output" = "status=partial claim=release attempt=1" ]
  [ "$(field 'stopper-2026-11-13' "[s['status'] for s in r['steps']]")" = "['ok', 'failed', 'skipped']" ]
  # released: due again at the next check
  run due list
  [[ "$output" == *"stopper 2026-11-13"* ]]
}

@test "continue: every step runs, the run is partial and the claim is done" {
  run due claim
  run due claim
  [ "$output" = "keeper 2026-11-13" ]
  rr begin keeper --key 2026-11-13
  run rr step keeper 2026-11-13 1 failed "x"
  [ "$output" = continue ]
  rr step keeper 2026-11-13 2 ok
  rr step keeper 2026-11-13 3 nothing-to-do
  run rr finish keeper 2026-11-13 "flaky"
  [ "$output" = "status=partial claim=done attempt=1" ]
  run due list
  [[ "$output" != *keeper* ]]
}

@test "all steps ok or nothing-to-do: status ok, claim done" {
  due claim >/dev/null
  rr begin stopper --key 2026-11-13
  rr step stopper 2026-11-13 1 ok
  rr step stopper 2026-11-13 2 nothing-to-do
  rr step stopper 2026-11-13 3 ok
  run rr finish stopper 2026-11-13 "all good"
  [ "$output" = "status=ok claim=done attempt=1" ]
}

@test "a single failing step with nothing else run rolls up as failed" {
  python3 -I - "$REPO/dev/.routines.yml" <<'PY'
import sys
open(sys.argv[1], "a").write('  solo:\n    schedule: {days: daily, at: "00:00", once_per: day}\n    steps: [{skill: "/todo"}]\n')
PY
  rr begin solo --key 2026-11-13
  rr step solo 2026-11-13 1 failed "bad"
  run rr finish solo 2026-11-13
  [[ "$output" == "status=failed claim=release"* ]]
}

@test "needs-human is reported once, not retried: the claim is done and stop skips the rest" {
  due claim >/dev/null
  rr begin stopper --key 2026-11-13
  run rr step stopper 2026-11-13 1 needs-human "which account?"
  [ "$output" = stop ]
  run rr finish stopper 2026-11-13 "needs a human"
  [ "$output" = "status=needs-human claim=done attempt=1" ]
  run due list
  [[ "$output" != *stopper* ]]
}

@test "retry cap: the 4th failed attempt of a key is capped (released, attempts exits 1)" {
  for n in 1 2 3 4; do
    rr begin stopper --key 2026-11-13
    rr step stopper 2026-11-13 1 failed x
    run rr finish stopper 2026-11-13
    if [ "$n" -lt 4 ]; then [[ "$output" == *"claim=release attempt=$n" ]]; run rr attempts stopper 2026-11-13; [ "$status" -eq 0 ]; fi
  done
  [[ "$output" == *"claim=capped attempt=4" ]]
  run rr attempts stopper 2026-11-13
  [ "$status" -eq 1 ]
  [ "$output" = 4 ]
}

@test "a manual run touches no claim and uses a manual- key" {
  run rr begin stopper
  [[ "$output" =~ ^manual-[0-9]+$ ]]
  key="$output"
  rr step stopper "$key" 1 ok
  run rr finish stopper "$key" "manual"
  [[ "$output" == "status=partial claim=none"* || "$output" == "status=ok claim=none"* ]]
  run due list
  [[ "$output" == *"stopper 2026-11-13"* ]]
  [ ! -e "$CCXP_RITUAL_DIR" ] || [ -z "$(find "$CCXP_RITUAL_DIR" -name 'stopper-*' 2>/dev/null)" ]
}

@test "record schema: fixed keys, free text is one line and capped" {
  rr begin stopper --key 2026-11-13
  long="$(printf 'x%.0s' $(seq 1 500))"
  rr step stopper 2026-11-13 1 ok "$(printf 'line one\nline two %s' "$long")"
  rr finish stopper 2026-11-13 "$long" >/dev/null
  run field 'stopper-2026-11-13' "sorted(r)"
  [ "$output" = "['attempt', 'claim', 'finished', 'key', 'on_failure', 'report', 'routine', 'started', 'status', 'steps', 'summary']" ]
  run field 'stopper-2026-11-13' "len(r['summary'])"
  [ "$output" = 200 ]
  run field 'stopper-2026-11-13' "'\n' in r['steps'][0]['note'] or len(r['steps'][0]['note'])"
  [ "$output" = 200 ]
}

@test "bad key and bad outcome are rejected" {
  run rr begin stopper --key ../../etc
  [ "$status" -ne 0 ]
  rr begin stopper --key 2026-11-13
  run rr step stopper 2026-11-13 1 great
  [ "$status" -ne 0 ]
  run rr step stopper 2026-11-13 9 ok
  [ "$status" -ne 0 ]
}

@test "last prints the newest record; none exits 3" {
  run rr last stopper
  [ "$status" -eq 3 ]
  rr begin stopper --key 2026-11-13
  run rr last stopper
  [ "$status" -eq 0 ]
  [[ "$output" == *'"routine": "stopper"'* ]]
}

@test "list shows every routine with enabled flag and last run" {
  run rr list
  [[ "$output" == *$'stopper\ttrue\t'* ]]
  [[ "$output" == *$'standup\tfalse\t'* ]]
  rr disable keeper
  run rr list
  [[ "$output" == *$'keeper\tfalse\t'* ]]
}

@test "enable and disable write only the profile file" {
  before="$(cat "$REPO/dev/.routines.yml")"
  run rr disable stopper
  [ "$status" -eq 0 ]
  grep -q 'enabled: false' "$CCXP_ROUTINES_PROFILE_FILE"
  [ "$(cat "$REPO/dev/.routines.yml")" = "$before" ]
  run due list
  [[ "$output" != *stopper* ]]
  run rr enable stopper
  grep -q 'enabled: true' "$CCXP_ROUTINES_PROFILE_FILE"
}

@test "allowed: a repo-level allow is ignored, a profile allow is honored, send is never grantable" {
  run rr allowed keeper archive
  [ "$status" -ne 0 ]
  printf 'routines:\n  keeper:\n    allow: [archive, send]\n' >"$CCXP_ROUTINES_PROFILE_FILE"
  run rr allowed keeper archive
  [ "$status" -eq 0 ]
  run rr allowed keeper send
  [ "$status" -ne 0 ]
  run rr allowed keeper label
  [ "$status" -ne 0 ]
}

@test "every: routine has no retry cap and its attempt counter resets" {
  printf '  ticker:\n    schedule: {every: 5m}\n    steps: [{skill: "/todo"}]\n' >>"$REPO/dev/.routines.yml"
  for n in 1 2 3 4 5; do
    rr begin ticker --key every >/dev/null
    rr step ticker every 1 failed x >/dev/null
    run rr finish ticker every
    [ "$output" = "status=failed claim=release attempt=1" ]
  done
  run rr attempts ticker every
  [ "$status" -eq 0 ]
}

@test "finish with no step recorded is failed and releases the claim" {
  due claim >/dev/null
  rr begin stopper --key 2026-11-13
  run rr finish stopper 2026-11-13 "aborted"
  [ "$output" = "status=failed claim=release attempt=1" ]
}

@test "a key with a trailing newline is rejected; enable of an unknown routine fails; scalar allow grants nothing" {
  run rr begin stopper --key $'2026-11-13\n'
  [ "$status" -ne 0 ]
  run rr enable inbxo
  [ "$status" -ne 0 ]
  [ ! -e "$CCXP_ROUTINES_PROFILE_FILE" ] || ! grep -q inbxo "$CCXP_ROUTINES_PROFILE_FILE"
  printf 'routines:\n  keeper:\n    allow: archive\n' >"$CCXP_ROUTINES_PROFILE_FILE"
  run rr allowed keeper arch
  [ "$status" -ne 0 ]
}

@test "finish of a disabled routine still prints the status and exits 0" {
  rr begin stopper --key 2026-11-13
  rr step stopper 2026-11-13 1 ok
  rr disable stopper
  run bash "$RR" --repo "$REPO" finish stopper 2026-11-13 "late"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok claim=done"* ]]
}
