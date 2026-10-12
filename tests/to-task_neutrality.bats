#!/usr/bin/env bats
# T20261012-109735 / T20261012-373882: the to-task skill + lib stay
# company-neutral and never post. (Renamed from support_neutrality.bats
# when /support -> /to-task.)

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; }

@test "no company-specific literals under to-task/ and _support/" {
  run grep -rniE 'synx|hashdata|synxdb|xinzweb' "$REPO_ROOT/to-task" "$REPO_ROOT/_support"
  [ "$status" -eq 1 ]
}

@test "no issue-posting calls under to-task/ and _support/ (intake posts nothing)" {
  run grep -rnE 'gh(\.sh)? +(issue +(comment|edit|close)|api .*(-X|--method) +(POST|PATCH|PUT)|pr +comment)' \
    "$REPO_ROOT/to-task" "$REPO_ROOT/_support" --include='*.sh' --include='SKILL.md'
  [ "$status" -eq 1 ]
}

@test "to-task skill is explicit-ask only" {
  grep -q '^disable-model-invocation: true' "$REPO_ROOT/to-task/SKILL.md"
}
