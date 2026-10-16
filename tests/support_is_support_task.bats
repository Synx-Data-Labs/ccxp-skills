#!/usr/bin/env bats
# Tests for _support/is-support-task.sh and the gate-pr usage guard (T20261012-109735).

load test_helper
setup() {
  cd "$BATS_TEST_TMPDIR" && mkdir -p dev/TODO dev/JOURNAL
  printf -- '---\nstatus: Open\nestimation: 1\n---\n\n# T20260101-000001: a\n\n## Problem\n\n- **Type**: support\n' > dev/TODO/T20260101-000001-a.md
  printf -- '---\nstatus: Open\nestimation: 1\nsupport-issue: https://example.com/o/r/issues/1\n---\n\n# T20260101-000002: b\n' > dev/TODO/T20260101-000002-b.md
  printf -- '---\nstatus: Open\nestimation: 1\n---\n\n# T20260101-000003: c\n\n- **Type**: bug\n' > dev/TODO/T20260101-000003-c.md
}

@test "body Type bullet marks a support task" {
  run bash "$REPO_ROOT/_support/is-support-task.sh" T20260101-000001
  [ "$status" -eq 0 ]
}

@test "support-issue frontmatter key marks a support task (by file path)" {
  run bash "$REPO_ROOT/_support/is-support-task.sh" dev/TODO/T20260101-000002-b.md
  [ "$status" -eq 0 ]
}

@test "bug task and unknown id are not support tasks" {
  run bash "$REPO_ROOT/_support/is-support-task.sh" T20260101-000003
  [ "$status" -eq 1 ]
  run bash "$REPO_ROOT/_support/is-support-task.sh" T29990101-000009
  [ "$status" -eq 1 ]
}

@test "gate-pr rejects a non-numeric PR argument" {
  run bash "$REPO_ROOT/_support/gate-pr.sh" abc
  [ "$status" -eq 1 ]
}
