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
  json='[{"number":1,"labels":[{"name":"triage"}]},{"number":2,"labels":[{"name":"accepted"},{"name":"sev2"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 0 ]
}

@test "flags an issue with zero primary labels (synxdb-support#20/#21/#23-shaped)" {
  json='[{"number":20,"labels":[]},{"number":21,"labels":[{"name":"family:synxdb"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#20: no primary-state label"* ]]
  [[ "$output" == *"#21: no primary-state label"* ]]
}

@test "flags an issue with more than one primary label" {
  json='[{"number":5,"labels":[{"name":"triage"},{"name":"accepted"}]}]'
  run cs-audit-check "$json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#5: multiple primary-state labels"* ]]
}

@test "ignores non-primary labels entirely" {
  json='[{"number":27,"labels":[{"name":"family:synxdb"},{"name":"triage"}]}]'
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
  _stub_gh_issue_list '[{"number":24,"labels":[{"name":"bug"}]}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash -c "source '$REPO_ROOT/customer-support/scripts/audit.sh'; cs-audit-main acme/synxdb-support"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#24: no primary-state label"* ]]
}

@test "CLI entrypoint works directly" {
  _stub_gh_issue_list '[{"number":1,"labels":[{"name":"triage"}]}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$REPO_ROOT/customer-support/scripts/audit.sh" acme/synxdb-support
  [ "$status" -eq 0 ]
}
