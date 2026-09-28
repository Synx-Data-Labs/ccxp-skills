#!/usr/bin/env bats
# Tests for _session/iteration.sh — current/next iteration date resolution.
# The GraphQL call (_session_gh) and project resolution are stubbed (no network);
# "today" is injected via SESSION_TODAY. What's exercised is the pure date-window
# selection logic that maps today -> current/next iteration startDate.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Dispatch block is guarded, so sourcing is side-effect-free.
  source "$REPO_ROOT/_session/iteration.sh"
  # Stub project resolution + GraphQL (canned 3-iteration config: It10/11/12).
  _session_resolve_project() { _SESSION_PROJECT_ID="PVT_test"; return 0; }
  _CANNED='{"data":{"node":{"field":{"configuration":{"iterations":[
    {"startDate":"2026-06-15","duration":7},
    {"startDate":"2026-06-22","duration":7},
    {"startDate":"2026-06-29","duration":7}]}}}}}'
  _session_gh() { printf '%s' "$_CANNED"; }
  export -f _session_resolve_project _session_gh 2>/dev/null || true
}

@test "current returns the iteration containing today" {
  SESSION_TODAY=2026-06-18 run session_iteration_date current
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-15" ]
}

@test "next returns the following iteration" {
  SESSION_TODAY=2026-06-18 run session_iteration_date next
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
}

@test "default arg is current" {
  SESSION_TODAY=2026-06-18 run session_iteration_date
  [ "$output" = "2026-06-15" ]
}

@test "boundary day belongs to the iteration it starts" {
  SESSION_TODAY=2026-06-22 run session_iteration_date current
  [ "$output" = "2026-06-22" ]
}

@test "today in a gap before all iterations -> next upcoming treated as current" {
  SESSION_TODAY=2026-06-01 run session_iteration_date current
  [ "$output" = "2026-06-15" ]
}

@test "next past the last defined iteration prints nothing (best-effort, exit 0)" {
  SESSION_TODAY=2026-06-29 run session_iteration_date next
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "null/empty Iteration config prints nothing, exits 0" {
  _session_gh() { printf '%s' '{"data":{"node":{"field":null}}}'; }
  export -f _session_gh 2>/dev/null || true
  SESSION_TODAY=2026-06-18 run session_iteration_date current
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
