#!/usr/bin/env bats
# Tests for _session/_lib.sh's session_pr_task_id() — correlates a PR number
# back to its task ID by trying three signals in priority order.
#
# T20260718-160579: the PR body `Task:` link must win over the branch name
# when both are present — a rescoped PR's branch name is fixed at
# PR-creation time and never renamed, while the body link is written
# deliberately to correct exactly this drift. `_session_gh` is stubbed per
# test (the function's own I/O seam — see task_claim.bats's
# _tc_resolve_task_location tests for the same pattern) so no network call
# fires.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_session/_lib.sh"
}

@test "body Task: link wins over a stale branch name (T20260718-160579)" {
  # Branch name encodes T20260601-100000 (the branch's original task); the
  # PR was later rescoped and the body's Task: link now points at
  # T20260601-100001 — the body link must win.
  _session_gh() {
    case "$*" in
      *"--json body"*) printf '%s' 'Task: https://github.com/example-org/example-repo/blob/main/dev/TODO/T20260601-100001-x.md' ;;
      *"--json headRefName"*) printf 't20260601-100000-impl' ;;
      *) printf '' ;;
    esac
  }
  [ "$(session_pr_task_id 234)" = "T20260601-100001" ]
}

@test "a T-id mentioned in prose BEFORE the Task: line does not win (a real-world shape)" {
  # The exact real-world shape that caught the bug in the priority-order fix
  # itself: a Summary bullet mentions unrelated T-ids ("Doc updates: T…
  # warm-up gap...") before the actual Task: line further down.
  BODY=$'## Summary\n\n- Doc updates: T20260501-100002 warm-up gap, T20260501-100003 decision\n\nTask: https://github.com/example-org/example-repo/blob/main/dev/TODO/T20260601-100001-x.md\n'
  _session_gh() {
    case "$*" in
      *"--json body"*) printf '%s' "$BODY" ;;
      *"--json headRefName"*) printf 't20260601-100000-impl' ;;
      *) printf '' ;;
    esac
  }
  [ "$(session_pr_task_id 234)" = "T20260601-100001" ]
}

@test "falls back to branch name when the body has no Task: link" {
  _session_gh() {
    case "$*" in
      *"--json body"*) printf 'no task link here' ;;
      *"--json headRefName"*) printf 't20260515-171645-impl' ;;
      *) printf '' ;;
    esac
  }
  [ "$(session_pr_task_id 42)" = "T20260515-171645" ]
}

@test "falls back to commit messageHeadline scan when neither body nor branch match (parens form)" {
  # Realistic repo convention: "this commit closes/implements task X" is
  # marked with a trailing `(T<id>)`, not a bare substring anywhere in the
  # message (T20260925-332662).
  _session_gh() {
    case "$*" in
      *"--json body"*) printf 'no task link here' ;;
      *"--json headRefName"*) printf 'fix/unrelated-branch' ;;
      *"--json commits"*) printf 'fix(pr_task_id): narrow signal-3 regex (T20260101-000001)\nunrelated commit' ;;
      *) printf '' ;;
    esac
  }
  [ "$(session_pr_task_id 7)" = "T20260101-000001" ]
}

@test "commit messageHeadline scan also accepts a leading 'T<id>:' subject prefix" {
  _session_gh() {
    case "$*" in
      *"--json body"*) printf 'no task link here' ;;
      *"--json headRefName"*) printf 'fix/unrelated-branch' ;;
      *"--json commits"*) printf 'T20260101-000003: fix something\nunrelated commit' ;;
      *) printf '' ;;
    esac
  }
  [ "$(session_pr_task_id 7)" = "T20260101-000003" ]
}

@test "a bare T<id> mentioned as DATA in a commit subject does not false-positive via signal 3 (T20260925-332662)" {
  # The exact shape that caused the false positive: /top's own commit message
  # names the task being reordered as data, not "this PR implements that
  # task" — e.g. "docs(queue): move T<id> to the top". A bare substring must
  # NOT resolve via signal 3.
  _session_gh() {
    case "$*" in
      *"--json body"*) printf 'no task link here' ;;
      *"--json headRefName"*) printf 'fix/unrelated-branch' ;;
      *"--json commits"*) printf 'docs(queue): move T20260806-147372 to the top\nunrelated commit' ;;
      *) printf '' ;;
    esac
  }
  [ -z "$(session_pr_task_id 7)" ]
}

@test "no PR number -> empty output, exit 0" {
  run session_pr_task_id ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nothing matches any signal -> empty output" {
  _session_gh() { printf ''; }
  [ -z "$(session_pr_task_id 99)" ]
}
