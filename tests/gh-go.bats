#!/usr/bin/env bats
# Tests for the opt-in Go counterpart of _gh/gh.sh / _gh/git.sh
# (T20261020-231370): the shim in the bash wrappers (CCXP_GH_GO=1) and the
# compiled binary itself, black-box, against the shared fake gh/git fixtures.
#
# The awk/locale regression tests in gh.bats/gh-wrapper-usage.bats are moot for
# the Go path: it reads `gh auth status --json hosts`, so no awk and no locale
# dependence exist to regress. Logic-level coverage lives in _gh/go/*_test.go.
#
# Binary tests are skipped when `go` is absent (CI's bats job has no setup-go
# today, so they run locally and wherever Go is installed).

load test_helper

setup_file() {
  if command -v go >/dev/null 2>&1; then
    export GH_GO_BIN="$BATS_FILE_TMPDIR/ccxp-gh"
    bash "$REPO_ROOT/_gh/go/build.sh" "$GH_GO_BIN" >/dev/null
  fi
}

setup() {
  REAL_GIT="$(command -v git)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"
  git init -q .
  git remote add origin https://github.com/owner/repo.git
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/gh/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  CALLLOG="$BATS_TEST_TMPDIR/calllog"
  export TMPDIR="$BATS_TEST_TMPDIR" USER="bats-go-test"
}

need_go() { [ -n "${GH_GO_BIN:-}" ] || skip "go not installed"; }

# fake git: intercepts only the final wrapped call (see fake-git.sh contract)
use_fake_git() {
  cp "$REPO_ROOT/tests/fixtures/git/fake-git.sh" "$FAKEBIN/git"
  chmod +x "$FAKEBIN/git"
}

# --- shim -------------------------------------------------------------------

@test "switch off: bash path runs even when a binary exists" {
  printf '#!/bin/sh\necho GO-BINARY\n' > "$BATS_TEST_TMPDIR/fake-bin"
  chmod +x "$BATS_TEST_TMPDIR/fake-bin"
  PATH="$FAKEBIN:$PATH" CCXP_GH_BIN="$BATS_TEST_TMPDIR/fake-bin" \
    FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" FAKE_GH_WRITE_OK="alice-token" \
    run bash "$REPO_ROOT/_gh/gh.sh" pr list
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "switch on + binary present: wrapper execs it with mode and args" {
  printf '#!/bin/sh\necho "GO-BINARY $*"\n' > "$BATS_TEST_TMPDIR/fake-bin"
  chmod +x "$BATS_TEST_TMPDIR/fake-bin"
  CCXP_GH_GO=1 CCXP_GH_BIN="$BATS_TEST_TMPDIR/fake-bin" run bash "$REPO_ROOT/_gh/gh.sh" pr list --state open
  [ "$output" = "GO-BINARY gh pr list --state open" ]
  CCXP_GH_GO=1 CCXP_GH_BIN="$BATS_TEST_TMPDIR/fake-bin" run bash "$REPO_ROOT/_gh/git.sh" push origin x
  [ "$output" = "GO-BINARY git push origin x" ]
}

@test "switch on + binary missing: falls back to bash silently" {
  PATH="$FAKEBIN:$PATH" CCXP_GH_GO=1 CCXP_GH_BIN="$BATS_TEST_TMPDIR/nope" \
    FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" FAKE_GH_WRITE_OK="alice-token" \
    run bash "$REPO_ROOT/_gh/gh.sh" pr list
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "switch on + binary missing + CCXP_GH_DEBUG=1: one stderr note, still works" {
  PATH="$FAKEBIN:$PATH" CCXP_GH_GO=1 CCXP_GH_DEBUG=1 CCXP_GH_BIN="$BATS_TEST_TMPDIR/nope" \
    FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" FAKE_GH_WRITE_OK="alice-token" \
    run bash "$REPO_ROOT/_gh/gh.sh" pr list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no binary at"* ]]
  [[ "$output" == *"ok" ]]
}

@test "_session_gh reaches the Go path under CCXP_GH_GO=1" {
  printf '#!/bin/sh\necho "GO-BINARY $*"\n' > "$BATS_TEST_TMPDIR/fake-bin"
  chmod +x "$BATS_TEST_TMPDIR/fake-bin"
  CCXP_GH_GO=1 CCXP_GH_BIN="$BATS_TEST_TMPDIR/fake-bin" \
    run bash -c "source '$REPO_ROOT/_session/_lib.sh'; _session_gh api user"
  [ "$output" = "GO-BINARY gh api user" ]
}

# --- binary: gh mode ----------------------------------------------------------

