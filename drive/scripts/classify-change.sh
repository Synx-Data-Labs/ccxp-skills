#!/usr/bin/env bash
# classify-change.sh [base] — /drive Phase 3.0: classify the change as docs or code.
#
#   (renames are listed as delete + add, so a code file moved into docs/ still
#   counts as code: both the old and the new path are classified.)
#   base   ref to diff against (default: main); the changed set is
#          `git diff --name-only <base>...HEAD`. A base that does not resolve
#          (e.g. a clone with only origin/main) or a diff that cannot run is an
#          error (exit 4), never a silent `empty`: pass origin/main or fetch.
#
# A path is docs when it is
#   dev/** or docs/** (docs/ at any depth), any *.md (any depth),
#   .github/ISSUE_TEMPLATE/**, or .github/pull_request_template.md.
# Everything else is code (workflows, scripts, *.bats, Makefile, build configs).
# Aggregate: all docs -> docs; any code -> code (mixed is code: stricter wins);
# nothing changed -> empty (defer; re-run after the first commit).
#
# stdout: one word, docs | code | empty.   Exit: 0 | 2 usage | 3 not a git repo |
# 4 base ref does not resolve / diff failed (message on stderr, nothing on stdout).
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

git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || {
  echo "classify-change.sh: base ref '$base' does not resolve; fetch it or pass an existing ref (e.g. origin/main)" >&2
  exit 4
}
changed="$(git diff --no-renames --name-only "$base...HEAD" 2>/dev/null)" || {
  echo "classify-change.sh: git diff $base...HEAD failed (no merge base?); pass a different base" >&2
  exit 4
}

kind=empty
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    dev/*|docs/*|*/docs/*|*.md|.github/ISSUE_TEMPLATE/*|.github/pull_request_template.md) [ "$kind" = code ] || kind=docs ;;
    *) kind=code; break ;;
  esac
done <<<"$changed"
echo "$kind"
