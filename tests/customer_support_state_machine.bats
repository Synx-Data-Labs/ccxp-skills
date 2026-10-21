#!/usr/bin/env bats
# Tests for customer-support/scripts/state_machine.sh (T20261012-373882).
# Pure logic — every row of the Transition rules table.

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/state_machine.sh"
}

@test "new -> triaged via triage" {
  run cs-sm-next "$CS_L_NEW" triage
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_TRIAGED" ]
}

@test "triage subcommand rejects a non-triage current state" {
  run cs-sm-next "$CS_L_TRIAGED" triage
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "accepted -> in-progress via start" {
  run cs-sm-next "$CS_L_TRIAGED" start
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "delivered -> in-progress via start (revert path)" {
  run cs-sm-next delivered start
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "start rejects triage or in-progress as current state" {
  run cs-sm-next "$CS_L_NEW" start
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
  run cs-sm-next "$CS_L_TRIAGED" deliver
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
  run cs-sm-next "$CS_L_TRIAGED" accept
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_NEW" accept
  [ "$status" -eq 1 ]
}

@test "reject allowed from every pre-close state" {
  for s in $CS_PRIMARY_LABELS; do
    run cs-sm-next "$s" reject
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSED:rejected" ]
  done
}

@test "unknown subcommand exits 2" {
  run cs-sm-next "$CS_L_NEW" frobnicate
  [ "$status" -eq 2 ]
}

@test "missing arguments exit 2" {
  run cs-sm-next triage
  [ "$status" -eq 2 ]
  run cs-sm-next
  [ "$status" -eq 2 ]
}

@test "cs-sm-is-preclose accepts the four primary states, rejects others" {
  run cs-sm-is-preclose "$CS_L_NEW"
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose delivered
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose none
  [ "$status" -eq 1 ]
  run cs-sm-is-preclose "CLOSED:completed"
  [ "$status" -eq 1 ]
}

@test "CLI entrypoint works directly" {
  run bash "$REPO_ROOT/customer-support/scripts/state_machine.sh" new triage
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_TRIAGED" ]
}

@test "retired names are aliases: triage -> new, accepted -> triaged (T20261021-266225)" {
  run cs-sm-next triage triage
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-sm-next accepted start
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_IN_PROGRESS" ]
  run cs-sm-is-preclose accepted
  [ "$status" -eq 0 ]
  run cs-sm-next accepted reject
  [ "$output" = "CLOSED:rejected" ]
}

@test "autoclose: only from delivered, yields CLOSED:timeout (distinct from accept)" {
  run cs-sm-next "$CS_L_DELIVERED" autoclose
  [ "$status" -eq 0 ]
  [ "$output" = "CLOSED:timeout" ]
  run cs-sm-next "$CS_L_IN_PROGRESS" autoclose
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_NEW" autoclose
  [ "$status" -eq 1 ]
}

@test "label_names: canon maps retired names and leaves current ones alone" {
  run cs-label-canon triage
  [ "$output" = "new" ]
  run cs-label-canon accepted
  [ "$output" = "triaged" ]
  run cs-label-canon in-progress
  [ "$output" = "in-progress" ]
}
