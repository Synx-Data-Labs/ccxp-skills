#!/usr/bin/env bats
# README's "install all N skills" must match the number of top-level skill dirs.

load test_helper

@test "README skill count matches */SKILL.md count" {
  actual=$(ls -d "$REPO_ROOT"/*/SKILL.md | wc -l | tr -d ' ')
  run grep -oE 'install all [0-9]+ skills' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "install all ${actual} skills" ]
}
