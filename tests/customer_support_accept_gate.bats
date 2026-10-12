#!/usr/bin/env bats
# Tests for customer-support/scripts/accept_gate.sh (T20261012-373882).
# Pure identity gate — accept is support-team-only, never self-applied by
# the delivering engineer.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/customer-support/scripts/accept_gate.sh"
}

@test "allows an actor on the allowlist" {
  run cs-accept-gate alice "alice,bob"
  [ "$status" -eq 0 ]
}

@test "allows an actor on the allowlist with spaces after commas" {
  run cs-accept-gate bob "alice, bob, carol"
  [ "$status" -eq 0 ]
}

@test "denies an actor not on the allowlist" {
  run cs-accept-gate mallory "alice,bob"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on the support-team allowlist"* ]]
}

@test "denies the delivering engineer when they are not on the allowlist" {
  # The exact scenario this gate exists for: the engineer who ran `deliver`
  # must not also be able to self-apply `accept`.
  run cs-accept-gate the-engineer "support-lead,support-oncall"
  [ "$status" -eq 1 ]
}

@test "fails CLOSED (denies) when the allowlist is unconfigured, never defaults to allow" {
  run cs-accept-gate alice ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"no support-team allowlist configured"* ]]
}

@test "fails on missing actor argument" {
  run cs-accept-gate "" "alice,bob"
  [ "$status" -eq 2 ]
}

@test "CLI entrypoint works directly" {
  run bash "$REPO_ROOT/customer-support/scripts/accept_gate.sh" alice "alice,bob"
  [ "$status" -eq 0 ]
}
