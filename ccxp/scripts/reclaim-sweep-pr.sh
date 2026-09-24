#!/usr/bin/env bash
# reclaim-sweep-pr.sh
#
# ccxp Phase 0.5 (Dead task-claim reclaim sweep): frees task claims left by a
# CC session that died (crash / kill / reboot) before it could release them.
# The peer-mode lock (_session/task_claim.sh, build-pipeline-repo
# T20260611-104067) is heartbeat-free by design, so a claim whose owning
# session died is never released on its own — this sweep is the proactive
# backstop (on-demand reclaim in /todo next covers the pick path).
#
# Detects first (read-only, via _session/reclaim_sweep.sh with no --apply) so
# a clean board is a no-op: nothing branched, nothing committed. Only when
# there's something to reclaim does it branch off main, apply the sweep, run
# the doc-lint guard, commit, push, and open a PR — then return to main so
# the cron working tree is never left on a branch.
#
# Run from the repo root. No-op (prints nothing, exits 0) when
# CCXP_PEER_MODE=0 (the old one-session-per-clone global-hold opt-out).
#
# On stdout when it did work: the reclaimed-lines summary (for the caller to
# forward to #acme-dev-notifications — a reclaim is never silent) followed by
# the PR URL. Prints nothing when there was nothing to reclaim.
set -euo pipefail

# Resolve sibling scripts relative to this script's own directory — not a
# hardcoded ~/.claude/skills/... path, which only exists under the retired
# symlink-install layout (T20260914-871616). Overridable via SKILLS_ROOT for
# tests (same seam as _taskid/url.sh's TASKID_GH).
SKILLS_ROOT="${SKILLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [ "${CCXP_PEER_MODE:-1}" == "0" ]; then
  exit 0
fi

reclaimed=$(bash "$SKILLS_ROOT/_session/reclaim_sweep.sh" 2>/dev/null || true)
if [ -z "$reclaimed" ]; then
  exit 0
fi

branch_name="chore/reclaim-sweep-$(date +%Y%m%d-%H%M%S)"
restore_main() {
  git checkout main >/dev/null 2>&1 || true
}

trap restore_main EXIT
git checkout -b "$branch_name"
bash "$SKILLS_ROOT/_session/reclaim_sweep.sh" --apply >/dev/null   # free on the branch
bash "$SKILLS_ROOT/_docs/lint-docs.sh" --fix || true   # doc-lint guard — shared script (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
git add dev/TODO/*.md
git commit -m "chore(reclaim): free dead task-claims (ccxp Phase-0 sweep)" -m "$reclaimed"
git push -u origin HEAD
pr_url=$(bash "$SKILLS_ROOT/_gh/gh.sh" pr create --fill)
trap - EXIT
git checkout main   # never leave the cron working tree on a branch

echo "$reclaimed"
echo "$pr_url"
