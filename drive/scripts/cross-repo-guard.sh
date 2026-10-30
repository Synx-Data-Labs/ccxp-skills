#!/usr/bin/env bash
# cross-repo-guard.sh <task-id> <owner/repo> — /drive Phase 1.5.0 existing-work
# guard: before cloning or writing code for a cross-repo task, look for work the
# hub cannot see (branches/PRs live in the TARGET repo). Stops an unattended loop
# from opening a duplicate PR for the same task every tick.
#
# stdout, one line:
#   open <pr-number> <headRefName>   an OPEN PR matches: do not re-implement, drive that PR
#                                    (several open: the lowest number; the rest go to stderr)
#   merged <pr-number>               no open PR but a MERGED one: the work shipped, go to Phase 7
#   none                             no match (a CLOSED-unmerged PR does not count): implement
# Exit codes: 0 ok | 2 usage | 3 gh failed or returned non-JSON (never read as "none").
# Judgment stays with the caller: whether the matching PR really implements the task.
#
# Env (tests): GH_SH overrides the gh wrapper (default _gh/gh.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"

usage() { echo "usage: cross-repo-guard.sh <task-id> <owner/repo>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
id="$1" repo="$2"
[[ "$id" =~ ^T[0-9]+(-[0-9]+)?$ ]] || { echo "cross-repo-guard.sh: not a task id: $id" >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "cross-repo-guard.sh: not owner/repo: $repo" >&2; exit 2; }

json="$(bash "$GH_SH" pr list --repo "$repo" --search "$id" --state all \
  --json number,state,title,headRefName,url 2>/dev/null)" || {
  echo "cross-repo-guard.sh: gh pr list failed for $repo" >&2; exit 3; }
printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  echo "cross-repo-guard.sh: unexpected gh output for $repo" >&2; exit 3; }

open="$(printf '%s' "$json" | jq -r '[.[] | select(.state == "OPEN")] | sort_by(.number)
  | if length == 0 then empty else "\(.[0].number) \(.[0].headRefName)" end')"
if [ -n "$open" ]; then
  extra="$(printf '%s' "$json" | jq -r '[.[] | select(.state == "OPEN")] | sort_by(.number) | .[1:] | map("#\(.number)") | join(" ")')"
  [ -z "$extra" ] || echo "cross-repo-guard.sh: more open PRs match: $extra" >&2
  echo "open $open"; exit 0
fi
merged="$(printf '%s' "$json" | jq -r '[.[] | select(.state == "MERGED")] | sort_by(.number) | if length == 0 then empty else "\(.[-1].number)" end')"
if [ -n "$merged" ]; then echo "merged $merged"; exit 0; fi
echo none
