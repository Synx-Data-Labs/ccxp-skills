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
  [ "$output" = "$CS_L_IN_PROGRESS" ]
}

@test "delivered -> in-progress via start (revert path)" {
  run cs-sm-next "$CS_L_DELIVERED" start
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_IN_PROGRESS" ]
}

@test "start rejects triage or in-progress as current state" {
  run cs-sm-next "$CS_L_NEW" start
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_IN_PROGRESS" start
  [ "$status" -eq 1 ]
}

@test "in-progress -> delivered via deliver" {
  run cs-sm-next "$CS_L_IN_PROGRESS" deliver
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_DELIVERED" ]
}

@test "deliver rejects any state other than in-progress" {
  run cs-sm-next "$CS_L_TRIAGED" deliver
  [ "$status" -eq 1 ]
}

@test "request-confirm is a no-op from delivered" {
  run cs-sm-next "$CS_L_DELIVERED" request-confirm
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_DELIVERED" ]
}

@test "request-confirm rejects any state other than delivered" {
  run cs-sm-next "$CS_L_IN_PROGRESS" request-confirm
  [ "$status" -eq 1 ]
}

@test "delivered -> CLOSED:completed via accept" {
  run cs-sm-next "$CS_L_DELIVERED" accept
  [ "$status" -eq 0 ]
  [ "$output" = "CLOSED:completed" ]
}

@test "accept rejects any state other than delivered (never self-close mid-flight)" {
  run cs-sm-next "$CS_L_IN_PROGRESS" accept
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
    [ "$output" = "CLOSED:wontfix" ]
    run cs-sm-next "$s" reject duplicate
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSED:duplicate" ]
  done
}

@test "reject refuses invalid (dropped) and unknown reasons, and a terminal/none state" {
  run cs-sm-next "$CS_L_NEW" reject invalid
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_WONTFIX" reject
  [ "$status" -eq 1 ]
  run cs-sm-next none reject
  [ "$status" -eq 1 ]
}

@test "triage accepts a legacy issue with no status label (none treated as new)" {
  run cs-sm-next none triage
  [ "$status" -eq 0 ]
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-sm-next none start
  [ "$status" -eq 1 ]
}

@test "block / needs-upstream replace the current status from any working state" {
  for s in $CS_L_NEW $CS_L_TRIAGED $CS_L_IN_PROGRESS $CS_L_DELIVERED; do
    run cs-sm-next "$s" block
    [ "$output" = "$CS_L_BLOCKED" ]
    run cs-sm-next "$s" needs-upstream
    [ "$output" = "$CS_L_NEEDS_UPSTREAM" ]
  done
  run cs-sm-next "$CS_L_BLOCKED" block
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_WONTFIX" block
  [ "$status" -eq 1 ]
  run cs-sm-next none block
  [ "$status" -eq 1 ]
}

@test "unblock / needs-upstream-off restore the previous status, fallback triaged" {
  run cs-sm-next "$CS_L_BLOCKED" unblock "$CS_L_IN_PROGRESS"
  [ "$output" = "$CS_L_IN_PROGRESS" ]
  run cs-sm-next "$CS_L_BLOCKED" unblock in-progress
  [ "$output" = "$CS_L_IN_PROGRESS" ]
  run cs-sm-next "$CS_L_BLOCKED" unblock
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-sm-next "$CS_L_BLOCKED" unblock "$CS_L_WONTFIX"
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-sm-next "$CS_L_BLOCKED" unblock "$CS_L_BLOCKED"
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-sm-next "$CS_L_NEEDS_UPSTREAM" needs-upstream-off "$CS_L_DELIVERED"
  [ "$output" = "$CS_L_DELIVERED" ]
  run cs-sm-next "$CS_L_TRIAGED" unblock "$CS_L_NEW"
  [ "$status" -eq 1 ]
  run cs-sm-next "$CS_L_BLOCKED" needs-upstream-off
  [ "$status" -eq 1 ]
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

@test "cs-sm-is-preclose accepts the working states, rejects terminal/none/closed" {
  run cs-sm-is-preclose "$CS_L_NEW"
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose delivered
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose "$CS_L_BLOCKED"
  [ "$status" -eq 0 ]
  run cs-sm-is-preclose "$CS_L_DUPLICATE"
  [ "$status" -eq 1 ]
  run cs-sm-is-preclose none
  [ "$status" -eq 1 ]
  run cs-sm-is-preclose "CLOSED:completed"
  [ "$status" -eq 1 ]
}

@test "CLI entrypoint works directly" {
  run bash "$REPO_ROOT/customer-support/scripts/state_machine.sh" "$CS_L_NEW" triage
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
  [ "$output" = "CLOSED:wontfix" ]
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
  [ "$output" = "$CS_L_NEW" ]
  run cs-label-canon accepted
  [ "$output" = "$CS_L_TRIAGED" ]
  run cs-label-canon in-progress
  [ "$output" = "$CS_L_IN_PROGRESS" ]
  run cs-label-canon "$CS_L_IN_PROGRESS"
  [ "$output" = "$CS_L_IN_PROGRESS" ]
  run cs-label-canon invalid
  [ "$output" = "$CS_L_WONTFIX" ]
  run cs-label-canon sev3
  [ "$output" = "$CS_L_SEVERITY_3" ]
  run cs-label-canon kb-candidate
  [ "$output" = "$CS_L_KB_CANDIDATE" ]
  run cs-label-canon bug
  [ "$output" = "$CS_L_TYPE_BUG" ]
  run cs-label-canon area:storage
  [ "$output" = "area:storage" ]
}

@test "label_names: the v2 scheme values" {
  [ "$CS_L_NEW" = "status:new" ]
  [ "$CS_L_NEEDS_UPSTREAM" = "status:needs-upstream" ]
  [ "$CS_L_KB_PUBLISHED" = "kb:published" ]
  [ "$CS_L_SEVERITY_1" = "severity:1" ]
  [ "$CS_L_TYPE_QUESTION" = "type:question" ]
}

@test "label_names: cs-label-names lists the current name plus every alias" {
  run cs-label-names "$CS_L_NEW"
  [[ "$output" == *"status:new"* && "$output" == *"triage"* ]]
  run cs-label-names "$CS_L_WONTFIX"
  [[ "$output" == *"wontfix"* && "$output" == *"invalid"* ]]
}
