#!/usr/bin/env bats
# Guards for T20261010-482917: /address-pr approves via the synx-merge-bot
# pr-approve.yml workflow, arms auto-merge, local minting is fallback only.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/address-pr/SKILL.md"

@test "pr-approve.yml exists, is dispatch-only and pins commit_sha" {
  f="$REPO_ROOT/.github/workflows/pr-approve.yml"
  [ -f "$f" ]
  grep -q "workflow_dispatch:" "$f"
  grep -q "commit_sha:" "$f"
  grep -q "commit_id=" "$f"
}

@test "address-pr step d dispatches with commit_sha then arms --auto merge" {
  grep -q 'workflow run pr-approve.yml -f pr_number=<NUMBER> -f commit_sha="${HEAD_SHA}"' "$SKILL"
  grep -q 'pr merge --auto --rebase --delete-branch' "$SKILL"
}

@test "address-pr documents gh-app-token.sh as fallback only" {
  grep -q 'gh-app-token.sh' "$SKILL"
  grep -q 'fallback only' "$SKILL"
}

@test "guidelines templates document the approval gate" {
  for f in dev/guidelines.md repo-conventions/templates/guidelines.md repo-conventions/scripts/mode.sh; do
    grep -q 'Approval gate' "$REPO_ROOT/$f"
  done
}
