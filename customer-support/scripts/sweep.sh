#!/usr/bin/env bash
# sweep.sh — delivered-timeout sweep for /customer-support (T20261021-266225).
# An open issue that has sat in `delivered` for >= --days (default 14) with no
# rejection is closed (completed) with a marked "NOT an acceptance" comment,
# so support/customer can reopen it (a reopen routes through `start`,
# delivered -> in-progress).
#
# Usage:
#   sweep.sh <owner/repo> [--days N] [--apply]     # default is DRY-RUN
#
# The close itself ALWAYS goes through `transition.sh autoclose` (the single
# enforced entrypoint), which re-runs the eligibility gate below — so this
# script's --apply cannot bypass the rules and neither can a direct call.
#
# Output (one line per delivered issue):
#   #N: WOULD CLOSE (delivered 15d ago)      (or: CLOSED with --apply)
#   #N: SKIP <reason>                        (too young, blocked, ...)
#   #N: FLAG needs human: <reason>           (a person has to look)
#
# Seams: CS_GH (gh), CS_NOW (epoch seconds, for tests).
set -euo pipefail

CS_SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./label_names.sh
source "${CS_SWEEP_DIR}/label_names.sh"

CS_SWEEP_DEFAULT_DAYS=14
CS_AUTOCLOSE_MARKER="<!-- cs-autoclose -->"

CS_GH="${CS_GH:-}"
cs-sweep-gh() {
  if [[ -n "$CS_GH" ]]; then "$CS_GH" "$@"; else gh "$@"; fi
}

# cs-sweep-days-check <days> — integer >= 1 (the floor is enforced here and
# therefore inside autoclose: a fresh delivery can never be closed).
cs-sweep-days-check() {
  local d="${1:-}"
  if ! [[ "$d" =~ ^[0-9]+$ ]] || [[ "$d" -lt 1 ]]; then
    echo "error: --days must be an integer >= 1 (got '${d}')" >&2
    return 2
  fi
}

# cs-sweep-timeline <repo> <issue> — flat JSON array of timeline events.
cs-sweep-timeline() {
  local repo="$1" issue="$2"
  cs-sweep-gh api --paginate --slurp "repos/${repo}/issues/${issue}/timeline" \
    | jq 'if (length > 0 and (.[0]|type)=="array") then add else . end'
}

# cs-sweep-eval <timeline-json> <label-names-newline-separated> <now-epoch> <days>
# Pure decision, no I/O. Prints CLOSE <age>d | SKIP <reason> | FLAG <reason>.
cs-sweep-eval() {
  local timeline="${1:?timeline json}" labels="${2-}" now="${3:?now epoch}" days="${4:?days}"
  if ! grep -qxF "$CS_L_DELIVERED" <<<"$labels"; then echo "SKIP not in ${CS_L_DELIVERED}"; return 0; fi
  if grep -qxF "$CS_L_BLOCKED" <<<"$labels"; then echo "SKIP ${CS_L_BLOCKED}"; return 0; fi
  if grep -qxF "$CS_L_NEEDS_UPSTREAM" <<<"$labels"; then echo "SKIP ${CS_L_NEEDS_UPSTREAM}"; return 0; fi
  jq -r --arg d "$CS_L_DELIVERED" --arg m "$CS_AUTOCLOSE_MARKER" \
    --argjson now "$now" --argjson days "$days" '
    ([.[] | select(.event=="labeled" and .label.name==$d)] | last) as $l
    | if $l == null then "FLAG no `\($d)` label event on the timeline (cannot date the delivery)"
      else
        ($l.created_at) as $t
        | ($l.actor.login // "") as $who
        | (($now - ($t | fromdateiso8601)) / 86400 | floor) as $age
        | if $age < $days then "SKIP too young (\($age)d < \($days)d)"
          elif ([.[] | select(.event=="reopened" and .created_at > $t)] | length) > 0
            then "FLAG needs human: reopened after delivery"
          else
            ([.[] | select(.event=="commented" and .created_at > $t
                           and ((.body // "") | contains($m) | not)
                           and ((.actor.login // .user.login // "") != $who))
              | (.actor.login // .user.login // "?")] | first) as $c
            | if $c != null then "FLAG needs human: comment by \($c) after delivery"
              else "CLOSE \($age)d" end
          end
      end' <<<"$timeline"
}

# cs-sweep-has-marker <timeline-json> — exit 0 if our autoclose comment exists.
cs-sweep-has-marker() {
  jq -e --arg m "$CS_AUTOCLOSE_MARKER" \
    '[.[] | select(.event=="commented" and ((.body // "") | contains($m)))] | length > 0' \
    <<<"${1:?timeline json}" >/dev/null
}

# cs-sweep-now — epoch seconds (CS_NOW overrides, for tests).
cs-sweep-now() { echo "${CS_NOW:-$(date -u +%s)}"; }

# cs-autoclose-gate <repo> <issue> <days> — the gate transition.sh autoclose
# runs: re-fetch labels + timeline, require a CLOSE verdict. Prints the
# verdict line; exit 1 when not eligible.
cs-autoclose-gate() {
  local repo="$1" issue="$2" days="$3" labels timeline verdict
  cs-sweep-days-check "$days" || return 2
  labels=$(cs-sweep-gh issue view "$issue" --repo "$repo" --json labels | jq -r '.labels[].name')
  timeline=$(cs-sweep-timeline "$repo" "$issue")
  verdict=$(cs-sweep-eval "$timeline" "$labels" "$(cs-sweep-now)" "$days")
  echo "$verdict"
  [[ "$verdict" == CLOSE* ]]
}

cs-sweep-main() {
  local repo="" days="$CS_SWEEP_DEFAULT_DAYS" apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="${2:?--days needs a value}"; shift 2 ;;
      --apply) apply=1; shift ;;
      -*) echo "usage: sweep.sh <owner/repo> [--days N] [--apply]" >&2; return 2 ;;
      *) repo="$1"; shift ;;
    esac
  done
  [[ -n "$repo" ]] || { echo "usage: sweep.sh <owner/repo> [--days N] [--apply]" >&2; return 2; }
  cs-sweep-days-check "$days" || return 2

  local list n labels timeline verdict closes=0 flags=0 now
  now=$(cs-sweep-now)
  list=$(cs-sweep-gh issue list --repo "$repo" --state open --label "$CS_L_DELIVERED" --json number,labels --limit 200)
  for n in $(jq -r '.[].number' <<<"$list"); do
    labels=$(jq -r --argjson n "$n" '.[] | select(.number==$n) | .labels[].name' <<<"$list")
    timeline=$(cs-sweep-timeline "$repo" "$n")
    verdict=$(cs-sweep-eval "$timeline" "$labels" "$now" "$days")
    case "$verdict" in
      CLOSE*)
        closes=$((closes + 1))
        if [[ "$apply" -eq 1 ]]; then
          bash "${CS_SWEEP_DIR}/transition.sh" autoclose "$repo" "$n" --days "$days" >/dev/null
          echo "#${n}: CLOSED (delivered ${verdict#CLOSE } ago)"
        else
          echo "#${n}: WOULD CLOSE (delivered ${verdict#CLOSE } ago)"
        fi
        ;;
      FLAG*) flags=$((flags + 1)); echo "#${n}: ${verdict}" ;;
      *) echo "#${n}: ${verdict}" ;;
    esac
  done
  if [[ "$apply" -eq 1 ]]; then
    echo "sweep: ${closes} closed, ${flags} flagged (days=${days})"
  else
    echo "sweep (dry-run, pass --apply to close): ${closes} would close, ${flags} flagged (days=${days})"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-sweep-main "$@"
fi
