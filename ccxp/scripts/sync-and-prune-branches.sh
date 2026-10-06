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
#   --skills-dir DIR   Path to the shared skills repo clone (default: this
#                       script's own containing repo — see below).
set -euo pipefail

# Default: the shared ccxp-skills checkout containing this very script.
# This script physically lives at <ccxp-skills>/ccxp/scripts/, so two levels
# up from its own directory ($BASH_SOURCE) is always the repo root —
# regardless of $HOME, how this repo was installed (plain clone, plugin
# cache, cron box, interactive clone), or whether ~/.claude/skills exists or
# points somewhere unrelated (T20260925-159860).
skills_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --skills-dir) skills_dir="$2"; shift 2 ;;
    *) echo "sync-and-prune-branches: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Guard: whichever way skills_dir was resolved (default or explicit flag),
# verify it actually looks like the ccxp-skills checkout before touching it
# with `git checkout`/`git pull` — fail loudly with a clear message instead
# of a confusing raw git error (T20260925-159860).
skills_remote="$(git -C "$skills_dir" remote get-url origin 2>/dev/null || true)"
if ! [[ "$skills_remote" =~ /ccxp-skills(\.git)?$ ]]; then
  echo "sync-and-prune-branches: '$skills_dir' doesn't look like the ccxp-skills checkout (origin remote: ${skills_remote:-<none/not a git repo>}) — pass --skills-dir explicitly." >&2
  exit 1
fi

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
