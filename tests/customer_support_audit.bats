#!/usr/bin/env bats
# Tests for customer-support/scripts/audit.sh (T20261012-373882).
# Pure invariant check (cs-audit-check) plus the gh-stubbed end-to-end path
# (CS_GH seam, mirrors labels.sh/ci-triage.sh's convention).

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/audit.sh"
  cd "$BATS_TEST_TMPDIR"
}

@test "clean: every issue has exactly one primary label" {
  json='[{"number":1,"labels":[{"name":"status:new"}]},{"number":2,"labels":[{"name":"status:triaged"},{"name":"severity:2"}]},{"number":3,"labels":[{"name":"status:wontfix"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 0 ]
}

@test "flags an issue with zero primary labels (synxdb-support#20/#21/#23-shaped)" {
  json='[{"number":20,"labels":[]},{"number":21,"labels":[{"name":"family:synxdb"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#20: no status label"* ]]
  [[ "$output" == *"#21: no status label"* ]]
}

@test "flags an issue with more than one primary label" {
  json='[{"number":5,"labels":[{"name":"status:new"},{"name":"status:triaged"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#5: multiple status labels"* ]]
}

@test "ignores non-primary labels entirely" {
  json='[{"number":27,"labels":[{"name":"family:synxdb"},{"name":"status:new"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 0 ]
}

_stub_gh_issue_list() {
  cat > gh-stub.sh <<STUB
#!/usr/bin/env bash
echo '$1'
STUB
  chmod +x gh-stub.sh
  CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh"
}

@test "cs-audit-main fetches open issues via gh and runs the check" {
  _stub_gh_issue_list '[{"number":24,"labels":[{"name":"type:bug"}]}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/audit.sh'; cs-audit-main acme/synxdb-support"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#24: no status label"* ]]
}

@test "CLI entrypoint works directly" {
  _stub_gh_issue_list '[{"number":1,"labels":[{"name":"status:new"}]}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$REPO_ROOT/customer-support/scripts/audit.sh" acme/synxdb-support
  [ "$status" -eq 0 ]
}

@test "audit treats retired names (triage/accepted) as valid primaries (T20261021-266225)" {
  run bash -c "source '$REPO_ROOT/customer-support/scripts/audit.sh'; cs-audit-check '[{\"number\":1,\"labels\":[{\"name\":\"triage\"}]},{\"number\":2,\"labels\":[{\"name\":\"accepted\"}]}]'"
  [ "$status" -eq 0 ]
}

@test "audit flags an old+new duplicate (triage + status:new)" {
  run bash -c "source '$REPO_ROOT/customer-support/scripts/audit.sh'; cs-audit-check '[{\"number\":3,\"labels\":[{\"name\":\"triage\"},{\"name\":\"status:new\"}]}]'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple status labels"* ]]
}

@test "audit accepts the pre-rename bare names (new/triaged/in-progress/blocked/needs-upstream/delivered/wontfix/duplicate/invalid) as the one status" {
  run bash -c "source '$REPO_ROOT/customer-support/scripts/audit.sh'; cs-audit-check '[{\"number\":1,\"labels\":[{\"name\":\"blocked\"}]},{\"number\":2,\"labels\":[{\"name\":\"needs-upstream\"}]},{\"number\":3,\"labels\":[{\"name\":\"wontfix\"}]},{\"number\":4,\"labels\":[{\"name\":\"invalid\"}]},{\"number\":5,\"labels\":[{\"name\":\"duplicate\"}]}]'"
  [ "$status" -eq 0 ]
}

@test "audit: blocked is a status now — a stale stacked triaged+blocked is flagged (no longer a modifier)" {
  json='[{"number":6,"labels":[{"name":"status:triaged"},{"name":"status:blocked"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#6: multiple status labels"* ]]
}

@test "audit also covers closed issues (--state all)" {
  cat > gh-stub.sh <<'STUB'
#!/usr/bin/env bash
echo "$*" >> gh-calls.log
echo '[{"number":9,"labels":[{"name":"status:delivered"}]}]'
STUB
  chmod +x gh-stub.sh
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$REPO_ROOT/customer-support/scripts/audit.sh" acme/synxdb-support
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--state all"* ]]
}
