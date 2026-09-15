#!/usr/bin/env bash
# tests/fixtures/epics/fake-gh.sh — a fake `gh` for tests/epic-status.bats.
#
# Put earlier on $PATH than the real gh (a fakebin dir). Understands exactly
# the subset of `gh` invocations epic-status.sh + _gh/gh.sh issue; anything
# else is logged to $EPIC_FAKE_GH_CALLLOG (when set) and exits 99, so a test
# can assert an unexpected call never happened.
#
# Contract (env vars a test sets before invoking epic-status.sh):
#
#   EPIC_FAKE_GH_ACCOUNTS   space-separated account names, e.g.
#                           "hub-user other-user" — `gh auth status` prints
#                           one "Logged in to github.com account <name>"
#                           line per name (the shape _gh_list_accounts'
#                           awk expects). `gh auth token --user <name>`
#                           deterministically returns "<name>-token".
#
#   EPIC_FAKE_GH_ACCESS     newline-separated "<token> <slug>" pairs —
#                           `gh repo view <slug>` exits 0 iff the caller's
#                           $GH_TOKEN pairs with that slug here, else 1.
#                           This is what makes the account-scoping test
#                           meaningful: give one account access to the hub
#                           slug and a different account access to the
#                           local repo's slug, regardless of which slug
#                           $PWD's own origin resolves to.
#
#   EPIC_FAKE_GH_HUB_DIR    a local directory standing in for the HUB repo's
#                           tree (dev/EPICS.md, dev/TODO/*.md,
#                           dev/PARKING/*.md, dev/JOURNAL/*.md). Contents-API
#                           reads (`gh api repos/.../contents/<path>?ref=main`)
#                           serve files from here, base64-encoded — same
#                           shape the real GitHub contents API returns.
#                           Directory-contents reads (dev/TODO etc, used by
#                           _epic_hub_lookup's startswith search) list this
#                           directory's filenames, filtered by the task id
#                           embedded in the --jq startswith(...) argument.
#
#   EPIC_FAKE_GH_EPICS_MISSING=1   simulate a 404 on dev/EPICS.md (exit 1,
#                           no output) regardless of EPIC_FAKE_GH_HUB_DIR.
#
#   EPIC_FAKE_GH_COMMIT_DATE_<safe path>
#                           ISO-8601 date returned for the commits-API call
#                           (`gh api repos/.../commits?path=<path>&per_page=1`)
#                           on that exact path — <safe path> is <path> with
#                           every non-alnum character turned into "_". Falls
#                           back to $EPIC_FAKE_GH_COMMIT_DATE when the
#                           path-specific var isn't set.
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

_safe_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

# Every call is logged (not just unrecognized ones) so a test can assert a
# call DID happen (e.g. "repo view <hub slug>", to prove the account-scoping
# fix used the hub-scoped token) as well as that one didn't.
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
  repo)
    case "${2:-}" in
      view)
        slug="${3:-}"
        # Here-string, not `printf ... | grep -qxF`: with `pipefail` set (as
        # this script does), a live producer racing an early-exiting `grep
        # -q` can have the PRODUCER'S stage register the pipeline's exit
        # status (verified: `false | true` reports 1, not 0) even though
        # grep itself matched — silently flipping this "access granted"
        # check to "denied" under load. A here-string has no live producer
        # to race (bash fully materializes it first), so it can't happen.
        if grep -qxF "${GH_TOKEN:-} $slug" <<<"${EPIC_FAKE_GH_ACCESS:-}"; then
          exit 0
        fi
        exit 1 ;;
      *) exit 99 ;;
    esac
    ;;
  api)
    url="${2:-}"
    case "$url" in
      repos/*/contents/dev/EPICS.md\?ref=main)
        [ "${EPIC_FAKE_GH_EPICS_MISSING:-0}" = "1" ] && exit 1
        [ -r "${EPIC_FAKE_GH_HUB_DIR:-}/dev/EPICS.md" ] || exit 1
        base64 < "${EPIC_FAKE_GH_HUB_DIR}/dev/EPICS.md"
        exit 0 ;;
      repos/*/contents/dev/TODO\?ref=main | repos/*/contents/dev/PARKING\?ref=main | repos/*/contents/dev/JOURNAL\?ref=main)
        dir="$(sed -E 's#repos/[^?]+/contents/(dev/[A-Z]+)\?ref=main#\1#' <<<"$url")"
        jqarg=""
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in --jq) jqarg="${2:-}"; shift 2 ;; *) shift ;; esac
        done
        # Here-string + parameter expansion, not `| grep -oE ... | head -1`
        # — see the "repo view" branch above for why a live pipe into an
        # early-exiting consumer is unsafe under `pipefail`, not just style.
        id="$(grep -oE 'T[0-9]{8}-[0-9]{6}' <<<"$jqarg")"
        id="${id%%$'\n'*}"
        d="${EPIC_FAKE_GH_HUB_DIR:-}/$dir"
        [ -d "$d" ] || exit 0
        for f in "$d"/*; do
          [ -e "$f" ] || continue
          base="$(basename "$f")"
          case "$base" in "$id"*) printf '%s\n' "$base" ;; esac
        done
        exit 0 ;;
      repos/*/contents/*\?ref=main)
        path="$(sed -E 's#repos/[^?]+/contents/(.*)\?ref=main#\1#' <<<"$url")"
        f="${EPIC_FAKE_GH_HUB_DIR:-}/$path"
        [ -r "$f" ] || exit 1
        base64 < "$f"
        exit 0 ;;
      repos/*/commits\?path=*)
        path="$(sed -E 's#repos/[^?]+/commits\?path=([^&]*)&.*#\1#' <<<"$url")"
        key="EPIC_FAKE_GH_COMMIT_DATE_$(_safe_key "$path")"
        val="${!key:-${EPIC_FAKE_GH_COMMIT_DATE:-}}"
        [ -n "$val" ] && printf '%s\n' "$val"
        exit 0 ;;
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
