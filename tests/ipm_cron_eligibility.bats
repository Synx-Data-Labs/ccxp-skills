#!/usr/bin/env bats
# T20260820-227478: ipm/SKILL.md's cron-mode eligibility filter must keep a
# second admission path for retro-filed Open tasks, and keep excluding other Open tasks.

load test_helper

setup() {
  LINE="$(grep -n 'When `CCXP_CRON_MODE=1`, drop any `Open` candidate' "$REPO_ROOT/ipm/SKILL.md" | head -1)"
}

@test "filter bullet exists" {
  [ -n "$LINE" ]
}

@test "filter admits Design + estimation and Open + Retro source + estimation" {
  [[ "$LINE" == *'`status: Design` with a non-empty `estimation`'* ]]
  [[ "$LINE" == *'`Open` whose `source:` begins "Retro" with a non-empty `estimation` and no `Category: quality` tag'* ]]
}

@test "filter still excludes every other Open task" {
  [[ "$LINE" == *'Every other `Open` task stays excluded'* ]]
}
