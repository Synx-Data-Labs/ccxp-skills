#!/usr/bin/env bash
# sync-and-prune-branches.sh [--skills-dir DIR]
#
# ccxp Phase 0 (Sync): fast-forwards the working repo and the shared skills
# repo to origin/main, then deletes local branches whose remote tracking ref
# is gone (PRs already merged + remote branch auto-deleted by
# `gh pr merge --delete-branch`). Inlines the /cleanup-branches workflow so
# the cron-driven ccxp run stays self-contained — no nested skill dispatch.
#
# Run from the working repo's root. Does NOT touch sibling product repos —
# that's /drive Phase 1.5's job (just-in-time refresh of the target repo,
# gated on safety checks).
#
# If the worktree has uncommitted changes, or `git pull --ff-only` fails
# (diverged history), this exits non-zero without force-resetting — the
# caller is expected to report and decide, not silently override.
#
# Options:
#   --skills-dir DIR   Path to the shared skills repo clone (default: ~/.claude/skills).
set -euo pipefail

skills_dir="${HOME}/.claude/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --skills-dir) skills_dir="$2"; shift 2 ;;
    *) echo "sync-and-prune-branches: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# 1. Refresh the project repo: prune dead remote refs, fast-forward main
git fetch --prune --tags
git checkout main
git pull --ff-only

# 2. Refresh the shared skills repo (same pattern)
git -C "$skills_dir" fetch --prune --tags
git -C "$skills_dir" checkout main
git -C "$skills_dir" pull --ff-only

# 3. Delete local branches whose remote tracking ref is gone
CURRENT=$(git branch --show-current)
DEFAULT=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
STALE=$(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
  | awk '$2 == "[gone]" {print $1}' \
  | grep -Fxv "${DEFAULT:-main}" | grep -Fxv "${CURRENT:-main}" || true)
if [ -n "$STALE" ]; then
  echo "$STALE" | while read -r branch; do
    [ -n "$branch" ] && git branch -D "$branch"
  done
  echo "Phase 0: deleted $(echo "$STALE" | wc -l | tr -d ' ') stale local branches."
else
  echo "Phase 0: no stale local branches to delete."
fi
