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

@test "triage: triaged label applied via the single entrypoint" {
  _stub_gh '{"labels":[{"name":"status:new"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" triage acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:new"* ]]
  [[ "$output" == *"--add-label status:triaged"* ]]
}

# Task-aware gh fake for `triage --task` (T20261021-289402): serves the issue's
# labels, a fixture-backed `gh api` for task_url.sh, and records every call.
_stub_gh_task() {
  mkdir -p fx
  cat > gh-task-stub.sh <<'STUB'
#!/usr/bin/env bash
echo "$#" >> argc.log
echo "$*" >> gh-calls.log
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  echo '{"labels":[{"name":"status:new"}]}'
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  printf '%s\n----\n' "${@: -1}" >> body.log
  exit 0
fi
if [[ "$1" == "api" ]]; then
  shift
  while [[ "${1:-}" == "-H" ]]; do shift 2; done
  f="fx/$(printf '%s' "$1" | sed 's#[/?&=]#_#g')"
  if [[ -f "$f" ]]; then cat "$f"; else exit 1; fi
fi
STUB
  chmod +x gh-task-stub.sh
}

_fx() { printf '%s' "$2" > "fx/$(printf '%s' "$1" | sed 's#[/?&=]#_#g')"; }

_fx_task_on_main() {
  # $1 = title (may contain shell metacharacters)
  _fx "repos/acme/synxdb-build-pipeline" '{"default_branch":"main"}'
  _fx "repos/acme/synxdb-build-pipeline/commits/main" '{"sha":"abc123"}'
  _fx "repos/acme/synxdb-build-pipeline/contents/dev/TODO?ref=abc123" '[{"name":"T20261016-412473-x.md","path":"dev/TODO/T20261016-412473-x.md"}]'
  _fx "repos/acme/synxdb-build-pipeline/contents/dev/TODO/T20261016-412473-x.md?ref=abc123" "# T20261016-412473: $1
"
}

@test "triage --task: comment is one argv element and carries the readable text, a markdown link and the bare URL (T20261021-289402)" {
  _stub_gh_task
  _fx_task_on_main 'Fix `id` && echo pwned; $(x) thing'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -eq 0 ]
  # issue comment 5 --repo acme/synxdb-support --body <one-element> = 7 argv.
  [ "$(grep -c '^issue comment ' gh-calls.log)" -eq 1 ]
  # the comment call's argc is the line right after its own gh-calls.log entry's
  # position: argc.log and gh-calls.log are appended together per call.
  n=$(grep -n '^issue comment ' gh-calls.log | cut -d: -f1)
  [ "$(sed -n "${n}p" argc.log)" -eq 7 ]
  url="https://github.com/acme/synxdb-build-pipeline/blob/abc123/dev/TODO/T20261016-412473-x.md"
  run cat body.log
  want="Tracked internally as [synxdb-build-pipeline#T20261016-412473](${url}) — "
  want+='Fix `id` && echo pwned; $(x) thing'
  [[ "$output" == "$want"* ]]
  [[ "$output" == *$'\n\n'"${url}"$'\n'* ]]
}

@test "triage --task: posts the URL comment before the label moves" {
  _stub_gh_task
  _fx_task_on_main 'Some task'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -eq 0 ]
  grep -q -- "--add-label status:triaged" gh-calls.log
  comment_line=$(grep -n -- "issue comment 5" gh-calls.log | head -1 | cut -d: -f1)
  label_line=$(grep -n -- "--add-label status:triaged" gh-calls.log | head -1 | cut -d: -f1)
  [ "$comment_line" -lt "$label_line" ]
}

@test "triage --task: task only on an open PR says so and links the PR" {
  _stub_gh_task
  _fx "repos/acme/synxdb-build-pipeline" '{"default_branch":"main"}'
  _fx "repos/acme/synxdb-build-pipeline/commits/main" '{"sha":"abc123"}'
  _fx "repos/acme/synxdb-build-pipeline/contents/dev/TODO?ref=abc123" '[]'
  _fx "repos/acme/synxdb-build-pipeline/pulls?state=open&per_page=100" '[{"number":9,"title":"stage T20261016-412473","body":"","head":{"ref":"b","sha":"feed99","repo":{"full_name":"acme/synxdb-build-pipeline"}},"html_url":"https://github.com/acme/synxdb-build-pipeline/pull/9"}]'
  _fx "repos/acme/synxdb-build-pipeline/pulls/9/files?per_page=100" '[{"filename":"dev/TODO/T20261016-412473-x.md"}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -eq 0 ]
  run cat body.log
  [[ "$output" == *"blob/feed99/dev/TODO/T20261016-412473-x.md"* ]]
  [[ "$output" == *"not on the default branch yet; its filing PR is still open: https://github.com/acme/synxdb-build-pipeline/pull/9"* ]]
}

