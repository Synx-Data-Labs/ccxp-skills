#!/usr/bin/env bash
# review-state.sh <pr-number> — /address-pr §2.d: has OUR independent Claude Code
# review already covered this PR's current head commit? Read-only.
#
# Looks at our own most recent PR comment whose body starts with
# `**Claude Code review:**` and takes the commit from its FIRST line,
# `(sha: <hex>)` (the header post-review.sh writes), then compares it with the
# PR's current head SHA.
#
# stdout: one line `reviewed <head-sha>` (the latest review covers exactly the
# head: skip to the approval gate) or `needs-review <head-sha>` (no review,
# review of an older commit, or a header without a sha: dispatch a fresh one).
# Pass that head sha to post-review.sh so the comment pins what was reviewed.
# Exit: 0 | 2 usage | 3 gh failed or output unusable (never read as `reviewed`).
# Judgment stays with the caller: the review itself, fix vs pushback.
#
# Env (tests): GH_SH overrides the gh wrapper (default _gh/gh.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"

usage() { echo "usage: review-state.sh <pr-number>" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
pr="$1"
[[ "$pr" =~ ^[0-9]+$ ]] || usage

fail() { echo "review-state.sh: $*" >&2; exit 3; }

me="$(bash "$GH_SH" api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)" || me=""
[ -n "$me" ] || fail "could not read the current gh user"
head="$(bash "$GH_SH" pr view "$pr" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null)" || head=""
[[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || fail "could not read the head commit of PR #$pr"
raw="$(bash "$GH_SH" api --paginate "repos/{owner}/{repo}/issues/${pr}/comments?per_page=100" 2>/dev/null)" \
  || fail "could not read the comments of PR #$pr"
comments="$(printf '%s' "$raw" | jq -s 'add // []' 2>/dev/null)" || fail "unexpected comment data for PR #$pr"
printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1 || fail "unexpected comment data for PR #$pr"

last_header="$(printf '%s' "$comments" | jq -r --arg me "$me" \
  '[.[] | select(.user.login == $me and ((.body // "") | startswith("**Claude Code review:**"))) | .body] | last // "" | split("\n")[0]')"
sha="$(printf '%s' "$last_header" | sed -nE 's/^\*\*Claude Code review:\*\* \(sha: ([0-9a-f]{7,40})\).*$/\1/p')"

if [ -n "$sha" ] && [ "$sha" = "$head" ]; then
  echo "reviewed $head"
else
  echo "needs-review $head"
fi
