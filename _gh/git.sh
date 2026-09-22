#!/usr/bin/env bash
# _gh/git.sh — git wrapper that authenticates as the gh account with access
# to the current repo, for git operations that need GitHub auth over HTTPS
# (push, most commonly).
#
# Usage (drop-in for `git`):
#   bash git.sh push -u origin <branch>
#   bash git.sh fetch origin
#
# Why a separate wrapper from gh.sh: `git push` isn't a `gh` subcommand, but
# on a repo whose `credential.helper` routes through `gh auth git-credential`
# (the default `gh auth setup-git` leaves, and what `_gh/auto-switch.sh`
# wires per-repo), that credential helper honors a process-scoped `GH_TOKEN`
# override exactly like the `gh` CLI itself does — so the same account-
# picking machinery applies. This retires the ad-hoc pattern of manually
# running `GH_TOKEN="$(gh auth token --user <name>)" git push ...` with a
# hardcoded account name; this wrapper auto-detects the right account the
# same way gh.sh does (T20260911-140914).
#
# Shares its account-picking logic with gh.sh by sourcing it — gh.sh's own
# `main()` is BASH_SOURCE-guarded, so sourcing it is side-effect-free (see
# its own header comment).

set -uo pipefail

_gh_git_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gh.sh
source "$_gh_git_dir/gh.sh"

main_git() {
  local slug user tok
  slug="$(_gh_repo_slug)" || _gh_die "no github 'origin' remote in $PWD"
  [[ -n "$slug" && "$slug" == */* ]] || _gh_die "could not parse owner/repo from origin URL"
  user="$(_gh_pick_account "$slug")" \
    || _gh_die "no authenticated gh account has access to $slug (try: gh auth login)"
  tok="$(_gh_token_for "$user")" || _gh_die "could not read token for account $user"
  GH_TOKEN="$tok" exec git "$@"
}

# Run only if executed directly (not sourced) — same convention as gh.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_git "$@"
fi
