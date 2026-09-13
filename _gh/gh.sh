#!/usr/bin/env bash
# _gh/gh.sh — gh wrapper that picks the authenticated account with access to this repo.
#
# Usage (drop-in for `gh`):
#   bash ~/.claude/skills/_gh/gh.sh pr list --state merged
#   bash ~/.claude/skills/_gh/gh.sh api repos/OWNER/REPO --jq .default_branch
#
# Why: machines with multiple gh-authenticated accounts (e.g. personal + work)
# can't use plain `gh` reliably — it always uses the *active* account, which
# may not have access to the repo. Setting `GITHUB_TOKEN=""` (the previous
# convention) only forces gh to use the keyring, but still defers to whatever
# account `gh auth switch` last selected — global mutable state shared across
# every shell and Claude Code session on the box.
#
# This wrapper probes each authenticated account (read from `gh auth status`)
# until one can read the repo at $PWD's `origin`, then runs `gh "$@"` with
# that account's token via `GH_TOKEN=...` (process-scoped, no global mutation).
# The (repo, account) pick is cached for the rest of the script's lifetime.

# -e deliberately omitted (matches every other sourceable script in this repo,
# e.g. _session/task_claim.sh): sourcing a `set -e` script pollutes the
# CALLER's shell options too (source runs in the same shell, not a
# subshell), which would abort a test shell that sources this file to
# exercise individual functions (e.g. _gh_repo_slug) on its next unrelated
# failing command. main()'s own fallible calls are already explicitly
# checked (`|| _gh_die ...` / `|| continue`) so this doesn't change their
# behavior; the two spots that aren't explicitly checked change in a
# strictly safer direction without -e: _gh_list_accounts' pipeline behaves
# the same either way (a `for x in $(...)` isn't -e-checked regardless),
# and the account-cache append (already documented above as best-effort,
# "duplicate lines are harmless") no longer aborts the whole command on a
# failed write — it did before, which was worse: a non-essential cache
# write failing shouldn't block returning an already-found valid account.
set -uo pipefail

_gh_die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }

_gh_repo_slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  # Strip the host generically rather than hardcoding "github.com" — a repo
  # cloned via a custom SSH host alias (the standard way to disambiguate
  # multiple gh accounts, e.g. `~/.ssh/config`'s `Host github-<alias>` ->
  # `HostName github.com`) has an origin like `git@github-<alias>:owner/repo.git`,
  # which the old literal-host match couldn't parse (T20260819-381973).
  # Two prefix shapes, tried in order:
  #   1. any scheme (https, http, git, ssh, ...), optional user@, host[:port]/
  #   2. scp-style git@host:owner/repo (no scheme)
  # Rule 1 only fires on a leading "scheme://", so it never misfires on rule
  # 2's shape, and vice versa.
  printf '%s' "$url" | sed -E \
    -e 's|^[a-z]+://([^@/]+@)?[^/]+/||' \
    -e 's|^[^/:]+@[^:]+:||' \
    -e 's|\.git$||'
}

_gh_list_accounts() {
  # Parse `gh auth status` for "Logged in to github.com account <name> (...)".
  # The status output is on stderr in some gh versions, hence 2>&1.
  gh auth status 2>&1 | awk '
    /Logged in to github.com account/ {
      for (i = 1; i <= NF; i++) if ($i == "account") { print $(i + 1); break }
    }'
}

_gh_token_for() {
  gh auth token --user "$1" 2>/dev/null
}

_gh_cache_file="${TMPDIR:-/tmp}/.gh-account-cache-${USER:-anon}"

_gh_pick_account() {
  local slug="$1" cached user
  if [[ -f "$_gh_cache_file" ]]; then
    cached="$(awk -v s="$slug" -F'\t' '$1 == s { print $2; exit }' "$_gh_cache_file")"
    if [[ -n "$cached" ]] && _gh_token_for "$cached" >/dev/null; then
      printf '%s' "$cached"
      return 0
    fi
  fi
  for user in $(_gh_list_accounts); do
    local tok
    tok="$(_gh_token_for "$user")" || continue
    if GH_TOKEN="$tok" gh repo view "$slug" >/dev/null 2>&1; then
      # Append; future runs read first match. No locking — duplicate lines are harmless.
      printf '%s\t%s\n' "$slug" "$user" >> "$_gh_cache_file"
      printf '%s' "$user"
      return 0
    fi
  done
  return 1
}

main() {
  local slug user tok
  slug="$(_gh_repo_slug)" || _gh_die "no github 'origin' remote in $PWD"
  [[ -n "$slug" && "$slug" == */* ]] || _gh_die "could not parse owner/repo from origin URL"
  user="$(_gh_pick_account "$slug")" \
    || _gh_die "no authenticated gh account has access to $slug (try: gh auth login)"
  tok="$(_gh_token_for "$user")" || _gh_die "could not read token for account $user"
  exec env GH_TOKEN="$tok" gh "$@"
}

# Run only if executed directly (not sourced) — lets tests source this file
# and call individual functions (e.g. _gh_repo_slug) without invoking main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
