#!/usr/bin/env bats
# Tests for customer-support/scripts/transition.sh (T20261012-373882,
# added per independent review of ccxp-skills#346 — the single enforced
# entrypoint that makes the evidence/identity gates structurally
# unbypassable, applies the specific reject-reason label before closing,
# and clears blocked/needs-upstream on close).

load test_helper
setup() {
  SCRIPT="$REPO_ROOT/customer-support/scripts/transition.sh"
  cd "$BATS_TEST_TMPDIR"
}

_stub_gh() {
  # $1 = JSON for an `issue view ... --json labels` call.
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
}

_stub_curl() {
  cat > curl-stub.sh <<STUB
#!/usr/bin/env bash
echo -n "$1"
STUB
  chmod +x curl-stub.sh
}

@test "triage: accepted label applied via the single entrypoint" {
  _stub_gh '{"labels":[{"name":"triage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" triage acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label triage"* ]]
  [[ "$output" == *"--add-label accepted"* ]]
}

@test "triage --task: posts a tracking-link comment before the label moves (T20261019-181127)" {
  _stub_gh '{"labels":[{"name":"triage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"comment 5 --repo acme/synxdb-support --body Tracked internally as synxdb-build-pipeline#T20261016-412473"* ]]
  [[ "$output" == *"--add-label accepted"* ]]
  comment_line=$(grep -n -- "comment 5" gh-calls.log | head -1 | cut -d: -f1)
  label_line=$(grep -n -- "--add-label accepted" gh-calls.log | head -1 | cut -d: -f1)
  [ "$comment_line" -lt "$label_line" ]
}

@test "deliver --urls: a verified URL moves the label" {
  _stub_gh '{"labels":[{"name":"in-progress"}]}'
  _stub_curl 200
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" CS_CURL="$BATS_TEST_TMPDIR/curl-stub.sh" \
    bash "$SCRIPT" deliver acme/synxdb-support 5 --urls "https://example.test/pkg.rpm"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label delivered"* ]]
}

@test "deliver --urls: a NON-verifying URL blocks the transition — labels.sh is never called" {
  _stub_gh '{"labels":[{"name":"in-progress"}]}'
  _stub_curl 404
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" CS_CURL="$BATS_TEST_TMPDIR/curl-stub.sh" \
    bash "$SCRIPT" deliver acme/synxdb-support 5 --urls "https://example.test/never-published.rpm"
  [ "$status" -eq 1 ]
  # The gate fired before any label-changing gh call — only the read-only
  # `issue view` (from cs-labels-primary) should appear in the call log,
  # never a --remove-label/--add-label.
  run cat gh-calls.log
  [[ "$output" != *"--add-label"* ]]
  [[ "$output" != *"--remove-label"* ]]
}

@test "accept: an actor not on the allowlist is refused — labels.sh is never called" {
  _stub_gh '{"labels":[{"name":"delivered"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" accept acme/synxdb-support 5 --actor the-engineer --allowed support-lead,support-oncall
  [ "$status" -eq 1 ]
  run cat gh-calls.log
  [[ "$output" != *"close"* ]]
}

@test "accept: an allowlisted actor closes with reason completed and clears modifiers" {
  _stub_gh '{"labels":[{"name":"delivered"},{"name":"blocked"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" accept acme/synxdb-support 5 --actor support-lead --allowed support-lead,support-oncall
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason completed"* ]]
  [[ "$output" == *"--remove-label blocked"* ]]
}

@test "reject: applies the specific reason label BEFORE closing (the gap found in review)" {
  _stub_gh '{"labels":[{"name":"triage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" reject acme/synxdb-support 5 --reason duplicate
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label duplicate"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason not planned"* ]]
  # the add-label call must precede the close call in the log
  add_line=$(grep -n -- "--add-label duplicate" gh-calls.log | head -1 | cut -d: -f1)
  close_line=$(grep -n -- "close 5" gh-calls.log | head -1 | cut -d: -f1)
  [ "$add_line" -lt "$close_line" ]
}

@test "reject: rejects an invalid --reason value before touching gh at all" {
  run bash "$SCRIPT" reject acme/synxdb-support 5 --reason wontfix-typo
  [ "$status" -eq 2 ]
  [ ! -f gh-calls.log ]
}

@test "block / unblock toggle the modifier label" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" block acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" unblock acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label blocked"* ]]
  [[ "$output" == *"--remove-label blocked"* ]]
}

@test "needs-upstream toggles on/off" {
  _stub_gh '{}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" needs-upstream acme/synxdb-support 5 on
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label needs-upstream"* ]]
}

@test "unknown subcommand exits 2" {
  run bash "$SCRIPT" frobnicate acme/synxdb-support 5
  [ "$status" -eq 2 ]
}