@test "triage --task: unresolvable task fails loudly, posts NO comment and moves NO label" {
  _stub_gh_task
  _fx "repos/acme/synxdb-build-pipeline" '{"default_branch":"main"}'
  _fx "repos/acme/synxdb-build-pipeline/commits/main" '{"sha":"abc123"}'
  _fx "repos/acme/synxdb-build-pipeline/contents/dev/TODO?ref=abc123" '[]'
  _fx "repos/acme/synxdb-build-pipeline/contents/dev/JOURNAL?ref=abc123" '[]'
  _fx "repos/acme/synxdb-build-pipeline/pulls?state=open&per_page=100" '[]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in acme/synxdb-build-pipeline"* ]]
  if grep -q -- "issue comment" gh-calls.log; then false; fi
  if grep -q -- "--add-label" gh-calls.log; then false; fi
}

@test "triage --task: unreadable (private, no access) repo fails before anything is written" {
  _stub_gh_task
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task "synxdb-build-pipeline#T20261016-412473"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read acme/synxdb-build-pipeline"* ]]
  if grep -q -- "issue comment" gh-calls.log; then false; fi
  if grep -q -- "--add-label" gh-calls.log; then false; fi
}

@test "triage --task: a malformed ref is rejected (no comment, no label)" {
  _stub_gh_task
  run env CS_GH="$BATS_TEST_TMPDIR/gh-task-stub.sh" \
    bash "$SCRIPT" triage acme/synxdb-support 5 --task 'synxdb-build-pipeline#T1 2 3 && echo pwned; `id`'
  [ "$status" -ne 0 ]
  if grep -q -- "issue comment" gh-calls.log; then false; fi
  if grep -q -- "--add-label" gh-calls.log; then false; fi
}

@test "deliver --urls: a verified URL moves the label" {
  _stub_gh '{"labels":[{"name":"status:in-progress"}]}'
  _stub_curl 200
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" CS_CURL="$BATS_TEST_TMPDIR/curl-stub.sh" \
    bash "$SCRIPT" deliver acme/synxdb-support 5 --urls "https://example.test/pkg.rpm"
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label status:delivered"* ]]
}

@test "deliver --urls: a NON-verifying URL blocks the transition — labels.sh is never called" {
  _stub_gh '{"labels":[{"name":"status:in-progress"}]}'
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
  _stub_gh '{"labels":[{"name":"status:delivered"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" accept acme/synxdb-support 5 --actor the-engineer --allowed support-lead,support-oncall
  [ "$status" -eq 1 ]
  run cat gh-calls.log
  [[ "$output" != *"close"* ]]
}

@test "accept: an allowlisted actor closes with reason completed and keeps status:delivered" {
  _stub_gh '{"labels":[{"name":"status:delivered"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" accept acme/synxdb-support 5 --actor support-lead --allowed support-lead,support-oncall
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason completed"* ]]
  [[ "$output" != *"--remove-label"* ]]
}

@test "reject --reason duplicate: swaps in status:duplicate BEFORE closing, GitHub reason duplicate" {
  _stub_gh '{"labels":[{"name":"status:new"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" reject acme/synxdb-support 5 --reason duplicate
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:new"* ]]
  [[ "$output" == *"--add-label status:duplicate"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason duplicate"* ]]
  add_line=$(grep -n -- "--add-label status:duplicate" gh-calls.log | head -1 | cut -d: -f1)
  close_line=$(grep -n -- "close 5" gh-calls.log | head -1 | cut -d: -f1)
  [ "$add_line" -lt "$close_line" ]
}

@test "reject --reason wontfix: status:wontfix, closed as 'not planned'" {
  _stub_gh '{"labels":[{"name":"status:in-progress"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" \
    bash "$SCRIPT" reject acme/synxdb-support 5 --reason wontfix
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:in-progress"* ]]
  [[ "$output" == *"--add-label status:wontfix"* ]]
  [[ "$output" == *"close 5 --repo acme/synxdb-support --reason not planned"* ]]
}

@test "reject --reason invalid is no longer accepted (dropped) and never touches gh" {
  run bash "$SCRIPT" reject acme/synxdb-support 5 --reason invalid
  [ "$status" -eq 2 ]
  [ ! -f gh-calls.log ]
}

@test "reject: rejects an invalid --reason value before touching gh at all" {
  run bash "$SCRIPT" reject acme/synxdb-support 5 --reason wontfix-typo
  [ "$status" -eq 2 ]
  [ ! -f gh-calls.log ]
}

# _stub_gh_tl <issue-view-json> <timeline-json> — gh stub that also serves the
# timeline API (used to restore the previous status on unblock).
_stub_gh_tl() {
  printf '%s' "$2" > tl.json
  cat > gh-stub.sh <<STUB
#!/usr/bin/env bash
echo "\$*" >> gh-calls.log
if [[ "\$1" == "api" ]]; then
  cat tl.json
elif [[ "\$*" == *"--json labels"* ]]; then
  cat <<'LABELS'
$1
LABELS
fi
STUB
  chmod +x gh-stub.sh
}

@test "block: REPLACES the current status with status:blocked (no stacking)" {
  _stub_gh '{"labels":[{"name":"status:in-progress"},{"name":"area:storage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" block acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:in-progress"* ]]
  [[ "$output" == *"--add-label status:blocked"* ]]
}

@test "block: refused when already blocked or when the issue is closed-terminal" {
  _stub_gh '{"labels":[{"name":"status:blocked"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" block acme/synxdb-support 5
  [ "$status" -eq 1 ]
  _stub_gh '{"labels":[{"name":"status:wontfix"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" block acme/synxdb-support 5
  [ "$status" -eq 1 ]
}

@test "unblock: restores the previous status read from the label timeline" {
  _stub_gh_tl '{"labels":[{"name":"status:blocked"}]}' '[
    {"event":"labeled","label":{"name":"status:triaged"}},
    {"event":"unlabeled","label":{"name":"status:triaged"}},
    {"event":"labeled","label":{"name":"status:in-progress"}},
    {"event":"unlabeled","label":{"name":"status:in-progress"}},
    {"event":"labeled","label":{"name":"area:storage"}},
    {"event":"labeled","label":{"name":"status:blocked"}}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" unblock acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:blocked"* ]]
  [[ "$output" == *"--add-label status:in-progress"* ]]
}

