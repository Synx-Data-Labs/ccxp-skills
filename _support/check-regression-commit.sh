#!/usr/bin/env bash
# check-regression-commit.sh — same-commit fix + e2e regression test gate
# (T20261012-109735).
#
# Usage: check-regression-commit.sh <base>..<head>
# For every commit in the range that touches non-test source, the SAME commit
# must touch a path matching $SUPPORT_E2E_GLOB, or carry a non-empty
# `No-regression-test: <reason>` trailer (needs the user's explicit approval;
# the script verifies only the trailer). Docs, dev/**, and e2e paths are not
# "source", so claim/design/journal commits pass.
# Exit: 0 ok, 1 violation (fails closed), 2 usage/bad range.
#
# SUPPORT_E2E_GLOB: whitespace-separated globs; `*` spans `/`; a leading `**/`
# also matches the repo root.

set -euo pipefail

DEFAULT_E2E_GLOB='**/e2e/** **/tests/e2e/** **/*_e2e* **/*e2e_test*'

function support-glob-match() {
  local path="$1" globs="${SUPPORT_E2E_GLOB:-$DEFAULT_E2E_GLOB}" g
  set -f
  for g in $globs; do
    set +f
    # shellcheck disable=SC2053  # pattern match is intended
    [[ "$path" == $g || "/$path" == $g || "/$path" == /$g ]] && return 0
    set -f
  done
  set +f
  return 1
}

function support-is-docs() {
  case "$1" in
    dev/*|docs/*|*.md|LICENSE|.github/ISSUE_TEMPLATE/*) return 0 ;;
  esac
  return 1
}

function support-check-regression-commit() {
  local range="${1:-}"
  if [[ -z "$range" ]]; then
    echo "usage: check-regression-commit.sh <base>..<head>" >&2; return 2
  fi
  local shas
  if ! shas="$(git rev-list --reverse "$range" 2>/dev/null)"; then
    echo "error: cannot resolve range '$range'" >&2; return 2
  fi
  local sha path has_src has_e2e bad=0 reason src_list
  for sha in $shas; do
    has_src=0; has_e2e=0; src_list=""
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if support-glob-match "$path"; then has_e2e=1
      elif support-is-docs "$path"; then :
      else has_src=1; src_list+=" $path"; fi
    done < <(git diff-tree --no-commit-id --name-only -r -m --first-parent "$sha")
    [[ "$has_src" -eq 1 && "$has_e2e" -eq 0 ]] || continue
    reason="$(git log -1 --format=%B "$sha" | sed -n 's/^No-regression-test:[[:space:]]*//p' | head -1)"
    if [[ -n "${reason//[[:space:]]/}" ]]; then
      echo "warning: ${sha:0:9} exempted by No-regression-test: $reason (requires explicit user approval)" >&2
      continue
    fi
    echo "BLOCKED: ${sha:0:9} changes source without an e2e regression test in the same commit:${src_list}" >&2
    bad=1
  done
  [[ "$bad" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  support-check-regression-commit "$@"
fi
