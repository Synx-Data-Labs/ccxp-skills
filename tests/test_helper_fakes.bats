#!/usr/bin/env bats
# Self-tests for the shared fakes in tests/test_helper.bash (fake_gh,
# fake_claude, pin_now, make_fixture_repo, assert_calls). These are the
# building blocks every script-backed-skill test relies on, so they get their
# own contract tests: a broken fake must fail here, not silently green a
# downstream test.

load test_helper

@test "make_fixture_repo: main branch, identity, queue.md, one commit" {
  d="$(make_fixture_repo "$BATS_TEST_TMPDIR/r")"
  [ "$d" = "$BATS_TEST_TMPDIR/r" ]
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = main ]
  [ "$(git -C "$d" rev-list --count HEAD)" = 1 ]
  [ -d "$d/dev/TODO" ] && [ -f "$d/dev/TODO/queue.md" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
}

@test "make_fixture_repo: appends queue lines given after --" {
  d="$(make_fixture_repo "$BATS_TEST_TMPDIR/r" -- '- [T20250101-000001](a.md): A' '- [T20250101-000002](b.md): B')"
  [ "$(grep -c '^- \[' "$d/dev/TODO/queue.md")" = 2 ]
}

@test "fake_gh: serves the fixture keyed by argv and logs the call" {
  mkdir "$BATS_TEST_TMPDIR/fx"
  echo '[{"number":7}]' > "$BATS_TEST_TMPDIR/fx/pr_list_state_open.json"
  fake_gh "$BATS_TEST_TMPDIR/fx"
  run gh pr list --state open
  [ "$status" -eq 0 ]
  [ "$output" = '[{"number":7}]' ]
  assert_calls "$FAKE_GH_LOG" '^pr list --state open$'
}

@test "fake_gh: an unmapped invocation fails loudly (97) and is logged" {
  mkdir "$BATS_TEST_TMPDIR/fx"
  fake_gh "$BATS_TEST_TMPDIR/fx"
  run gh issue list
  [ "$status" -eq 97 ]
  assert_calls "$FAKE_GH_LOG" '^UNMAPPED issue list'
  refute_calls "$FAKE_GH_LOG" '^issue list$'
}

@test "fake_gh: FAKE_GH_FAIL forces a non-zero exit for matching calls only" {
  mkdir "$BATS_TEST_TMPDIR/fx"
  echo ok > "$BATS_TEST_TMPDIR/fx/pr_view.txt"
  echo ok > "$BATS_TEST_TMPDIR/fx/pr_list.txt"
  fake_gh "$BATS_TEST_TMPDIR/fx"
  export FAKE_GH_FAIL='^pr view'
  run gh pr view
  [ "$status" -eq 1 ]
  assert_calls "$FAKE_GH_LOG" '^FAILED pr view$'
  refute_calls "$FAKE_GH_LOG" '^pr view$'
  run gh pr list
  [ "$status" -eq 0 ]
}

@test "fake_gh: longest fixture prefix wins and <key>.rc sets the exit code" {
  mkdir "$BATS_TEST_TMPDIR/fx"
  echo short > "$BATS_TEST_TMPDIR/fx/pr.txt"
  echo long > "$BATS_TEST_TMPDIR/fx/pr_view_12.txt"
  echo 3 > "$BATS_TEST_TMPDIR/fx/pr_view_12.rc"
  fake_gh "$BATS_TEST_TMPDIR/fx"
  run gh pr view 12 --json state
  [ "$status" -eq 3 ]
  [ "$output" = long ]
  run gh pr list
  [ "$output" = short ]
}

@test "refute_calls: passes with no log, fails on a match" {
  refute_calls "$BATS_TEST_TMPDIR/none.log" 'anything'
  echo 'pr merge 3' > "$BATS_TEST_TMPDIR/l.log"
  run refute_calls "$BATS_TEST_TMPDIR/l.log" 'pr merge'
  [ "$status" -ne 0 ]
}

@test "fake_claude: logs argv and stdin, prints the canned output, honors rc" {
  fake_claude "canned reply"
  export FAKE_CLAUDE_STDIN=1
  run bash -c 'echo prompt-body | claude -p --model x'
  [ "$status" -eq 0 ]
  [ "$output" = "canned reply" ]
  assert_calls "$FAKE_CLAUDE_LOG" '^-p --model x$'
  grep -q prompt-body "$FAKE_CLAUDE_LOG.stdin"
  FAKE_CLAUDE_STDIN=0 FAKE_CLAUDE_RC=4 run claude -p
  [ "$status" -eq 4 ]
}

@test "pin_now: date, date -u and date +FMT report the pinned instant" {
  pin_now 2026-10-30T12:34:56Z
  [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" = 2026-10-30T12:34:56Z ]
  [ "$(date -u +%s)" = "$NOW_EPOCH" ]
  [ -n "$(date)" ]
}

@test "pin_now: arithmetic forms pass through to the real date" {
  pin_now 2026-10-30T12:00:00Z
  run bash -c 'date -u -d "2026-01-02" +%F 2>/dev/null || date -u -j -f %Y-%m-%d 2026-01-02 +%F'
  [ "$output" = 2026-01-02 ]
}
