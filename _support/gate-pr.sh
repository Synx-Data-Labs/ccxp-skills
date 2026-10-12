#!/usr/bin/env bash
# gate-pr.sh — /address-pr hard-merge-gate hook for support tasks
# (T20261012-109735).
#
# Usage: gate-pr.sh <pr-number>   (run from a clone of the PR's repo)
# Resolves the PR's task (_session/pr_task_id.sh); if it is not a support task
# (or the task file is not in this clone) the gate is a no-op (exit 0). For a
# support task it fetches the PR head from `origin` and runs
# check-regression-commit.sh over base..head. Fork PRs cannot be verified and
# are blocked. Exit: 0 pass/not applicable, 1 blocked.

set -uo pipefail
_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function support-gate-pr() {
  local pr="${1:-}" task base fork
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "usage: gate-pr.sh <pr-number>" >&2; return 1; }
  task="$(bash "$_SUPPORT_DIR/../_session/pr_task_id.sh" "$pr" 2>/dev/null || true)"
  [[ -n "$task" ]] || return 0
  bash "$_SUPPORT_DIR/is-support-task.sh" "$task" || return 0
  base="$(bash "$_SUPPORT_DIR/../_gh/gh.sh" pr view "$pr" --json baseRefName --jq .baseRefName 2>/dev/null)"
  fork="$(bash "$_SUPPORT_DIR/../_gh/gh.sh" pr view "$pr" --json isCrossRepository --jq .isCrossRepository 2>/dev/null)"
  if [[ -z "$base" || "$fork" == "true" ]]; then
    echo "BLOCKED: support gate cannot verify PR #$pr (fork PR or unreadable metadata)" >&2
    return 1
  fi
  git fetch -q origin "$base" "pull/$pr/head:refs/remotes/support-gate/pr-$pr" || {
    echo "BLOCKED: support gate could not fetch PR #$pr head" >&2; return 1; }
  bash "$_SUPPORT_DIR/check-regression-commit.sh" "origin/$base..refs/remotes/support-gate/pr-$pr"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  support-gate-pr "$@"
fi
