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

# --- _gh_permission_error / _gh_invalidate_cache (pure unit tests) ---------

@test "_gh_permission_error matches a GraphQL collaborator error" {
  run _gh_permission_error "pull request create failed: GraphQL: must be a collaborator (createPullRequest)"
  [ "$status" -eq 0 ]
}

@test "_gh_permission_error matches an HTTP 403" {
  run _gh_permission_error "HTTP 403: Resource not accessible by personal access token"
  [ "$status" -eq 0 ]
}

@test "_gh_permission_error does not match an unrelated 404" {
  run _gh_permission_error "GraphQL: Could not resolve to a Repository with the name X (repository)"
  [ "$status" -ne 0 ]
}

@test "_gh_invalidate_cache drops only the matching (slug, user) line" {
  _gh_cache_file="$BATS_TEST_TMPDIR/cache"
  printf 'slugA\tuser1\nslugB\tuser2\n' > "$_gh_cache_file"
  _gh_invalidate_cache "slugA" "user1"
  run cat "$_gh_cache_file"
  [ "$output" = "slugB	user2" ]
}

# --- _gh_pick_account: write-aware picking (T20260911-140914) --------------
#
# Exercises the real _gh_pick_account() sourced above against a fake `gh`
# (fixtures/gh/fake-gh.sh) placed earlier on $PATH, so no real GitHub
# account or network call is involved.

_gh_bats_use_fake_gh() {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/gh/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  PATH="$FAKEBIN:$PATH"
  _gh_cache_file="$BATS_TEST_TMPDIR/cache"
  rm -f "$_gh_cache_file"
}

@test "_gh_pick_account prefers a write-capable account over an earlier-listed read-only one" {
  _gh_bats_use_fake_gh
  export FAKE_GH_ACCOUNTS="alice bob"
  export FAKE_GH_PERM="alice-token:false bob-token:true"

  run _gh_pick_account "owner/repo"
  [ "$status" -eq 0 ]
  [ "$output" = "bob" ]
  run cat "$_gh_cache_file"
  [ "$output" = "owner/repo	bob" ]
}

@test "_gh_pick_account falls back to a read-only account when none has write" {
  _gh_bats_use_fake_gh
  export FAKE_GH_ACCOUNTS="alice bob"
  export FAKE_GH_PERM="alice-token:false bob-token:false"

  run _gh_pick_account "owner/repo"
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "_gh_pick_account skips an account with no repo access at all" {
  _gh_bats_use_fake_gh
  export FAKE_GH_ACCOUNTS="alice bob"
  export FAKE_GH_PERM="bob-token:true"   # alice-token absent -> 404-shaped

  run _gh_pick_account "owner/repo"
  [ "$status" -eq 0 ]
  [ "$output" = "bob" ]
}

# --- main(): end-to-end self-heal on a stale cached pick -------------------
#
# These invoke gh.sh as a real subprocess (`bash "$REPO_ROOT/_gh/gh.sh" ...`)
# rather than sourcing, so main()'s full retry/cache-invalidation path runs.

@test "main() self-heals a stale read-only cached pick on a permission-shaped write failure" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/gh/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"

  # Must match _gh_cache_file's own computation ("${TMPDIR}/.gh-account-cache-${USER}")
  # under the TMPDIR/USER this subprocess is invoked with below.
  cache_file="$BATS_TEST_TMPDIR/.gh-account-cache-anon"
  printf 'owner/repo\talice\n' > "$cache_file"
  calllog="$BATS_TEST_TMPDIR/calllog"

  git remote add origin https://github.com/owner/repo.git

  PATH="$FAKEBIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" USER="anon" \
    FAKE_GH_ACCOUNTS="alice bob" \
    FAKE_GH_PERM="alice-token:false bob-token:true" \
    FAKE_GH_WRITE_OK="bob-token" \
    FAKE_GH_CALLLOG="$calllog" \
    run bash "$REPO_ROOT/_gh/gh.sh" pr create --title test

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  # Two write attempts logged: the stale (alice) failure, then the re-probed
  # (bob) success.
  [ "$(grep -c 'pr create' "$calllog")" -eq 2 ]
  grep -q 'GH_TOKEN=alice-token' "$calllog"
  grep -q 'GH_TOKEN=bob-token' "$calllog"
  # Cache now points at the write-capable account.
  run cat "$cache_file"
  [ "$output" = "owner/repo	bob" ]
}

@test "main() does not retry a failure that isn't permission-shaped" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/gh/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"

  calllog="$BATS_TEST_TMPDIR/calllog"
  git remote add origin https://github.com/owner/repo.git

  PATH="$FAKEBIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" USER="anon" \
    FAKE_GH_ACCOUNTS="alice" \
    FAKE_GH_PERM="alice-token:true" \
    FAKE_GH_GENERIC_FAIL="1" \
    FAKE_GH_CALLLOG="$calllog" \
    run bash "$REPO_ROOT/_gh/gh.sh" pr create --title test

  [ "$status" -eq 1 ]
  [ "$(grep -c 'pr create' "$calllog")" -eq 1 ]
}
