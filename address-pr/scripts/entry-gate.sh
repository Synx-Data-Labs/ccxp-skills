#!/usr/bin/env bash
# entry-gate.sh <pr-number | pr-url | -> — /address-pr §1 (find the PR) + §1.3
# (authorship gate) + §1.6 (ownership verdict) as one read-only decision.
# Writes nothing: no claim, no Project-board update, no comment.
#
#   <n> | <url>   the PR to address (a .../pull/<n> URL is reduced to <n>, and must
#                 name the repo of the current clone: otherwise exit 2)
#   -             auto-pick (auto-pick.sh) the next pickable PR, then gate it
#
# stdout: one JSON line {number, task_id, author, verdict, head_ref}.
#   verdict: mine | untracked | free | new | foreign | owned:<agent> | unknown
#   task_id: "" when the PR maps to no task. author/head_ref: "" when unreadable.
# Exit codes (the caller MUST stop on anything but 0, 10 and 11):
#    0  proceed (verdict mine | untracked)
#   10  proceed after claiming the task first: verdict free (separate claim PR)
#   11  proceed after claiming on the PR's own branch: verdict new
#   20  foreign PR (not authored by the current gh user, or author/user unreadable):
#       take NO write action of any kind
#   21  owned by another session (verdict owned:<agent>): defer, do not touch
#   22  ownership unresolvable (verdict unknown, or an unrecognised/empty answer
#       from pr-owner): defer, fail-safe, never a silent merge
#    1  auto-pick found nothing pickable (nothing printed on stdout)
#    2  usage / not a PR number / URL of a different repo than this clone
# Fail-closed: a missing value (empty author, empty login, gh error, empty
# pr-owner answer) never yields a proceed code; the authorship check runs first and
# a foreign PR is never asked for its ownership.
# Judgment stays with the caller: what to tell the user, how to claim.
#
# Env (tests): GH_SH, TASK_CLAIM_SH, PR_TASK_ID_SH, AUTO_PICK_SH override the sibling scripts.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"
TASK_CLAIM_SH="${TASK_CLAIM_SH:-$HERE/../../_session/task_claim.sh}"
PR_TASK_ID_SH="${PR_TASK_ID_SH:-$HERE/../../_session/pr_task_id.sh}"
AUTO_PICK_SH="${AUTO_PICK_SH:-$HERE/auto-pick.sh}"

usage() { echo "usage: entry-gate.sh <pr-number | pr-url | ->" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
arg="$1"

if [ "$arg" = "-" ]; then
  picked="$(bash "$AUTO_PICK_SH")" || picked=""
  num="$(printf '%s' "$picked" | jq -r '.number // empty' 2>/dev/null)" || num=""
  [ -n "$num" ] || { echo "entry-gate.sh: no open PR to address" >&2; exit 1; }
elif [[ "$arg" =~ ^[0-9]+$ ]]; then
  num="$arg"
elif [[ "$arg" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
  # The gate reads the PR of the CURRENT clone's repo, so a URL for another repo
  # must not be reduced to its number: refuse unless it is this repo.
  num="${BASH_REMATCH[2]}"; url_repo="${BASH_REMATCH[1]}"
  here="$(bash "$GH_SH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || here=""
  if [ -z "$here" ] || [ "$(printf '%s' "$here" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$url_repo" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "entry-gate.sh: PR URL is for $url_repo but this clone's repo is '${here:-unreadable}'; cd into the right clone (or pass the number)" >&2
    exit 2
  fi
else
  echo "entry-gate.sh: not a PR number or URL: $arg" >&2; usage
fi

emit() { # <task_id> <author> <verdict> <head_ref>
  jq -cn --argjson n "$num" --arg t "$1" --arg a "$2" --arg v "$3" --arg h "$4" \
    '{number: $n, task_id: $t, author: $a, verdict: $v, head_ref: $h}'
}

me="$(bash "$GH_SH" api user --jq .login 2>/dev/null)" || me=""
view="$(bash "$GH_SH" pr view "$num" --json author,headRefName 2>/dev/null)" || view=""
author="$(printf '%s' "$view" | jq -r '.author.login // empty' 2>/dev/null)" || author=""
head_ref="$(printf '%s' "$view" | jq -r '.headRefName // empty' 2>/dev/null)" || head_ref=""

# §1.3: ours only. An unreadable author or login is foreign (err toward not touching).
if [ -z "$me" ] || [ -z "$author" ] || [ "$author" != "$me" ]; then
  emit "" "$author" foreign "$head_ref"
  exit 20
fi

task_id="$(bash "$PR_TASK_ID_SH" "$num" 2>/dev/null)" || task_id=""
task_id="$(printf '%s' "$task_id" | head -n1 | tr -d '[:space:]')"

# §1.6: ownership derives from the task claim.
own="$(bash "$TASK_CLAIM_SH" pr-owner "$num" 2>/dev/null)" || own=""
own="$(printf '%s' "$own" | head -n1 | tr -d '[:space:]')"
case "$own" in
  mine|untracked) emit "$task_id" "$author" "$own" "$head_ref"; exit 0 ;;
  free)           emit "$task_id" "$author" free "$head_ref"; exit 10 ;;
  new)            emit "$task_id" "$author" new "$head_ref"; exit 11 ;;
  owned:?*)       emit "$task_id" "$author" "$own" "$head_ref"; exit 21 ;;
  *)              emit "$task_id" "$author" unknown "$head_ref"; exit 22 ;;
esac
