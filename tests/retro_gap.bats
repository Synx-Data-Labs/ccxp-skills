#!/usr/bin/env bats
# Tests for _session/retro_gap.sh — the missed-Friday-retro detector
# (T20260813-392025). Pure file enumeration; "today" is pinned via RETRO_GAP_TODAY.

load test_helper
setup() {
  source "$REPO_ROOT/_session/retro_gap.sh"
  J="$BATS_TEST_TMPDIR/JOURNAL"; mkdir -p "$J"
  export RETRO_GAP_TODAY=2026-10-30
}

@test "silent when the newest retro is exactly 7 days old" {
  touch "$J/2026-10-23-retro-weekly.md"
  run retro_gap "$J"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints the gap line when the newest retro is 8 days old" {
  touch "$J/2026-10-22-retro-weekly.md"
  run retro_gap "$J"
  [ "$status" -eq 0 ]
  [ "$output" = "retro-gap 8d — last retro-weekly 2026-10-22 (2026-10-22-retro-weekly.md)" ]
}

@test "uses the newest of several files, not the lexically first" {
  touch "$J/2026-07-24-retro-weekly.md" "$J/2026-10-23-retro-weekly.md" "$J/2026-08-14-retro-weekly.md"
  run retro_gap "$J"
  [ -z "$output" ]
}

@test "names a long gap in days (the 2026-07-24 incident shape)" {
  touch "$J/2026-07-24-retro-weekly.md"
  RETRO_GAP_TODAY=2026-08-13 run retro_gap "$J"
  [[ "$output" == "retro-gap 20d — last retro-weekly 2026-07-24"* ]]
}

@test "prints the none note when there is no retro file or the dir is missing" {
  run retro_gap "$J"
  [[ "$output" == "retro-gap none — no retro-weekly file found in "* ]]
  run retro_gap "$BATS_TEST_TMPDIR/absent"
  [[ "$output" == "retro-gap none"* ]]
}

@test "ignores non-retro and malformed filenames" {
  touch "$J/2026-10-29-daily-summary.md" "$J/notes-retro-weekly.md"
  run retro_gap "$J"
  [[ "$output" == "retro-gap none"* ]]
}

@test "today defaults to America/Chicago: a UTC-next-day instant still counts as the Chicago date" {
  unset RETRO_GAP_TODAY
  touch "$J/2000-01-01-retro-weekly.md"
  run retro_gap "$J"
  [[ "$output" == "retro-gap "*"d — last retro-weekly 2000-01-01"* ]]
  [ "$(TZ=America/Chicago date +%Y-%m-%d)" = "$(_rg_today)" ]
}

@test "never mutates the journal dir" {
  touch "$J/2026-10-01-retro-weekly.md"
  before="$(ls -l "$J")"
  retro_gap "$J" >/dev/null
  [ "$before" = "$(ls -l "$J")" ]
}

# ---- standup rendering of the retro_gap judgment key -------------------------

FX_DIR="$BATS_TEST_DIRNAME/fixtures/standup"
RENDER="$REPO_ROOT/ccxp/scripts/render-standup.sh"

@test "render: retro_gap appears in slack and journal output when set" {
  jq '. + {retro_gap: "retro-gap 20d — last retro-weekly 2026-07-24 (x.md)"}' "$FX_DIR/judgment.json" > "$BATS_TEST_TMPDIR/j.json"
  run bash "$RENDER" "$FX_DIR/data.json" "$BATS_TEST_TMPDIR/j.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retro cadence"* ]]
  [[ "$output" == *"retro-gap 20d"* ]]
  run bash "$RENDER" "$FX_DIR/data.json" "$BATS_TEST_TMPDIR/j.json" --format journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"- Retro cadence: retro-gap 20d"* ]]
}

@test "render: without retro_gap the output is unchanged (no Retro cadence anywhere)" {
  run bash "$RENDER" "$FX_DIR/data.json" "$FX_DIR/judgment.json"
  [[ "$output" != *"Retro cadence"* ]]
  run bash "$RENDER" "$FX_DIR/data.json" "$FX_DIR/judgment.json" --format journal
  [[ "$output" != *"Retro cadence"* ]]
}

@test "an impossible-date filename never masks a real gap" {
  touch "$J/2026-99-99-retro-weekly.md" "$J/2026-10-22-retro-weekly.md"
  run retro_gap "$J"
  [[ "$output" == "retro-gap 8d — last retro-weekly 2026-10-22"* ]]
}
