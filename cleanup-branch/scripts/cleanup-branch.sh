#!/usr/bin/env bash
# cleanup-branch.sh — deterministic branch hygiene sweep for the /cleanup-branch skill.
#
# Usage:
#   cleanup-branch.sh                  # PR-verified sweep, all local branches (§1)
#   cleanup-branch.sh <branch>         # PR-verified sweep, scoped to one branch (§1)
#   cleanup-branch.sh prune            # delete branches whose upstream is [gone] (§2)
#   cleanup-branch.sh prune --dry-run  # list what §2 would delete, no deletion
#
# Prints a tab-separated report to stdout. Exits non-zero only on conditions
# that need a human/agent decision (e.g. checkout blocked by local changes) —
# those cases print to stderr and must NOT be worked around automatically
# (no stash, no discard).

set -euo pipefail

GH_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../_gh/gh.sh"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

run_prune() {
  local dry_run="${1:-}"
  local default current stale

  default="$(git remote show origin | sed -n 's/.*HEAD branch: //p')"
  [ -n "$default" ] || die "could not determine default branch from origin"

  git fetch --prune

  current="$(git branch --show-current)"
  stale="$(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2 == "[gone]" {print $1}' \
    | grep -Fxv "$default" | grep -Fxv "$current" || true)"

  if [ -z "$stale" ]; then
    echo "No stale branches to delete."
    return 0
  fi

  if [ "$dry_run" = "--dry-run" ]; then
    echo "Would delete (upstream gone):"
    echo "$stale"
    echo "Count: $(echo "$stale" | wc -l)"
    return 0
  fi

  local deleted=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git branch -D "$b"
    deleted=$((deleted + 1))
  done <<< "$stale"

  echo "Deleted: $deleted stale branch(es) (upstream gone)."
}

run_pr_verified() {
  local target="${1:-}"
  local candidates b res num url

  if ! git checkout main 2>/tmp/cleanup-branch-checkout-err; then
    cat /tmp/cleanup-branch-checkout-err >&2
    die "git checkout main failed — likely uncommitted changes. Stop; do not stash or discard."
  fi
  git pull
  git fetch --prune

  if [ -n "$target" ]; then
    candidates="$target"
  else
    candidates="$(git branch --format='%(refname:short)' | grep -v '^main$' || true)"
  fi

  if [ -z "$candidates" ]; then
    echo "no feature branches to clean up"
    return 0
  fi

  printf 'BRANCH\tSTATUS\tPR\n'
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    res="$(bash "$GH_SCRIPT" pr list --head "$b" --state merged --json number,url,mergedAt --jq '.[0]' 2>/dev/null || true)"
    if [ -z "$res" ] || [ "$res" = "null" ]; then
      printf '%s\tskipped: no merged PR\t\n' "$b"
      continue
    fi
    num="$(echo "$res" | jq -r '.number')"
    url="$(echo "$res" | jq -r '.url')"
    if git branch -d "$b" >/dev/null 2>&1; then
      printf '%s\tdeleted\t#%s %s\n' "$b" "$num" "$url"
    elif git branch -D "$b" >/dev/null 2>&1; then
      printf '%s\tdeleted (force, rebased/squash merge)\t#%s %s\n' "$b" "$num" "$url"
    else
      printf '%s\tERROR: could not delete\t#%s %s\n' "$b" "$num" "$url"
    fi
  done <<< "$candidates"

  echo
  echo "Current branch: main"
  git log -1 --oneline main
}

main() {
  if [ "${1:-}" = "prune" ]; then
    shift
    run_prune "${1:-}"
  else
    run_pr_verified "${1:-}"
  fi
}

main "$@"
