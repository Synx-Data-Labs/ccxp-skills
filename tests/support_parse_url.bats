#!/usr/bin/env bats
# Tests for _support/parse-issue-url.sh (T20261012-109735).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  P="$REPO_ROOT/_support/parse-issue-url.sh"
}

@test "https github.com issue URL -> owner repo number" {
  run bash "$P" https://github.com/acme/support-repo/issues/24
  [ "$status" -eq 0 ]
  [ "$output" = "acme support-repo 24" ]
}

@test "fragment and trailing slash tolerated" {
  run bash "$P" "https://github.com/acme/r/issues/5#issuecomment-1"
  [ "$status" -eq 0 ]
  [ "$output" = "acme r 5" ]
  run bash "$P" "https://github.com/acme/r/issues/5/"
  [ "$output" = "acme r 5" ]
}

@test "owner/repo#N shorthand" {
  run bash "$P" acme/r#9
  [ "$status" -eq 0 ]
  [ "$output" = "acme r 9" ]
}

@test "GHES host accepted" {
  run bash "$P" https://git.example.internal/acme/r/issues/3
  [ "$status" -eq 0 ]
  [ "$output" = "acme r 3" ]
}

@test "--canonical prints a stable URL (host kept, shorthand uses GH_HOST or github.com)" {
  run bash "$P" --canonical "https://github.com/acme/r/issues/5#x"
  [ "$output" = "https://github.com/acme/r/issues/5" ]
  run bash "$P" --canonical acme/r#5
  [ "$output" = "https://github.com/acme/r/issues/5" ]
  GH_HOST=git.example.internal run bash "$P" --canonical acme/r#5
  [ "$output" = "https://git.example.internal/acme/r/issues/5" ]
}

@test "pull request URL rejected with exit 2 and a clear message" {
  run bash "$P" https://github.com/acme/r/pull/5
  [ "$status" -eq 2 ]
  [[ "$output" == *"pull request"* ]]
}

@test "garbage and empty input rejected with exit 1" {
  run bash "$P" "not a url"
  [ "$status" -eq 1 ]
  run bash "$P"
  [ "$status" -eq 1 ]
  run bash "$P" "https://github.com/acme/r/issues/abc"
  [ "$status" -eq 1 ]
}
