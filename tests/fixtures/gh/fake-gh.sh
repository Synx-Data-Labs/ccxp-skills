#!/usr/bin/env bash
# tests/fixtures/gh/fake-gh.sh — a fake `gh` for tests/gh.bats' write-aware
# account-picker + self-heal tests (T20260911-140914).
#
# Put a fakebin dir containing this file (named `gh`) earlier on $PATH than
# the real gh.
#
# Contract (env vars a test sets before invoking gh.sh):
#
#   FAKE_GH_ACCOUNTS   space-separated account names — `gh auth status`
#                       prints one "Logged in to github.com account <name>"
#                       line per name (the shape _gh_list_accounts' awk
#                       expects). `gh auth token --user <name>`
#                       deterministically returns "<name>-token".
#
#   FAKE_GH_PERM        space-separated "<token>:<true|false>" pairs.
#                       `gh api repos/<slug> --jq .permissions.push` prints
#                       the paired value and exits 0 when $GH_TOKEN has an
#                       entry here; a token with no entry means "can't see
#                       the repo at all" — exits 1, no output (404-shaped).
#
#   FAKE_GH_WRITE_OK    space-separated tokens for which any OTHER gh
#                       subcommand (pr create, pr merge, ...) succeeds
#                       (prints "ok", exits 0). A token not listed here gets
#                       a permission-shaped failure on stderr ("GraphQL:
#                       must be a collaborator (createPullRequest)"), exit 1
#                       — simulates a real write-permission denial.
#
#   FAKE_GH_GENERIC_FAIL=1   any OTHER gh subcommand always fails with an
#                       unrelated (non-permission-shaped) error, regardless
#                       of token — for asserting the wrapper does NOT retry
#                       on errors that aren't permission-shaped.
#
#   FAKE_GH_CALLLOG     file every call's "$* | GH_TOKEN=<token>" is
#                       appended to (optional) — lets a test assert how many
#                       attempts were made and with which account.
set -uo pipefail

_log() {
  [ -n "${FAKE_GH_CALLLOG:-}" ] && printf '%s | GH_TOKEN=%s\n' "$*" "${GH_TOKEN:-}" >> "$FAKE_GH_CALLLOG"
}
_log "$*"

case "${1:-}" in
  auth)
    case "${2:-}" in
      status)
        for acct in ${FAKE_GH_ACCOUNTS:-}; do
          printf 'Logged in to github.com account %s (keyring)\n' "$acct"
        done
        exit 0 ;;
      token)
        printf '%s-token\n' "${4:-}"
        exit 0 ;;
      *) exit 99 ;;
    esac
    ;;
  api)
    url="${2:-}"
    case "$url" in
      repos/*)
        for pair in ${FAKE_GH_PERM:-}; do
          tok="${pair%%:*}"
          val="${pair#*:}"
          if [ "$tok" = "${GH_TOKEN:-}" ]; then
            printf '%s\n' "$val"
            exit 0
          fi
        done
        exit 1 ;;
      *) exit 99 ;;
    esac
    ;;
  *)
    # Any other subcommand (pr create, pr view, pr merge, ...) is a
    # write-shaped call gated by FAKE_GH_WRITE_OK / FAKE_GH_GENERIC_FAIL.
    if [ "${FAKE_GH_GENERIC_FAIL:-0}" = "1" ]; then
      echo "HTTP 500: something unrelated broke" >&2
      exit 1
    fi
    for tok in ${FAKE_GH_WRITE_OK:-}; do
      if [ "$tok" = "${GH_TOKEN:-}" ]; then
        printf 'ok\n'
        exit 0
      fi
    done
    echo "GraphQL: must be a collaborator (createPullRequest)" >&2
    exit 1
    ;;
esac
