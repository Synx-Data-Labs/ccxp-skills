#!/usr/bin/env bash
# _gh/land.sh — the shared "land these paths as a PR" step: (branch) -> add ->
# commit -> push -> gh pr create. Used by /stage, /top, /bottom and anything
# else that lands a small bookkeeping change. Prints the new PR's URL on stdout;
# driving it to merge stays with /address-pr.
#
# Usage:
#   bash land.sh --branch <name> --message <commit-msg> --title <pr-title> \
#                [--body <text> | --body-file <file>] [--base main] -- <path>...
#
#   --branch   created from the current HEAD unless it is already checked out
#   --message  commit message; a Co-Authored-By trailer is the caller's job
#   Only the listed paths are staged (scope discipline: nothing else in the
#   working tree is touched). Exits 3 without side effects when none of them
#   has changes (nothing to land).
# Env: LAND_GIT / LAND_GH override the git / gh wrappers (default: sibling
# git.sh / gh.sh, which pick the right gh account for the repo).
set -euo pipefail

function land() {
  local dir branch="" message="" title="" body="" body_file="" base="main"
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local git_cmd="${LAND_GIT:-bash $dir/git.sh}" gh_cmd="${LAND_GH:-bash $dir/gh.sh}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      --message) message="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "land.sh: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$branch" && -n "$message" && -n "$title" && $# -gt 0 ]] \
    || { echo "land.sh: --branch, --message, --title and at least one path are required" >&2; return 2; }

  # Nothing to land -> exit 3 before creating a branch.
  if [[ -z "$(git status --porcelain -- "$@")" ]]; then
    echo "land.sh: no changes in the given paths — nothing to land" >&2
    return 3
  fi

  [[ "$(git rev-parse --abbrev-ref HEAD)" == "$branch" ]] || git checkout -q -b "$branch"
  git add -- "$@"
  git commit -q -m "$message"
  $git_cmd push -q -u origin "$branch" >&2

  if [[ -n "$body_file" ]]; then
    $gh_cmd pr create --base "$base" --head "$branch" --title "$title" --body-file "$body_file"
  else
    $gh_cmd pr create --base "$base" --head "$branch" --title "$title" --body "$body"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  land "$@"
fi
