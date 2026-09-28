#!/usr/bin/env bash
# update-roadmap.sh clone
# update-roadmap.sh commit-pr --target DIR --bp-pr-url URL
#
# ccxp Phase 2a.5b (Update the ROADMAP doc in a cross-repo hub, cross-repo):
# propagates this week's IPM commit into a multi-IPM ROADMAP doc
# (`dev/ROADMAP.md`) living in a separate hub repo (T20260510-836314), via an
# ephemeral clone — same pattern as /drive Phase 1.5 cross-repo dispatch
# (T20260513-403409). The ccxp run never touches the maintainer's working
# clone of that hub repo.
#
# The hub repo is required config, not a hardcoded default — set
# ROADMAP_TARGET_REPO="<owner>/<repo>" (already-exported env wins; otherwise
# resolved from ~/.claude/.env, machine-global, same convention as
# vpn/scripts/vpn.sh's load_vpn_env and _session/_lib.sh's
# _session_load_env). Each adopting team supplies its own value
# (T20260827-280088 — no company/repo name baked into this script).
#
# Split into two subcommands because the actual ROADMAP.md content edits
# (promote this week's commitments, demote cuts, advance "Last updated",
# archive shipped entries — Phase 2a.5b steps 1-4) are a judgment call made
# by the agent editing the file directly, not scriptable. `clone` sets up the
# ephemeral worktree and prints its path; the caller edits dev/ROADMAP.md
# there; `commit-pr` lints, commits, pushes, and opens the PR, then removes
# the ephemeral clone.
#
# clone:
#   Clones ROADMAP_TARGET_REPO into a fresh /tmp directory on a dated
#   roadmap/ipm-* branch. Prints the clone's path on stdout — cd into it
#   before editing dev/ROADMAP.md (creating it from the template first if it
#   doesn't exist yet, per the task file's "Initial content shape" section).
#
# commit-pr:
#   Run from anywhere once dev/ROADMAP.md has been edited in --target. Runs
#   the doc-lint guard, commits, pushes, opens the PR against
#   ROADMAP_TARGET_REPO, and removes the ephemeral clone. --bp-pr-url is the
#   IPM commit PR in the repo that produced this week's IPM file, linked in
#   the PR body.
#
# On any step failure, report to the maintainer per the skill's escalation
# protocol — the IPM file in the source repo is already committed
# regardless, so a failure here can be retried later via a re-run of just
# this phase.
set -euo pipefail

# Resolve sibling scripts relative to this script's own directory — not a
# hardcoded ~/.claude/skills/... path, which only exists under the retired
# symlink-install layout (T20260914-871616). Resolved before any `cd`, since
# roadmap_commit_pr below cds into an ephemeral cross-repo clone.
# Overridable via SKILLS_ROOT for tests (same seam as _taskid/url.sh's
# TASKID_GH).
SKILLS_ROOT="${SKILLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

ROADMAP_TARGET_REPO="${ROADMAP_TARGET_REPO:-}"

# Load ROADMAP_TARGET_REPO from ~/.claude/.env (machine-global) when not
# already exported — same resolution order and ENV_FILE test seam as
# _session/_lib.sh's _session_load_env and vpn/scripts/vpn.sh's
# load_vpn_env. Skipped in BATS to keep tests hermetic.
#
# Both `source` calls below are `|| true`-guarded: this file is a shared,
# hand-edited, machine-global env file carrying many unrelated vars
# (VPN_*, RETRO_SLACK_CHANNEL, METRICS_OWNER/REPOS, ...) — if its last
# executed line/assignment ever fails, `source` itself returns non-zero,
# and under set -e that's the *final* command of its if-body (not exempt
# the way a non-final command in a && list is), which would silently abort
# this whole script with zero output before ROADMAP_TARGET_REPO is even
# checked. A degrade-to-unset (→ _require_roadmap_target_repo's clear
# error) is the correct behavior for a bad shared file, not a silent
# crash (PR #238 review).
_update_roadmap_load_env() {
  [ -n "$ROADMAP_TARGET_REPO" ] && return 0
  if [ -n "${ENV_FILE:-}" ]; then
    [ -f "$ENV_FILE" ] && { # shellcheck disable=SC1090
      source "$ENV_FILE" || true; }
    return 0
  fi
  [ -n "${BATS_TEST_TMPDIR:-}" ] && return 0
  # Explicit if/fi, not the `[ ... ] && { ...; }` shape used above — as the
  # terminal statement of this function (no `return 0` follows), a missing
  # file here would make the function itself return non-zero, and under
  # set -e that silently aborts the whole script (same hazard as the
  # `|| true` above, different mechanism — verified). Matches
  # vpn/scripts/vpn.sh's load_vpn_env, which uses this same explicit form
  # for exactly this reason.
  if [ -f "$HOME/.claude/.env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.claude/.env" || true
  fi
}
_update_roadmap_load_env
ROADMAP_TARGET_REPO="${ROADMAP_TARGET_REPO:-}"

_require_roadmap_target_repo() {
  if [ -z "$ROADMAP_TARGET_REPO" ]; then
    echo "update-roadmap.sh: ROADMAP_TARGET_REPO is not set (checked \$ENV_FILE, ~/.claude/.env) — set it to the <owner>/<repo> of the hub repo whose dev/ROADMAP.md should be updated" >&2
    return 1
  fi
}

roadmap_clone() {
  _require_roadmap_target_repo || return 1
  local target
  target="/tmp/ccxp-ipm-$(date +%Y-%m-%d)-roadmap-update"
  rm -rf "$target"
  git clone --depth=20 "git@github.com:${ROADMAP_TARGET_REPO}.git" "$target"
  (cd "$target" && git checkout -b "roadmap/ipm-$(date +%Y-%m-%d)")
  echo "$target"
}

roadmap_commit_pr() {
  _require_roadmap_target_repo || return 1
  # target is not `local` — the EXIT trap below fires after this function
  # returns, by which point a local's binding is already gone (set -u would
  # then reject the trap's own "$target" reference as unbound). bp_pr_url
  # isn't read by the trap, so it stays local.
  target=""
  local bp_pr_url="<link>"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --bp-pr-url) bp_pr_url="$2"; shift 2 ;;
      *) echo "update-roadmap commit-pr: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$target" ]; then
    echo "update-roadmap commit-pr: --target DIR is required" >&2
    return 2
  fi

  trap 'rm -rf "$target"' EXIT
  cd "$target" || return 1
  bash "$SKILLS_ROOT/_docs/lint-docs.sh" --fix || true   # doc-lint guard — shared script, runs for real here too now (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
  git add dev/ROADMAP.md
  git commit -m "docs(roadmap): IPM commit $(date +%Y-%m-%d) — promotions, demotions, last-updated tick"
  local branch
  branch=$(git branch --show-current)
  git push -u origin "$branch"
  bash "$SKILLS_ROOT/_gh/gh.sh" pr create --repo "$ROADMAP_TARGET_REPO" \
    --title "docs(roadmap): IPM commit $(date +%Y-%m-%d)" \
    --body "Auto-generated by ccxp Phase 2a.5b. Mirrors this week's IPM commit (${bp_pr_url}) into the multi-IPM ROADMAP."
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    clone) roadmap_clone "$@" ;;
    commit-pr) roadmap_commit_pr "$@" ;;
    *) echo "Usage: update-roadmap.sh clone | commit-pr --target DIR --bp-pr-url URL" >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced) — lets tests source this file
# and call individual functions (e.g. _update_roadmap_load_env) without
# invoking main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
