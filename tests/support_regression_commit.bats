#!/usr/bin/env bats
# Tests for _support/check-regression-commit.sh (T20261012-109735).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  C="$REPO_ROOT/_support/check-regression-commit.sh"
  unset SUPPORT_E2E_GLOB
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R" && cd "$R"
  git init -q -b main . && git config user.email t@e.x && git config user.name t
  mkdir -p src tests/e2e dev/TODO
  echo base > src/a.sh && git add -A && git commit -qm base
  git checkout -q -b fix
}

commit() { git add -A && git commit -q -m "$1"; }

@test "fix and e2e test in the same commit passes" {
  echo v2 > src/a.sh; echo t > tests/e2e/a_test.sh
  commit "fix: a"
  run bash "$C" main..HEAD
  [ "$status" -eq 0 ]
}

@test "fix commit without a test fails closed (exit 1) and names the commit" {
  echo v2 > src/a.sh; commit "fix: a"
  run bash "$C" main..HEAD
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/a.sh"* ]]
}

@test "test added in a LATER commit still fails (same-commit rule)" {
  echo v2 > src/a.sh; commit "fix: a"
  echo t > tests/e2e/a_test.sh; commit "test: a"
  run bash "$C" main..HEAD
  [ "$status" -eq 1 ]
}

@test "docs-only and task-file-only commits pass" {
  echo x > dev/TODO/T1.md; echo y > README.md
  commit "docs: claim"
  run bash "$C" main..HEAD
  [ "$status" -eq 0 ]
}

@test "No-regression-test trailer exempts the commit and warns" {
  echo v2 > src/a.sh
  git add -A && git commit -q -m "fix: a" -m "No-regression-test: config-only, approved by owner"
  run bash "$C" main..HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"No-regression-test"* ]]
}

@test "empty trailer reason does not exempt" {
  echo v2 > src/a.sh
  git add -A && git commit -q -m "fix: a" -m "No-regression-test:"
  run bash "$C" main..HEAD
  [ "$status" -eq 1 ]
}

@test "custom SUPPORT_E2E_GLOB is honoured" {
  mkdir -p checks; echo v2 > src/a.sh; echo t > checks/z.sh
  commit "fix: a"
  run bash "$C" main..HEAD
  [ "$status" -eq 1 ]
  SUPPORT_E2E_GLOB="checks/*" run bash "$C" main..HEAD
  [ "$status" -eq 0 ]
}

@test "empty range passes; bad range exits 2" {
  run bash "$C" main..HEAD
  [ "$status" -eq 0 ]
  run bash "$C" nope..HEAD
  [ "$status" -eq 2 ]
  run bash "$C"
  [ "$status" -eq 2 ]
}
