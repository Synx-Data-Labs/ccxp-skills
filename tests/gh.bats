#!/usr/bin/env bats
# Tests for _gh/gh.sh — the gh wrapper that picks the authenticated account
# with access to the current repo (T20260819-381973).
#
# Scope: _gh_repo_slug() only — parses an `origin` remote URL into an
# `owner/repo` slug. It must handle any host in git@<host>:owner/repo(.git)
# or https://<host>/owner/repo(.git) form, not just literal github.com, so
# repos cloned via a custom SSH host alias (the standard multi-account setup,
# e.g. `~/.ssh/config`'s `Host github-<alias>` -> `HostName github.com`)
# still resolve. I/O is hermetic: a throwaway repo tree under
# $BATS_TEST_TMPDIR supplies the `origin` remote; the production function is
# exercised by sourcing the script (its CLI dispatch is BASH_SOURCE-guarded,
# so sourcing is side-effect-free).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"
  git init -q .

  source "$REPO_ROOT/_gh/gh.sh"
}

# --- the bug: SSH host alias origins ----------------------------------------

@test "SSH host alias origin resolves to owner/repo" {
  git remote add origin git@github-personal:someuser/somerepo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "someuser/somerepo" ]
}

@test "SSH host alias origin without .git suffix still resolves" {
  git remote add origin git@github-work:acme/widgets
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

# --- existing-shape regression ----------------------------------------------

@test "plain github.com SSH origin still resolves (regression)" {
  git remote add origin git@github.com:owner/repo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

@test "plain github.com HTTPS origin still resolves (regression)" {
  git remote add origin https://github.com/owner/repo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

@test "HTTPS origin without .git suffix still resolves" {
  git remote add origin https://github.com/owner/repo
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

# --- other schemes (git://, explicit ssh://) --------------------------------

@test "git:// origin resolves to owner/repo" {
  git remote add origin git://github.com/owner/repo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

@test "explicit ssh:// origin (no user@) resolves to owner/repo" {
  git remote add origin ssh://github.com/owner/repo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

@test "explicit ssh:// origin with user@ and port resolves to owner/repo" {
  git remote add origin ssh://git@github.com:22/owner/repo.git
  run _gh_repo_slug
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

# --- no remote ---------------------------------------------------------------

@test "no origin remote -> non-zero exit" {
  run _gh_repo_slug
  [ "$status" -ne 0 ]
}
