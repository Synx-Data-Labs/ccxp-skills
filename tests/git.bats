#!/usr/bin/env bats
# Tests for _gh/git.sh — the git wrapper sharing gh.sh's account-picking
# logic for git operations needing GitHub auth over HTTPS (T20260911-140914).
#
# Scope: main_git()'s own wiring — does it resolve the slug, pick an
# account, and exec git with GH_TOKEN reaching the child via environment
# and never via argv? The account-picking logic itself (_gh_pick_account,
# write-preference, fallback) is gh.sh's own and already fully covered by
# tests/gh.bats — not re-tested here.
#
# I/O is hermetic: a throwaway repo tree under $BATS_TEST_TMPDIR supplies
# the `origin` remote; a fake `gh` (tests/fixtures/gh/fake-gh.sh, reused
# from gh.bats) answers the account-picking probes; a fake `git`
# (tests/fixtures/git/fake-git.sh) records what main_git() actually execs
# into, delegating gh.sh's own internal `git remote get-url origin` call
# (made before main_git() ever execs) straight through to the real git.
# Both run as real subprocesses (`bash "$REPO_ROOT/_gh/git.sh" ...`), not
# sourced, since main_git() ends in `exec` — sourcing it into the bats
# process itself would replace the test runner.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_GIT="$(command -v git)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"
  git init -q .
  git remote add origin https://github.com/owner/repo.git

  # $FAKEBIN only goes on $PATH per-invocation inside each @test. The fake
  # `git` still needs to answer gh.sh's own internal `git remote get-url
  # origin` (called by _gh_repo_slug() before main_git() ever execs) — it
  # delegates that to $REAL_GIT and only intercepts the final wrapped call.
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/gh/fake-gh.sh" "$FAKEBIN/gh"
  cp "$REPO_ROOT/tests/fixtures/git/fake-git.sh" "$FAKEBIN/git"
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/git"

  CALLLOG="$BATS_TEST_TMPDIR/calllog"

  # _gh_cache_file is "${TMPDIR:-/tmp}/.gh-account-cache-${USER:-anon}" — a
  # FIXED path outside $BATS_TEST_TMPDIR unless TMPDIR/USER are overridden.
  # Without this, every test here would read and write the real machine's
  # actual gh.sh cache (shared with real, concurrent gh.sh/git.sh usage
  # elsewhere), not a hermetic per-test one — same isolation gh.bats' own
  # "main() self-heals..." test already applies for the same reason.
  export TMPDIR="$BATS_TEST_TMPDIR"
  export USER="bats-git-test"
}

@test "main_git execs git with GH_TOKEN in environment, never in argv" {
  PATH="$FAKEBIN:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FAKE_GH_ACCOUNTS="alice" \
    FAKE_GH_PERM="alice-token:true" \
    FAKE_GIT_CALLLOG="$CALLLOG" \
    run bash "$REPO_ROOT/_gh/git.sh" push -u origin some-branch

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]

  run grep '^ARGV: ' "$CALLLOG"
  [ "$status" -eq 0 ]
  # Only the caller's own args reach git — no GH_TOKEN=... anywhere in argv.
  [ "$output" = "ARGV: push -u origin some-branch" ]
  [[ "$output" != *GH_TOKEN* ]]

  run grep '^ENV_GH_TOKEN: ' "$CALLLOG"
  [ "$status" -eq 0 ]
  [ "$output" = "ENV_GH_TOKEN: alice-token" ]
}

@test "main_git picks the write-capable account, not an earlier-listed read-only one" {
  PATH="$FAKEBIN:$PATH" \
    REAL_GIT="$REAL_GIT" \
    FAKE_GH_ACCOUNTS="alice bob" \
    FAKE_GH_PERM="alice-token:false bob-token:true" \
    FAKE_GIT_CALLLOG="$CALLLOG" \
    run bash "$REPO_ROOT/_gh/git.sh" push origin main

  [ "$status" -eq 0 ]
  run grep '^ENV_GH_TOKEN: ' "$CALLLOG"
  [ "$output" = "ENV_GH_TOKEN: bob-token" ]
}

@test "git.sh source never reintroduces the exec-env argv-leak pattern" {
  # Regression guard for the exact bug this file's other tests exist to
  # cover functionally: `exec env GH_TOKEN=...` puts the token in env's own
  # argv (ps, /proc/<pid>/cmdline). Bash's prefix-assignment form
  # (`GH_TOKEN="$tok" exec git "$@"`) never does. A plain grep is enough to
  # catch a regression cheaply, no subprocess inspection needed.
  run grep -E 'exec[[:space:]]+env[[:space:]]+GH_TOKEN' "$REPO_ROOT/_gh/git.sh"
  [ "$status" -ne 0 ]
}
