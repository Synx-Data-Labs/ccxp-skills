#!/usr/bin/env bats
# T20261012-109735: the support skill + lib stay company-neutral and never post.

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; }

@test "no company-specific literals under support/ and _support/" {
  run grep -rniE 'synx|hashdata|synxdb|xinzweb' "$REPO_ROOT/support" "$REPO_ROOT/_support"
  [ "$status" -eq 1 ]
}

@test "no issue-posting calls under support/ and _support/ (P1 posts nothing)" {
  run grep -rnE 'gh(\.sh)? +(issue +(comment|edit|close)|api .*(-X|--method) +(POST|PATCH|PUT)|pr +comment)' \
    "$REPO_ROOT/support" "$REPO_ROOT/_support" --include='*.sh' --include='SKILL.md'
  [ "$status" -eq 1 ]
}

@test "support skill is explicit-ask only" {
  grep -q '^disable-model-invocation: true' "$REPO_ROOT/support/SKILL.md"
}
