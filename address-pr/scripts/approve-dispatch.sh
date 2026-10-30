#!/usr/bin/env bash
# approve-dispatch.sh <pr-number> <head-sha> (--clean-bill | --lgtm-by <login> [--findings-open]) [--dry-run]
# /address-pr §2.d approval gate: dispatch the repo's `pr-approve.yml` (synx-merge-bot) for
# <head-sha>, poll the PR's own reviews for a genuine APPROVED review pinned to that exact
# commit, and, only if none landed, take the local-mint fallback (when the App credentials
# are already in the environment). It encodes the existing mechanics only: whether the
# review was a clean bill, and whether findings are open, are the caller's judgment, passed
# in as the trigger flag.
#
# Trigger (exactly one; none, or an unknown flag, is a usage error: fail closed):
#   --clean-bill        the independent review of <head-sha> found nothing real
#   --lgtm-by <login>   the PR author's LGTM (has-lgtm.sh printed <login>); never
#                       enough while findings are open
#   --findings-open     with --lgtm-by: a finding is still unanswered -> not-eligible
#                       (a usage error together with --clean-bill)
# --dry-run: runs the read-only checks (workflow present, repo), prints what would be
#   dispatched/polled/posted, and changes nothing on GitHub.
#
# stdout (one line) and exit:
#    0  approved via workflow <sha> | approved via fallback <sha> | dry-run ... (would act)
#   10  no-workflow   the repo has no pr-approve.yml on its default branch (or gh could not
#                     tell: deliberately fail-safe, never approves); nothing was dispatched
#   11  timeout       dispatched, but no approval landed in the window and the fallback was
#                     unavailable or failed; the §2.a mergeability check is the backstop
#   12  not-eligible  --lgtm-by with --findings-open; nothing was dispatched
#    2  usage / <head-sha> is not a full 40-hex commit id
# The token is never printed.
#
# Env: APPROVE_POLL_TRIES (default 12, >=1), APPROVE_POLL_INTERVAL seconds (default 10, >=0).
# Env (tests): GH_SH, GH_APP_TOKEN_SH override the sibling scripts; GH_APP_ID and
#   GH_APP_PRIVATE_KEY_FILE | GH_APP_PRIVATE_KEY enable the fallback.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"
GH_APP_TOKEN_SH="${GH_APP_TOKEN_SH:-$HERE/../../_gh/gh-app-token.sh}"
TRIES="${APPROVE_POLL_TRIES:-12}"
INTERVAL="${APPROVE_POLL_INTERVAL:-10}"

usage() {
  echo "usage: approve-dispatch.sh <pr-number> <head-sha> (--clean-bill | --lgtm-by <login> [--findings-open]) [--dry-run]" >&2
  exit 2
}
dry=0 clean=0 lgtm="" findings=0 args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --clean-bill) clean=1 ;;
    --findings-open) findings=1 ;;
    --lgtm-by) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; lgtm="$2"; shift ;;
    -*) usage ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ "${#args[@]}" -eq 2 ] || usage
pr="${args[0]}" sha="${args[1]}"
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "approve-dispatch.sh: head-sha must be a full 40-hex commit id: $sha" >&2; exit 2; }
[[ "$TRIES" =~ ^[0-9]+$ ]] && [ "$TRIES" -ge 1 ] || { echo "approve-dispatch.sh: APPROVE_POLL_TRIES must be an integer >= 1" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "approve-dispatch.sh: APPROVE_POLL_INTERVAL must be an integer >= 0" >&2; exit 2; }
if [ "$clean" = 1 ]; then
  [ -z "$lgtm" ] && [ "$findings" = 0 ] || usage
elif [ -z "$lgtm" ]; then
  usage
elif [ "$findings" = 1 ]; then
  echo "not-eligible"; echo "approve-dispatch.sh: LGTM does not count while a finding is open" >&2; exit 12
fi

# Fail-safe: cannot tell "no pr-approve.yml" from a transient/auth failure; either way no approval.
bash "$GH_SH" workflow view pr-approve.yml >/dev/null 2>&1 || { echo "no-workflow"; exit 10; }
[ -n "$lgtm" ] && echo "approval triggered via LGTM by $lgtm" >&2

# The local-mint fallback is taken only when the App credentials are already in the environment.
fallback=0
if [ -n "${GH_APP_ID:-}" ] && { [ -n "${GH_APP_PRIVATE_KEY_FILE:-}" ] || [ -n "${GH_APP_PRIVATE_KEY:-}" ]; }; then fallback=1; fi

if [ "$dry" = 1 ]; then
  echo "dry-run: would dispatch pr-approve.yml -f pr_number=$pr -f commit_sha=$sha, poll up to $TRIES x ${INTERVAL}s for an APPROVED review at $sha, then $([ "$fallback" = 1 ] && echo 'fall back to a locally minted bot approval' || echo 'give up (no App credentials: no fallback)')"
  exit 0
fi

bash "$GH_SH" workflow run pr-approve.yml -f pr_number="$pr" -f commit_sha="$sha" >/dev/null 2>&1 \
  || echo "approve-dispatch.sh: workflow dispatch failed; still checking for a landed approval" >&2

# Poll the PR's own reviews, not the workflow run: what matters is a genuine APPROVED
# review pinned to this commit. Bounded: a slow/failed dispatch must never hang the loop.
landed() {
  bash "$GH_SH" pr view "$pr" --json reviews 2>/dev/null \
    | jq -e --arg sha "$sha" '[.reviews[]? | select(.state == "APPROVED" and .commit.oid == $sha)] | length > 0' >/dev/null 2>&1
}
i=1
while [ "$i" -le "$TRIES" ]; do
  landed && { echo "approved via workflow $sha"; exit 0; }
  [ "$i" -lt "$TRIES" ] && sleep "$INTERVAL"
  i=$((i + 1))
done

if [ "$fallback" = 1 ]; then
  slug="$(bash "$GH_SH" repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty' 2>/dev/null)" || slug=""
  token=""
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && token="$(bash "$GH_APP_TOKEN_SH" --repo "$slug" 2>/dev/null || true)"
  if [ -n "$token" ] \
     && GH_TOKEN="$token" bash "$GH_SH" api --method POST "repos/$slug/pulls/$pr/reviews" \
          -f event=APPROVE -f commit_id="$sha" \
          -f body="Approved by synx-merge-bot (local-mint fallback) after a clean independent review at $sha." >/dev/null 2>&1; then
    echo "approved via fallback $sha"; exit 0
  fi
fi
echo "timeout"
echo "approve-dispatch.sh: no landed approval at $sha (dispatch within the poll window, then the local-mint fallback); the mergeability check in step a will show whether this blocks merge" >&2
exit 11
