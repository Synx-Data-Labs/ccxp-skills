#!/usr/bin/env bash
# tests/fixtures/git/fake-git.sh — a fake `git` for tests/git.bats' argv-leak
# regression test (T20260911-140914).
#
# Put a fakebin dir containing this file (named `git`) earlier on $PATH than
# the real git. Only intercepts the *wrapped* invocation main_git() execs
# into (the caller's own args, e.g. `push -u origin some-branch`) — gh.sh's
# own internal `git remote get-url origin` (used by _gh_repo_slug(), called
# *before* main_git()'s account-picking/exec) is delegated straight through
# to the real git via $REAL_GIT, since that call needs a genuine answer
# (the test's throwaway repo's actual origin) to reach main_git() at all.
#
# Contract:
#
#   REAL_GIT           absolute path to the real git binary — required,
#                       delegated to for anything shaped like a plain
#                       read/plumbing call (`remote get-url ...`, and
#                       anything else this fixture doesn't recognize as the
#                       final wrapped call, so it never silently swallows an
#                       internal call this file's own author didn't
#                       anticipate).
#
#   FAKE_GIT_CALLLOG    file the final wrapped call's argv (space-joined,
#                       "$*") and its own GH_TOKEN env var are appended to,
#                       one line each, prefixed "ARGV: " / "ENV_GH_TOKEN: "
#                       — lets a test assert the token reached the process
#                       via environment (functionality) while never
#                       appearing in argv (the exact leak the exec-env
#                       pattern caused).
set -uo pipefail

case "${1:-}" in
  remote)
    [ -n "${REAL_GIT:-}" ] || { echo "fake-git.sh: REAL_GIT not set" >&2; exit 99; }
    exec "$REAL_GIT" "$@"
    ;;
esac

# Anything else is treated as the final wrapped call (push, fetch, ...).
if [ -n "${FAKE_GIT_CALLLOG:-}" ]; then
  {
    printf 'ARGV: %s\n' "$*"
    printf 'ENV_GH_TOKEN: %s\n' "${GH_TOKEN:-}"
  } >> "$FAKE_GIT_CALLLOG"
fi

printf 'ok\n'
exit 0
