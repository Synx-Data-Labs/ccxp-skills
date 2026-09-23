#!/usr/bin/env bash
#
# auto-pick.sh — walk-and-skip PR auto-pick for /address-pr §1 (T20260919-266165)
#
# Lists our own open PRs oldest-first and prints the JSON of the first one
# whose ownership verdict (task_claim.sh pr-owner) is `mine`, `free`, `new`,
# or `untracked` — the same set §1.6 already treats as "proceed". Any PR
# whose verdict is `owned:<other>` or `unknown` is skipped (never picked),
# and the walk continues to the next-oldest candidate instead of stopping at
# position 0 the way the old inline `sort_by(.createdAt) | .[0]` jq filter
# did.
#
# Prints nothing and exits 0 when there are no open PRs, or when every open
# PR is skipped — same observable "nothing to do" outcome as before, just
# reached only after checking every candidate. Diagnostic detail (which PRs
# were skipped and why) goes to stderr so stdout stays machine-parseable
# (one-line JSON object, or nothing).
#
# Usage:
#   bash auto-pick.sh
#
# Output (stdout): {"number":N,"title":"...","createdAt":"...","reason":"<verdict>"}
# or nothing if no PR is pickable.
#
set -euo pipefail

# Resolve sibling scripts relative to this script's own directory — same
# seam as address-pr/scripts/pre-merge-check.sh's GH_SH resolution.
# Overridable via env var for hermetic BATS tests (stub scripts).
GH_SH="${GH_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_gh" && pwd)/gh.sh}"
TASK_CLAIM_SH="${TASK_CLAIM_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_session" && pwd)/task_claim.sh}"

function auto-pick-main() {
  local prs_json
  prs_json="$(bash "$GH_SH" pr list --author @me --state open \
    --json number,title,createdAt --jq 'sort_by(.createdAt)' 2>/dev/null || true)"

  if [ -z "$prs_json" ] || [ "$prs_json" = "null" ] || [ "$prs_json" = "[]" ]; then
    return 0
  fi

  local pr number reason
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    number="$(jq -r '.number' <<<"$pr")"

    reason="$(bash "$TASK_CLAIM_SH" pr-owner "$number" 2>/dev/null || true)"

    case "$reason" in
      mine|free|new|untracked)
        jq -c --arg reason "$reason" '. + {reason: $reason}' <<<"$pr"
        return 0
        ;;
      *)
        # owned:<other>, unknown, or any unrecognized/empty verdict — fail-safe
        # skip, never pick. Continues the walk to the next-oldest candidate.
        printf 'auto-pick: skipping PR #%s (%s)\n' "$number" "${reason:-unknown}" >&2
        ;;
    esac
  done < <(jq -c '.[]' <<<"$prs_json")

  return 0
}

# Run only if executed directly (not sourced) — same convention as
# dev/guidelines.md's Script Standards.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto-pick-main "$@"
fi
