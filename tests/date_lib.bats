#!/usr/bin/env bats
# _date/date.sh — portable date arithmetic. Runs on whichever `date` flavor
# the host has (GNU in CI, BSD on macOS); every expectation is a calendar fact,
# so both flavors must agree.

load test_helper

DATE_SH="$REPO_ROOT/_date/date.sh"

@test "monday: every day of the week 2026-10-26 (Mon) .. 2026-11-01 (Sun) maps to 2026-10-26" {
  for d in 2026-10-26 2026-10-27 2026-10-28 2026-10-29 2026-10-30 2026-10-31 2026-11-01; do
    run bash "$DATE_SH" monday "$d"
    [ "$status" -eq 0 ]
    [ "$output" = 2026-10-26 ]
  done
}

@test "monday --next: on a Monday it is the same day, otherwise the following Monday" {
  [ "$(bash "$DATE_SH" monday 2026-10-26 --next)" = 2026-10-26 ]
  [ "$(bash "$DATE_SH" monday 2026-10-27 --next)" = 2026-11-02 ]
  [ "$(bash "$DATE_SH" monday 2026-11-01 --next)" = 2026-11-02 ]
}

@test "monday: crosses month and year boundaries" {
  [ "$(bash "$DATE_SH" monday 2027-01-01)" = 2026-12-28 ]
  [ "$(bash "$DATE_SH" monday 2024-03-01)" = 2024-02-26 ]
}

@test "monday defaults to TODAY, which the environment can pin" {
  [ "$(TODAY=2026-10-30 bash "$DATE_SH" monday)" = 2026-10-26 ]
  [ "$(TODAY=2026-10-30 bash "$REPO_ROOT/_date/monday.sh")" = 2026-10-26 ]
  [ "$(TODAY=2026-10-30 bash "$REPO_ROOT/_date/monday.sh" --next)" = 2026-11-02 ]
}

@test "dow: ISO weekday, Monday=1 .. Sunday=7" {
  [ "$(bash "$DATE_SH" dow 2026-10-26)" = 1 ]
  [ "$(bash "$DATE_SH" dow 2026-10-30)" = 5 ]
  [ "$(bash "$DATE_SH" dow 2026-11-01)" = 7 ]
}

@test "add: forward, backward, leap day and year rollover" {
  [ "$(bash "$DATE_SH" add 2026-12-31 1)" = 2027-01-01 ]
  [ "$(bash "$DATE_SH" add 2026-03-01 -1)" = 2026-02-28 ]
  [ "$(bash "$DATE_SH" add 2024-03-01 -1)" = 2024-02-29 ]
  [ "$(bash "$DATE_SH" add 2026-10-30 7)" = 2026-11-06 ]
  [ "$(bash "$DATE_SH" add 2026-10-30 0)" = 2026-10-30 ]
}

@test "invalid dates and counts exit 2: bad shape, impossible day, non-integer" {
  run bash "$DATE_SH" monday 2026-13-01;  [ "$status" -eq 2 ]
  run bash "$DATE_SH" dow 2026-02-31;     [ "$status" -eq 2 ]
  run bash "$DATE_SH" dow yesterday;      [ "$status" -eq 2 ]
  run bash "$DATE_SH" add 2026-10-30 x;   [ "$status" -eq 2 ]
  run bash "$DATE_SH" ago -3;             [ "$status" -eq 2 ]
  run bash "$DATE_SH" nonsense;           [ "$status" -eq 2 ]
}

@test "ago: N days before the pinned NOW, as a UTC timestamp" {
  [ "$(NOW=2026-10-30T12:00:00Z bash "$DATE_SH" ago 7)" = 2026-10-23T12:00:00Z ]
  [ "$(NOW=2026-10-30T12:00:00Z bash "$DATE_SH" ago 0)" = 2026-10-30T12:00:00Z ]
  [ "$(NOW=2026-03-02T00:00:30Z bash "$DATE_SH" ago 2)" = 2026-02-28T00:00:30Z ]
}

@test "ago: without NOW it uses the real clock (shape check only)" {
  run bash "$DATE_SH" ago 1
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "sourceable: functions are available without running main" {
  run bash -c "source '$DATE_SH'; d_monday 2026-10-29"
  [ "$status" -eq 0 ]
  [ "$output" = 2026-10-26 ]
}
