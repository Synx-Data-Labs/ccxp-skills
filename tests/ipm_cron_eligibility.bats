#!/usr/bin/env bats
# T20260820-227478: ipm/SKILL.md's cron-mode eligibility filter must keep a
# second admission path for retro-filed Open tasks, and keep excluding other Open tasks.

load test_helper

@test "cron eligibility filter admits Open + source Retro + non-empty estimation" {
  run grep -n 'begins "Retro"' "$REPO_ROOT/ipm/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -n 'begins "Retro"' "$REPO_ROOT/ipm/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "cron eligibility filter still excludes every other Open task" {
  run grep -n 'Every other `Open` task stays excluded' "$REPO_ROOT/ipm/SKILL.md"
  [ "$status" -eq 0 ]
}
