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
  _stub_gh '{"labels":[{"name":"status:triaged"},{"name":"severity:2"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 0 ]
  [ "$output" = "status:triaged" ]
}

@test "primary prints 'none' when no primary label is present" {
  _stub_gh '{"labels":[{"name":"severity:2"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "primary fails loudly on more than one primary label (invariant violation)" {
  _stub_gh '{"labels":[{"name":"status:triaged"},{"name":"status:in-progress"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one primary label"* ]]
  [[ "$output" == *"audit"* ]]
}

@test "apply removes the old primary and adds the new one" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 status:triaged status:in-progress"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:triaged"* ]]
  [[ "$output" == *"--add-label status:in-progress"* ]]
}

@test "apply from 'none' only adds, never removes" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 none status:new"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" != *"--remove-label"* ]]
  [[ "$output" == *"--add-label status:new"* ]]
}

@test "apply CLOSED:completed closes with reason completed and keeps status:delivered" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 status:delivered CLOSED:completed"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" != *"--remove-label"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason completed"* ]]
}

@test "apply CLOSED:wontfix swaps in status:wontfix then closes 'not planned'" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 status:new CLOSED:wontfix"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:new"* ]]
  [[ "$output" == *"--add-label status:wontfix"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason not planned"* ]]
  [ "$(grep -n -- "--add-label status:wontfix" gh-calls.log | cut -d: -f1)" -lt "$(grep -n -- "close 5" gh-calls.log | cut -d: -f1)" ]
}

@test "apply CLOSED:duplicate swaps in status:duplicate then closes with reason duplicate" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 status:triaged CLOSED:duplicate"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label status:duplicate"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason duplicate"* ]]
}

@test "toggle on adds, toggle off removes" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-toggle acme/synxdb-support 5 status:blocked on"
  [ "$status" -eq 0 ]
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-toggle acme/synxdb-support 5 status:blocked off"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label status:blocked"* ]]
  [[ "$output" == *"--remove-label status:blocked"* ]]
}

@test "toggle rejects a bad mode" {
  run cs-labels-toggle acme/synxdb-support 5 status:blocked sideways
  [ "$status" -eq 2 ]
}

@test "CLI entrypoint dispatches primary/apply/toggle" {
  _stub_gh '{"labels":[{"name":"status:new"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$REPO_ROOT/customer-support/scripts/labels.sh" primary acme/synxdb-support 5
  [ "$status" -eq 0 ]
  [ "$output" = "status:new" ]
}

@test "primary reports a retired label as-is so --remove-label hits the real one (T20261021-266225)" {
  _stub_gh '{"labels":[{"name":"accepted"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

@test "apply CLOSED:timeout closes as completed and does NOT remove the delivered label" {
  _stub_gh '{"labels":[]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-apply acme/synxdb-support 5 status:delivered CLOSED:timeout"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"issue close 5"*"--reason completed"* ]]
  [[ "$output" != *"--remove-label"* ]]
}

@test "primary reports a pre-rename bare label (e.g. in-progress) as-is" {
  _stub_gh '{"labels":[{"name":"in-progress"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/labels.sh'; cs-labels-primary acme/synxdb-support 5"
  [ "$output" = "in-progress" ]
}
