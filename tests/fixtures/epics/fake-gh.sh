#!/usr/bin/env bash
# tests/fixtures/epics/fake-gh.sh — a fake `gh` for tests/epic-status.bats.
#
# Put earlier on $PATH than the real gh (a fakebin dir). Understands exactly
# the subset of `gh` invocations epic-status.sh + `_gh/gh.sh` issue now that
# every lookup is local (T20261005-639913 dropped the cross-repo hub path and
# its contents/commits-API reads): account discovery/token, the
# `_gh_account_tier` write-access probe, and `gh pr list --search`. Anything
# else is logged to $EPIC_FAKE_GH_CALLLOG (when set) and exits 99, so a test
# can assert an unexpected call never happened.
#
# Contract (env vars a test sets before invoking epic-status.sh):
#
#   EPIC_FAKE_GH_ACCOUNTS   space-separated account names — `gh auth status`
#                           prints one "Logged in to github.com account
#                           <name>" line per name (the shape _gh_list_accounts's
#                           awk expects). `gh auth token --user <name>`
#                           deterministically returns "<name>-token".
#
#   EPIC_FAKE_GH_ACCESS     newline-separated "<token> <slug>" pairs —
#                           `gh api repos/<slug> --jq .permissions.push`
#                           (the write-access probe `_gh_account_tier` makes)
#                           prints "true" iff the caller's $GH_TOKEN pairs
#                           with that slug here, else exits 1 (no access).
#
#   EPIC_FAKE_GH_PR_FOR_ID / EPIC_FAKE_GH_PR_LINE
#                           `gh pr list --search <id> ...` prints
#                           $EPIC_FAKE_GH_PR_LINE only when <id> equals
#                           $EPIC_FAKE_GH_PR_FOR_ID; prints nothing (still
#                           exit 0 — "no PR") otherwise.
#
#   EPIC_FAKE_GH_CALLLOG    file every call's "$*" is appended to (optional).
set -uo pipefail

_log() {
  [ -n "${EPIC_FAKE_GH_CALLLOG:-}" ] && printf '%s\n' "$*" >> "$EPIC_FAKE_GH_CALLLOG"
}

# Every call is logged (not just unrecognized ones) so a test can assert a
# call DID happen (e.g. the permission probe against a specific slug) as
# well as that one didn't.
_log "$*"

case "${1:-}" in
  auth)
    case "${2:-}" in
      status)
        for acct in ${EPIC_FAKE_GH_ACCOUNTS:-}; do
          printf 'Logged in to github.com account %s (keyring)\n' "$acct"
        done
        exit 0 ;;
      token)
        # gh auth token --user <name>
        printf '%s-token\n' "${4:-}"
        exit 0 ;;
      *) exit 99 ;;
    esac
    ;;
  api)
    url="${2:-}"
    case "$url" in
      repos/*)
        # Bare "repos/<owner>/<repo>" — _gh_account_tier()'s permission probe
        # (_gh/gh.sh, T20260911-140914): `gh api repos/<slug> --jq
        # .permissions.push`. A token/slug pair listed in
        # EPIC_FAKE_GH_ACCESS means "has WRITE access" (prints "true").
        slug="${url#repos/}"
        if grep -qxF "${GH_TOKEN:-} $slug" <<<"${EPIC_FAKE_GH_ACCESS:-}"; then
          printf 'true\n'
          exit 0
        fi
        exit 1 ;;
      *) exit 99 ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      list)
        search=""
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in --search) search="${2:-}"; shift 2 ;; *) shift ;; esac
        done
        if [ -n "${EPIC_FAKE_GH_PR_FOR_ID:-}" ] && [ "$search" = "$EPIC_FAKE_GH_PR_FOR_ID" ]; then
          printf '%s\n' "${EPIC_FAKE_GH_PR_LINE:-}"
        fi
        exit 0 ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 99 ;;
esac
