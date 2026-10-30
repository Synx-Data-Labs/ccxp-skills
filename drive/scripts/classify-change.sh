#!/usr/bin/env bash
# classify-change.sh [base] — /drive Phase 3.0: classify the change as docs or code.
#
#   base   ref to diff against (default: main); the changed set is
#          `git diff --name-only <base>...HEAD`, falling back to the working-tree
#          status when that diff cannot run (no such ref).
#
# A path is docs when it is
#   dev/** or docs/** (docs/ at any depth), any *.md (any depth),
#   .github/ISSUE_TEMPLATE/**, or .github/pull_request_template.md.
# Everything else is code (workflows, scripts, *.bats, Makefile, build configs).
# Aggregate: all docs -> docs; any code -> code (mixed is code: stricter wins);
# nothing changed -> empty (defer; re-run after the first commit).
#
# stdout: one word, docs | code | empty.   Exit: 0 | 2 usage | 3 not a git repo.
# Judgment stays with the caller: which TDD/verification route each class takes.

set -uo pipefail

usage() { echo "usage: classify-change.sh [base]" >&2; exit 2; }

base=main
case "$#" in
  0) ;;
  1) case "$1" in -*) usage ;; *) base="$1" ;; esac ;;
  *) usage ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "classify-change.sh: not a git repository" >&2; exit 3; }

if ! changed="$(git diff --name-only "$base...HEAD" 2>/dev/null)"; then
  # porcelain: "XY path" or "XY old -> new"; keep the new path
  changed="$(git status --porcelain 2>/dev/null | cut -c4- | sed 's/.* -> //; s/^"//; s/"$//')"
fi

kind=empty
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    dev/*|docs/*|*/docs/*|*.md|.github/ISSUE_TEMPLATE/*|.github/pull_request_template.md) [ "$kind" = code ] || kind=docs ;;
    *) kind=code; break ;;
  esac
done <<<"$changed"
echo "$kind"
