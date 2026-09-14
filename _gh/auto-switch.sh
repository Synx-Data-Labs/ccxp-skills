#!/usr/bin/env bash
# _gh/auto-switch.sh — pick the `gh` account with access to the current repo.
#
# Wired as a SessionStart hook in ~/.claude/settings.json (see README.md's
# "Shared helpers" section for the exact snippet). On a machine with
# multiple `gh auth` accounts configured, the *active* account can drift —
# e.g. a different repo was open last session and left a different account
# selected. If anything then shells out to a BARE `gh` command (not routed
# through `_gh/gh.sh` — e.g. a Bash-tool call running `gh pr view` directly,
# or a human typing `gh` in the terminal), it runs against whatever account
# is globally active, which may not see the current repo. Everything 404s.
#
# This is a fallback tier, not a replacement for `_gh/gh.sh`: `gh.sh` is the
# preferred integration for any script that can be written to call it
# (process-scoped `GH_TOKEN`, no global mutation — see its own header
# comment). This hook instead mutates the actual global `gh auth switch`
# selection, on purpose, because that's the only lever available to fix a
# *bare*, unwrapped `gh` call made by something outside this repo's scripts.
#
# Exits 0 in all cases — never block session start.
#   - Not a git repo: no-op.
#   - Active account already sees the repo: no-op.
#   - Switched: stays switched for the rest of the session.
#   - All accounts 404: no-op (leaves whatever was active).
#
# Testing: bats tests/auto-switch.bats

# -e deliberately omitted, same rationale as _gh/gh.sh: sourcing a `set -e`
# script pollutes the CALLER's shell options too, which would abort a test
# shell that sources this file to exercise _auto_switch_org_repo() on its
# next unrelated failing command.
set -uo pipefail

_auto_switch_org_repo() {
  # $1 origin remote URL -> "owner/repo", or empty if unparseable.
  printf '%s\n' "$1" \
    | sed -E 's#[.]git$##' \
    | awk -F'[/:]' '{print $(NF-1)"/"$NF}'
}

_auto_switch_list_accounts() {
  # Parse `gh auth status` for "Logged in to github.com account <name> (...)".
  # The status output is on stderr in some gh versions, hence 2>&1.
  gh auth status 2>&1 | awk '
    /Logged in to github.com account/ {
      for (i = 1; i <= NF; i++) if ($i == "account") { print $(i + 1); break }
    }'
}

_auto_switch_run() {
  local origin org_repo user
  origin=$(git -C "$PWD" config --get remote.origin.url 2>/dev/null) || return 0
  [ -z "$origin" ] && return 0

  org_repo=$(_auto_switch_org_repo "$origin")
  [ -z "$org_repo" ] || [ "$org_repo" = "/" ] && return 0

  # Already works? Done.
  gh api "repos/$org_repo" --silent 2>/dev/null && return 0

  # Try each configured account until one can see the repo.
  while read -r user; do
    [ -z "$user" ] && continue
    gh auth switch --user "$user" >/dev/null 2>&1 || continue
    gh api "repos/$org_repo" --silent 2>/dev/null && return 0
  done < <(_auto_switch_list_accounts)

  return 0
}

# Run only if executed directly (not sourced) — lets tests source this file
# and call individual functions (e.g. _auto_switch_org_repo) without
# invoking the hook itself.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _auto_switch_run
fi
