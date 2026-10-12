#!/usr/bin/env bash
# audit.sh — read-only invariant check for /customer-support audit
# (T20261012-373882). Checks "exactly one primary-state label, consistent
# with open/closed state" across open issues in a synxdb-support-shaped
# repo. Never writes anything — this is the mechanism that would have
# caught synxdb-support#20/#21/#24/#25/#27's real label gaps.
#
# Board-drift reporting against the Projects board is intentionally NOT
# implemented here: the Projects-board retirement is explicitly DEFERRED
# (T20261012-373882 design doc, pending a separate leadership decision) and
# this design does not depend on the board's fate either way.
#
# gh wrapper — DI seam via CS_GH, same convention as labels.sh.
set -euo pipefail

CS_PRIMARY_LABELS="triage accepted in-progress delivered"

CS_GH="${CS_GH:-}"
cs-audit-gh() {
  if [[ -n "$CS_GH" ]]; then
    "$CS_GH" "$@"
  else
    gh "$@"
  fi
}

# cs-audit-check <issues-json> — issues-json is an array of
# {"number": N, "labels": [{"name": "..."}]}, the same shape
# `gh issue list --json number,labels` prints. Prints one line per
# violation ("#N: <reason>"); exit 0 if clean, 1 if any violation found.
cs-audit-check() {
  local json="${1:?issues JSON required}"
  local violations=0
  local numbers n names count label
  numbers=$(echo "$json" | jq -r '.[].number')
  for n in $numbers; do
    names=$(echo "$json" | jq -r --argjson n "$n" '.[] | select(.number==$n) | .labels[].name')
    count=0
    local matched=""
    for label in $CS_PRIMARY_LABELS; do
      if grep -qxF "$label" <<<"$names"; then
        count=$((count + 1))
        matched="${matched:+$matched,}${label}"
      fi
    done
    if [[ "$count" -eq 0 ]]; then
      echo "#${n}: no primary-state label (expected exactly one of: ${CS_PRIMARY_LABELS// /, })"
      violations=$((violations + 1))
    elif [[ "$count" -gt 1 ]]; then
      echo "#${n}: multiple primary-state labels (${matched}) — invariant violated"
      violations=$((violations + 1))
    fi
  done
  [[ "$violations" -eq 0 ]]
}

# cs-audit-main <owner/repo> — fetches open issues and runs the check above.
cs-audit-main() {
  local repo="${1:?owner/repo required}" json
  json=$(cs-audit-gh issue list --repo "$repo" --state open --json number,labels --limit 200)
  cs-audit-check "$json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-audit-main "$@"
fi
