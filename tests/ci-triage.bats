#!/usr/bin/env bats
# Tests for _gh/ci-triage.sh — compact CI-failure summary (T20260719-204917).
#
# Pure logic (run-id parsing, window extraction, job rendering) is exercised
# by sourcing the script directly (CLI dispatch is BASH_SOURCE-guarded). The
# `gh` I/O is injected via the CI_TRIAGE_GH seam (mirrors _taskid/url.sh's
# TASKID_GH) — a stub script that branches on its argv to simulate
# `run view --json jobs` vs `run view --log-failed`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_gh/ci-triage.sh"
  cd "$BATS_TEST_TMPDIR"
}

# --- run-id parsing (pure) -----------------------------------------------------

@test "ci_triage_parse_run_id accepts a bare numeric id" {
  run ci_triage_parse_run_id "29670112823"
  [ "$status" -eq 0 ]
  [ "$output" = "29670112823" ]
}

@test "ci_triage_parse_run_id extracts the id from a full run URL" {
  run ci_triage_parse_run_id "https://github.com/your-org/build-pipeline-repo/actions/runs/29670112823"
  [ "$status" -eq 0 ]
  [ "$output" = "29670112823" ]
}

@test "ci_triage_parse_run_id extracts the id from a run URL with a job suffix" {
  run ci_triage_parse_run_id "https://github.com/o/r/actions/runs/123456/job/789"
  [ "$status" -eq 0 ]
  [ "$output" = "123456" ]
}

@test "ci_triage_parse_run_id fails on unparseable input" {
  run ci_triage_parse_run_id "not-a-run"
  [ "$status" -ne 0 ]
}

# --- window extraction (pure) ---------------------------------------------------

@test "ci_triage_extract_windows finds a single ##[error] line with context" {
  log=$'line1\nline2\nline3\n##[error]Process completed with exit code 1.\nline5\nline6'
  run ci_triage_extract_windows "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"##[error]Process completed with exit code 1."* ]]
  [[ "$output" == *"line2"* ]]
  [[ "$output" == *"line5"* ]]
}

@test "ci_triage_extract_windows merges overlapping windows from nearby matches" {
  log=$'a\nb\nError: first failure\nc\nd\nFAILED second\ne\nf'
  run ci_triage_extract_windows "$log" 3
  [ "$status" -eq 0 ]
  # both matches present in one merged block — no `--` group separator needed
  [[ "$output" == *"Error: first failure"* ]]
  [[ "$output" == *"FAILED second"* ]]
}

@test "ci_triage_extract_windows separates disjoint matches with the grep -- marker" {
  log=$'Error: one\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\nfatal: two'
  run ci_triage_extract_windows "$log" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--"* ]]
  [[ "$output" == *"Error: one"* ]]
  [[ "$output" == *"fatal: two"* ]]
}

@test "ci_triage_extract_windows returns empty for a clean log with no error patterns" {
  log=$'all good\nbuild succeeded\nno issues here'
  run ci_triage_extract_windows "$log" 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci_triage_extract_windows matches 'not ok' (BATS/TAP failure convention)" {
  log=$'1..2\nok 1 first test\nnot ok 2 second test\n# some diagnostic'
  run ci_triage_extract_windows "$log" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not ok 2 second test"* ]]
}

# --- job rendering (pure-ish; python3 formatting) --------------------------------

@test "ci_triage_render_jobs lists failed jobs and their failed steps" {
  json='[{"name":"BATS Tests","steps":["Run bats","Upload results"]}]'
  run ci_triage_render_jobs "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS Tests: Run bats, Upload results"* ]]
}

@test "ci_triage_render_jobs reports none-found for an empty array" {
  run ci_triage_render_jobs "[]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"none found"* ]]
}

@test "ci_triage_render_jobs degrades gracefully on unparseable JSON" {
  run ci_triage_render_jobs "not json at all"
  [ "$status" -eq 0 ]
}

# --- end-to-end main (gh stubbed via CI_TRIAGE_GH) -------------------------------

_stub_gh() {
  # $1 jobs-json  $2 log-text → writes a gh stub that branches on argv.
  cat > gh-stub.sh <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"--json jobs"* ]]; then
  cat <<'JOBS'
$1
JOBS
elif [[ "\$*" == *"--log-failed"* ]]; then
  cat <<'LOG'
$2
LOG
fi
STUB
  chmod +x gh-stub.sh
  export CI_TRIAGE_GH="$BATS_TEST_TMPDIR/gh-stub.sh"
}

@test "ci_triage_main reports the failed job and a bounded error window" {
  _stub_gh \
    '[{"name":"BATS Tests","steps":["Run bats"]}]' \
    $'setup\nrunning...\n##[error]Process completed with exit code 1.\ncleanup'
  run ci_triage_main 12345
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI triage: run 12345"* ]]
  [[ "$output" == *"BATS Tests: Run bats"* ]]
  [[ "$output" == *"##[error]Process completed with exit code 1."* ]]
}

@test "ci_triage_main accepts a full run URL" {
  _stub_gh '[]' $'nothing wrong here'
  run ci_triage_main "https://github.com/o/r/actions/runs/999"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI triage: run 999"* ]]
}

@test "ci_triage_main respects --context to widen the window" {
  _stub_gh '[]' $'1\n2\n3\n4\n5\nError: boom\n7\n8\n9\n10\n11'
  run ci_triage_main 12345 --context 4
  [ "$status" -eq 0 ]
  [[ "$output" == *"+/-4 lines"* ]]
  # match is line 6; +/-4 context spans lines 2-10 (grep -n -C prefixes each
  # line with its number), so line 1 and line 11 fall outside the window.
  [[ "$output" == *$'\n2-2'* ]]
  [[ "$output" == *$'\n10-10'* ]]
  [[ "$output" != *$'\n1-1'* ]]
  [[ "$output" != *$'\n11-11'* ]]
}

@test "ci_triage_main reports no-log-available when the log is empty" {
  _stub_gh '[]' ''
  run ci_triage_main 12345
  [ "$status" -eq 0 ]
  [[ "$output" == *"no failed-step log available"* ]]
}

@test "ci_triage_main errors cleanly on an unparseable run reference" {
  run ci_triage_main "not-a-run-id"
  [ "$status" -ne 0 ]
}