@test "go gh: picks the write-capable account and passes args through" {
  need_go
  PATH="$FAKEBIN:$PATH" FAKE_GH_ACCOUNTS="alice bob" FAKE_GH_PERM="alice-token:false bob-token:true" \
    FAKE_GH_WRITE_OK="bob-token" FAKE_GH_CALLLOG="$CALLLOG" \
    run "$GH_GO_BIN" gh pr create --title t
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  grep -q 'pr create --title t | GH_TOKEN=bob-token' "$CALLLOG"
}

@test "go gh: self-heals a stale cached read-only pick" {
  need_go
  printf 'owner/repo\talice\n' > "$BATS_TEST_TMPDIR/.gh-account-cache-bats-go-test"
  PATH="$FAKEBIN:$PATH" FAKE_GH_ACCOUNTS="alice bob" FAKE_GH_PERM="alice-token:false bob-token:true" \
    FAKE_GH_WRITE_OK="bob-token" FAKE_GH_CALLLOG="$CALLLOG" \
    run "$GH_GO_BIN" gh pr create --title t
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  [ "$(grep -c 'pr create' "$CALLLOG")" -eq 2 ]
  run cat "$BATS_TEST_TMPDIR/.gh-account-cache-bats-go-test"
  [ "$output" = "owner/repo	bob" ]
}

@test "go gh: does not retry a non-permission failure; exit code preserved" {
  need_go
  PATH="$FAKEBIN:$PATH" FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" \
    FAKE_GH_GENERIC_FAIL=1 FAKE_GH_CALLLOG="$CALLLOG" \
    run "$GH_GO_BIN" gh pr view 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 500"* ]]
  [ "$(grep -c 'pr view' "$CALLLOG")" -eq 1 ]
}

@test "go gh: no account with access -> same error message as the bash wrapper" {
  need_go
  PATH="$FAKEBIN:$PATH" FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="" \
    run "$GH_GO_BIN" gh api repos/owner/repo
  [ "$status" -eq 1 ]
  [ "$output" = "gh.sh: no authenticated gh account has access to owner/repo (try: gh auth login)" ]
}

@test "go gh: no origin remote -> same error message" {
  need_go
  git remote remove origin
  PATH="$FAKEBIN:$PATH" run "$GH_GO_BIN" gh pr list
  [ "$status" -eq 1 ]
  [ "$output" = "gh.sh: no github 'origin' remote in $PWD" ]
}

@test "go gh: old gh without --json -> clear upgrade error, not 'no access'" {
  need_go
  PATH="$FAKEBIN:$PATH" FAKE_GH_ACCOUNTS="alice" FAKE_GH_NO_JSON=1 run "$GH_GO_BIN" gh pr list
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not support"* ]]
}

@test "go gh: awk/locale independence — works with a broken awk on PATH and LC_ALL=C" {
  need_go
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/awk"; chmod +x "$FAKEBIN/awk"
  PATH="$FAKEBIN:$PATH" LC_ALL=C FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" \
    FAKE_GH_WRITE_OK="alice-token" run "$GH_GO_BIN" gh pr list
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- binary: git mode ---------------------------------------------------------

@test "go git: execs git with GH_TOKEN in env, never argv" {
  need_go
  use_fake_git
  PATH="$FAKEBIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_GH_ACCOUNTS="alice bob" \
    FAKE_GH_PERM="alice-token:false bob-token:true" FAKE_GIT_CALLLOG="$CALLLOG" \
    run "$GH_GO_BIN" git push -u origin some-branch
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run grep '^ARGV: ' "$CALLLOG"
  [ "$output" = "ARGV: push -u origin some-branch" ]
  run grep '^ENV_GH_TOKEN: ' "$CALLLOG"
  [ "$output" = "ENV_GH_TOKEN: bob-token" ]
}

@test "go git: wires repo-local credential helper and insteadOf" {
  need_go
  use_fake_git
  PATH="$FAKEBIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" \
    FAKE_GIT_CALLLOG="$CALLLOG" run "$GH_GO_BIN" git fetch origin
  [ "$status" -eq 0 ]
  run git config --local --get-all credential.helper
  [[ "$output" == *"!gh auth git-credential"* ]]
  run git config --local --get-all 'url.https://github.com/.insteadOf'
  [[ "$output" == *"git@github.com:"* ]]
  # idempotent: second run leaves exactly one helper entry
  PATH="$FAKEBIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_GH_ACCOUNTS="alice" FAKE_GH_PERM="alice-token:true" \
    FAKE_GIT_CALLLOG="$CALLLOG" run "$GH_GO_BIN" git fetch origin
  [ "$(git config --local --get-all credential.helper | grep -c 'gh auth git-credential')" -eq 1 ]
}

@test "go: usage error on bad mode" {
  need_go
  run "$GH_GO_BIN" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}
