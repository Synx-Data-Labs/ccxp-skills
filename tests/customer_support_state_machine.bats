#!/usr/bin/env bats
# Tests for customer-support/scripts/state_machine.sh (T20261012-373882).
# Pure logic — every row of the Transition rules table.

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/state_machine.sh"
}

@test "triage -> accepted" {
  run cs-sm-next triage triage
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

@test "triage subcommand rejects a non-triage current state" {
  run cs-sm-next accepted triage
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "accepted -> in-progress via start" {
  run cs-sm-next accepted start
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "delivered -> in-progress via start (revert path)" {
  run cs-sm-next delivered start
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "start rejects triage or in-progress as current state" {
  run cs-sm-next triage start
  [ "$status" -eq 1 ]
  run cs-sm-next in-progress start
  [ "$status" -eq 1 ]
}

@test "in-progress -> delivered via deliver" {
  run cs-sm-next in-progress deliver
  [ "$status" -eq 0 ]
  [ "$output" = "delivered" ]
}

@test "deliver rejects any state other than in-progress" {
  run cs-sm-next accepted deliver
  [ "$status" -eq 1 ]
}

@test "request-confirm is a no-op from delivered" {
  run cs-sm-next delivered request-confirm
  [ "$status" -eq 0 ]
  [ "$output" = "delivered" ]
}

@test "request-confirm rejects any state other than delivered" {
  run cs-sm-next in-progress request-confirm
  [ "$status" -eq 1 ]
}

@test "delivered -> CLOSED:completed via accept" {
  run cs-sm-next delivered accept
  [ "$status" -eq 0 ]
  [ "$output" = "CLOSED:completed" ]
}

@test "accept rejects any state other than delivered (never self-close mid-flight)" {
  run cs-sm-next in-progress accept
  [ "$status" -eq 1 ]
  run cs-sm-next accepted accept
  [ "$status" -eq 1 ]
  run cs-sm-next triage accept
  [ "$status" -eq 1 ]
}

@test "reject allowed from every pre-close state" {
  for s in triage accepted in-progress delivered; do
    run cs-sm-next "$s" reject
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSED:rejected" ]
  done
}

@test "unknown subcommand exits 2" {
  run cs-sm-next triage frobnicate
  [ "$status" -eq 2 ]
}

@test "missing arguments exit 2" {
  run cs-sm-next triage
  [ "$status" -eq 2 ]
  run cs-sm-next
  [ "$status" -eq 2 ]
}

@test "cs-sm-is-preclose accepts the four primary states, rejects others" {
  run cs-sm-is-preclose triage
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose delivered
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose none
  [ "$status" -eq 1 ]
  run cs-sm-is-preclose "CLOSED:completed"
  [ "$status" -eq 1 ]
}

@test "CLI entrypoint works directly" {
  run bash "$REPO_ROOT/customer-support/scripts/state_machine.sh" triage triage
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}
