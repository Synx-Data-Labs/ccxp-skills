#!/usr/bin/env bats
# Tests for _gh/auto-switch.sh — the SessionStart hook that switches the
# active `gh auth` account to whichever one can see the current repo's
# `origin`, so a bare (unwrapped) `gh` call also lands on the right account.
#
# Scope: _auto_switch_org_repo() (URL -> owner/repo parsing) and
# _auto_switch_run()'s no-op paths, all exercised without any real `gh auth`
# calls — I/O is hermetic via a throwaway repo tree under $BATS_TEST_TMPDIR.
# The production function is exercised by sourcing the script (its CLI
# dispatch is BASH_SOURCE-guarded, so sourcing is side-effect-free).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"
  git init -q .

  source "$REPO_ROOT/_gh/auto-switch.sh"
}

# --- URL parsing -------------------------------------------------------------

@test "ssh origin resolves to owner/repo" {
  run _auto_switch_org_repo 'git@github.com:acme/widgets.git'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "https + .git origin resolves to owner/repo" {
  run _auto_switch_org_repo 'https://github.com/acme/widgets.git'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "https origin without .git suffix resolves" {
  run _auto_switch_org_repo 'https://github.com/acme/widgets'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "dotted repo name resolves" {
  run _auto_switch_org_repo 'git@github.com:me/a.b.c.git'
  [ "$status" -eq 0 ]
  [ "$output" = "me/a.b.c" ]
}

# --- no-op paths (never reach a real `gh` call) ------------------------------

@test "non-git directory is a no-op that exits 0" {
  cd "$BATS_TEST_TMPDIR"
  run _auto_switch_run
  [ "$status" -eq 0 ]
}

@test "git repo with no origin remote is a no-op that exits 0" {
  run _auto_switch_run
  [ "$status" -eq 0 ]
}