@test "unblock: uses the LAST block cycle, and reads pre-rename names (in-progress / blocked)" {
  _stub_gh_tl '{"labels":[{"name":"blocked"}]}' '[
    {"event":"unlabeled","label":{"name":"triaged"}},
    {"event":"labeled","label":{"name":"blocked"}},
    {"event":"unlabeled","label":{"name":"blocked"}},
    {"event":"labeled","label":{"name":"delivered"}},
    {"event":"unlabeled","label":{"name":"delivered"}},
    {"event":"labeled","label":{"name":"blocked"}}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" unblock acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label blocked"* ]]
  [[ "$output" == *"--add-label status:delivered"* ]]
}

@test "unblock: falls back to status:triaged when the timeline has no previous status" {
  _stub_gh_tl '{"labels":[{"name":"status:blocked"}]}' '[{"event":"labeled","label":{"name":"status:blocked"}}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" unblock acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label status:triaged"* ]]
}

@test "unblock: refused unless the issue is status:blocked" {
  _stub_gh_tl '{"labels":[{"name":"status:triaged"}]}' '[]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" unblock acme/synxdb-support 5
  [ "$status" -eq 1 ]
  run cat gh-calls.log
  [[ "$output" != *"--add-label"* ]]
}

@test "needs-upstream on replaces the status; off restores the previous one" {
  _stub_gh '{"labels":[{"name":"status:triaged"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" needs-upstream acme/synxdb-support 5 on
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:triaged"* ]]
  [[ "$output" == *"--add-label status:needs-upstream"* ]]
  rm -f gh-calls.log
  _stub_gh_tl '{"labels":[{"name":"status:needs-upstream"}]}' '[
    {"event":"unlabeled","label":{"name":"status:in-progress"}},
    {"event":"labeled","label":{"name":"status:needs-upstream"}}]'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" needs-upstream acme/synxdb-support 5 off
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label status:needs-upstream"* ]]
  [[ "$output" == *"--add-label status:in-progress"* ]]
}

@test "needs-upstream: bad mode exits 2" {
  _stub_gh '{"labels":[{"name":"status:triaged"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" needs-upstream acme/synxdb-support 5 maybe
  [ "$status" -eq 2 ]
}

@test "unknown subcommand exits 2" {
  run bash "$SCRIPT" frobnicate acme/synxdb-support 5
  [ "$status" -eq 2 ]
}

@test "triage on a stale issue still labelled 'triage' works and removes that real label (T20261021-266225)" {
  _stub_gh '{"labels":[{"name":"triage"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" triage acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label triage"* ]]
  [[ "$output" == *"--add-label status:triaged"* ]]
}

@test "triage on a legacy issue with NO status label works (none treated as new): adds status:triaged, removes nothing" {
  _stub_gh '{"labels":[{"name":"family:synxdb"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" triage acme/synxdb-support 20
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--add-label status:triaged"* ]]
  [[ "$output" != *"--remove-label"* ]]
}

@test "triage on a pre-rename bare 'new' label removes that real label" {
  _stub_gh '{"labels":[{"name":"new"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" triage acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"--remove-label new"* ]]
  [[ "$output" == *"--add-label status:triaged"* ]]
}

@test "start on a legacy no-status issue is refused (only triage accepts none)" {
  _stub_gh '{"labels":[]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" start acme/synxdb-support 20
  [ "$status" -eq 1 ]
}

@test "request-confirm is a true no-op on labels (no remove/re-add that would restart the sweep clock)" {
  _stub_gh '{"labels":[{"name":"status:delivered"}]}'
  run env CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" request-confirm acme/synxdb-support 5
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" != *"--remove-label"* ]]
  [[ "$output" != *"--add-label"* ]]
}
