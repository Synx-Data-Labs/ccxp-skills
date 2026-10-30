#!/usr/bin/env bash
# wait-merged.sh <pr-number> — /address-pr §3.3: `gh pr merge --auto` returns before the
# merge happens, so poll the PR's state until it is MERGED before the Status=Done write and
# any branch cleanup. Read-only: it never merges, closes or edits anything.
#
# stdout (one line) and exit:
#    0  merged
#   11  timeout: still OPEN when the window ran out (stdout `timeout open`); do not run
#       step 4: report and let the merge policy / branch protection decide
#   12  closed: the PR was CLOSED without merging (stdout `closed`); stop and report
#    4  gh failed (or returned an unusable state) on every poll: the state was never read
#    2  usage
# An unreadable or unknown state is never read as MERGED (fail closed).
#
# Env: WAIT_MERGED_TRIES (default 30, >=1), WAIT_MERGED_INTERVAL seconds (default 10, >=0).
# Env (tests): GH_SH overrides the gh wrapper (default _gh/gh.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"
TRIES="${WAIT_MERGED_TRIES:-30}"
INTERVAL="${WAIT_MERGED_INTERVAL:-10}"

usage() { echo "usage: wait-merged.sh <pr-number>" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
pr="$1"
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$TRIES" =~ ^[0-9]+$ ]] && [ "$TRIES" -ge 1 ] || { echo "wait-merged.sh: WAIT_MERGED_TRIES must be an integer >= 1" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "wait-merged.sh: WAIT_MERGED_INTERVAL must be an integer >= 0" >&2; exit 2; }

read_ok=0 i=1
while [ "$i" -le "$TRIES" ]; do
  state="$(bash "$GH_SH" pr view "$pr" --json state 2>/dev/null | jq -r '.state // empty' 2>/dev/null)" || state=""
  case "$state" in
    MERGED) echo "merged"; exit 0 ;;
    CLOSED) echo "closed"; exit 12 ;;
    OPEN) read_ok=1 ;;
  esac
  [ "$i" -lt "$TRIES" ] && sleep "$INTERVAL"
  i=$((i + 1))
done
if [ "$read_ok" = 1 ]; then echo "timeout open"; exit 11; fi
echo "wait-merged.sh: could not read the state of PR #$pr" >&2
exit 4
