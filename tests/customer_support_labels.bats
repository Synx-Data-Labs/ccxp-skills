#!/usr/bin/env bats
# Tests for customer-support/scripts/labels.sh (T20261012-373882).
# gh I/O injected via the CS_GH seam (mirrors _gh/ci-triage.sh's
# CI_TRIAGE_GH convention). Records every gh invocation to gh-calls.log so
# tests can assert the right command shape was issued.

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/labels.sh"
  cd "$BATS_TEST_TMPDIR"
}

_stub_gh() {
  # $1 = JSON to print for an `issue view ... --json labels` call.
  cat > gh-stub.sh <<STUB
#!/usr/bin/env bash
echo "\$*" >> gh-calls.log
if [[ "\$*" == *"--json labels"* ]]; then
  cat <<'LABELS'
$1
LABELS
fi
STUB
  chmod +x gh-stub.sh
  CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh"
}

@test "primary reads the single current primary label" {
  _stub_gh '{"labels":[{"name":"accepted"},{"name":"sev2"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

@test "primary prints 'none' when no primary label is present" {
  _stub_gh '{"labels":[{"name":"sev2"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "primary fails loudly on more than one primary label (invariant violation)" {
  _stub_gh '{"labels":[{"name":"accepted"},{"name":"in-progress"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one primary label"* ]]
  [[ "$output" == *"audit"* ]]
}

@test "apply removes the old primary and adds the new one" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 accepted in-progress"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label accepted"* ]]
  [[ "$output" == *"--add-label in-progress"* ]]
}

@test "apply from 'none' only adds, never removes" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 none triage"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" != *"--remove-label"* ]]
  [[ "$output" == *"--add-label triage"* ]]
}

@test "apply CLOSED:completed closes with reason completed, no add-label" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 delivered CLOSED:completed"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label delivered"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason completed"* ]]
}

@test "apply CLOSED:rejected closes with reason 'not planned'" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 triage CLOSED:rejected"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason not planned"* ]]
}

@test "toggle on adds, toggle off removes" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-toggle acme/synxdb-support 5 blocked on"
  [ "$status" -eq 0 ]
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-toggle acme/synxdb-support 5 blocked off"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label blocked"* ]]
  [[ "$output" == *"--remove-label blocked"* ]]
}

@test "toggle rejects a bad mode" {
  run cs-labels-toggle acme/synxdb-support 5 blocked sideways
  [ "$status" -eq 2 ]
}

@test "CLI entrypoint dispatches primary/apply/toggle" {
  _stub_gh '{"labels":[{"name":"triage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$REPO_ROOT/customer-support/scripts/labels.sh" primary acme/synxdb-support 5
  [ "$status" -eq 0 ]
  [ "$output" = "triage" ]
}
