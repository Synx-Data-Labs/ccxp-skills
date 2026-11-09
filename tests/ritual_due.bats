#!/usr/bin/env bats
# Tests for agent-pairing/scripts/ritual-due.sh (T20261107-228304): the persona's token-free "what is due" check.
# Fake clock via CCXP_RITUAL_NOW; all Chicago-time epochs below were computed with `TZ=America/Chicago date -d`.

bats_require_minimum_version 1.5.0
load test_helper
RD="$REPO_ROOT/agent-pairing/scripts/ritual-due.sh"

MON_NOON=1794247200   # 2026-11-09 Mon 12:00 CST
MON_0030=1794205800   # 2026-11-09 Mon 00:30 CST 
SUN_2330=1794202200   # 2026-11-08 Sun 23:30 CST (= 2026-11-09 05:30Z, UTC date already Monday)
WED_NOON=1794420000   # 2026-11-11 Wed 12:00
FRI_NOON=1794592800   # 2026-11-13 Fri 12:00
SAT_NOON=1794679200   # 2026-11-14 Sat 12:00
SUN2_2330=1794807000  # 2026-11-15 Sun 23:30
MON2_0010=1794809400  # 2026-11-16 Mon 00:10

setup() {
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers"
  export CCXP_RITUAL_TZ="America/Chicago"
  unset CCXP_RITUALS CCXP_RITUAL_TTL
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dev/TODO"
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin git@example.com:acme/widgets.git
  # no network, no model: any call to these would fail the test loudly
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in gh curl wget claude ssh; do printf '#!/bin/sh\necho "NETWORK CALL: %s" >&2\nexit 99\n' "$t" >"$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

at() { CCXP_RITUAL_NOW="$1" bash "$RD" --repo "$REPO" "${@:2}"; }

@test "weekdays: Monday lists standup and ipm; no retro" {
  run at "$MON_NOON" list
  [ "$status" -eq 0 ]
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
}

@test "midweek: standup and ipm (keyed to that week's Monday); Friday adds retro keyed to Friday" {
  run at "$WED_NOON" list
  [ "$output" = $'standup 2026-11-11\nipm 2026-11-09' ]
  run at "$FRI_NOON" list
  [ "$output" = $'standup 2026-11-13\nipm 2026-11-09\nretro 2026-11-13' ]
}

@test "weekend: standup and a missed retro catch up, ipm window is closed" {
  run at "$SAT_NOON" list
  [ "$output" = $'standup 2026-11-14\nretro 2026-11-13' ]
}

@test "timezone: day boundary and weekday follow America/Chicago, not UTC" {
  # Sunday 23:30 Chicago is already Monday in UTC: still Sunday here, so no ipm
  run at "$SUN_2330" list
  [ "$output" = $'standup 2026-11-08\nretro 2026-11-06' ]
  # Monday 00:30 Chicago: Monday
  run at "$MON_0030" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  # a different zone moves the boundary
  CCXP_RITUAL_TZ=Asia/Shanghai run at "$SUN_2330" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
}

@test "year and month rollover: Monday key across a month boundary" {
  # 2026-12-02 Wed 12:00 CST -> Monday 2026-11-30
  local e; e="$(TZ=America/Chicago date -d '2026-12-02 12:00' +%s 2>/dev/null || true)"
  [ -n "$e" ] || skip "GNU date needed for this epoch"
  run at "$e" list
  [ "$output" = $'standup 2026-12-02\nipm 2026-11-30' ]
}

@test "claim prints one ritual per check, in priority order, and is idempotent per ritual" {
  run at "$MON_NOON" claim
  [ "$output" = "standup 2026-11-09" ]
  run at "$MON_NOON" claim
  [ "$output" = "ipm 2026-11-09" ]
  run at "$MON_NOON" claim
  [ -z "$output" ]
  [ "$status" -eq 0 ]
  run at "$MON_NOON" list
  [ -z "$output" ]
}

@test "no-op fast path: nothing due prints nothing, exits 0, writes no marker" {
  at "$MON_NOON" claim >/dev/null
  at "$MON_NOON" claim >/dev/null
  local before; before="$(find "$CCXP_RITUAL_DIR" -type f | sort | tr '\n' ' ')"
  run at "$MON_NOON" claim
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(find "$CCXP_RITUAL_DIR" -type f | sort | tr '\n' ' ')" = "$before" ]
}

@test "done marks a ritual finished for good; the next day is a fresh standup" {
  at "$MON_NOON" claim >/dev/null
  at "$MON_NOON" done standup 2026-11-09
  run at "$MON_NOON" list
  [ "$output" = "ipm 2026-11-09" ]
  run at "$WED_NOON" list
  [ "$output" = $'standup 2026-11-11\nipm 2026-11-09' ]
}

@test "missed Monday heals: ipm is still due on Wednesday of the same week" {
  run at "$WED_NOON" claim
  [ "$output" = "standup 2026-11-11" ]
  run at "$WED_NOON" claim
  [ "$output" = "ipm 2026-11-09" ]
  at "$WED_NOON" done ipm 2026-11-09
  run at "$FRI_NOON" list
  [ "$output" = $'standup 2026-11-13\nretro 2026-11-13' ]
}

@test "claim is race-safe: of several concurrent claims exactly one wins each ritual" {
  local i out="$BATS_TEST_TMPDIR/race"; mkdir -p "$out"
  for i in 1 2 3 4 5 6; do ( CCXP_RITUAL_NOW="$WED_NOON" bash "$RD" --repo "$REPO" claim >"$out/$i" ) & done
  wait
  [ "$(cat "$out"/* | grep -c '^standup 2026-11-11$')" -eq 1 ]
  [ "$(cat "$out"/* | grep -c '^ipm 2026-11-09$')" -eq 1 ]
}

@test "a claim whose job died is retried after the TTL, not before" {
  at "$MON_NOON" claim >/dev/null           # standup claimed, never done
  run at $((MON_NOON + 3600)) list
  [ "$output" = "ipm 2026-11-09" ]          # one hour later: still in flight
  run at $((MON_NOON + 21600 + 60)) list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  run at $((MON_NOON + 21600 + 60)) claim
  [ "$output" = "standup 2026-11-09" ]
}

@test "release drops the claim so the next check may retry; done is not touched" {
  at "$MON_NOON" claim >/dev/null
  at "$MON_NOON" release standup 2026-11-09
  run at "$MON_NOON" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
}

@test "Friday standup claim also claims the retro (the standup job is /ccxp); done and release follow it" {
  run at "$FRI_NOON" claim
  [ "$output" = "standup 2026-11-13" ]
  run at "$FRI_NOON" list
  [ "$output" = "ipm 2026-11-09" ]          # retro is held by the standup job
  at "$FRI_NOON" done standup 2026-11-13
  run at "$SAT_NOON" list
  [ "$output" = "standup 2026-11-14" ]      # retro done: not due on Saturday either
  # failure path
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers2"
  at "$FRI_NOON" claim >/dev/null
  at "$FRI_NOON" release standup 2026-11-13
  run at "$FRI_NOON" list
  [ "$output" = $'standup 2026-11-13\nipm 2026-11-09\nretro 2026-11-13' ]
}

@test "a standalone retro claim (Saturday catch-up) is separate from the standup" {
  run at "$SAT_NOON" claim; [ "$output" = "standup 2026-11-14" ]
  run at "$SAT_NOON" claim; [ "$output" = "retro 2026-11-13" ]
  at "$SAT_NOON" done retro 2026-11-13
  run at "$SUN2_2330" list
  [ "$output" = "standup 2026-11-15" ]
}

@test "markers are per repo; a worktree of the same origin shares them" {
  at "$MON_NOON" claim >/dev/null
  local other="$BATS_TEST_TMPDIR/other"; mkdir -p "$other/dev/TODO"; git -C "$other" init -q
  git -C "$other" remote add origin git@example.com:acme/gadgets.git
  run env CCXP_RITUAL_NOW="$MON_NOON" bash "$RD" --repo "$other" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  git -C "$REPO" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
  git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/wt" -b wt
  mkdir -p "$BATS_TEST_TMPDIR/wt/dev/TODO"
  run env CCXP_RITUAL_NOW="$MON_NOON" bash "$RD" --repo "$BATS_TEST_TMPDIR/wt" list
  [ "$output" = "ipm 2026-11-09" ]
}

@test "silent no-op outside a repo with dev/TODO, and with the off switches" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run env CCXP_RITUAL_NOW="$MON_NOON" bash "$RD" --repo "$BATS_TEST_TMPDIR/plain" claim
  [ "$status" -eq 0 ]; [ -z "$output" ]
  CCXP_RITUALS=0 run at "$MON_NOON" claim
  [ "$status" -eq 0 ]; [ -z "$output" ]
  mkdir -p "$CCXP_RITUAL_DIR"; : >"$CCXP_RITUAL_DIR/off"
  run at "$MON_NOON" claim
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "bad input: unknown verb and unknown ritual exit 2" {
  run at "$MON_NOON" frobnicate
  [ "$status" -eq 2 ]
  run at "$MON_NOON" done lunch 2026-11-09
  [ "$status" -eq 2 ]
  run at "$MON_NOON" done standup "not-a-date"
  [ "$status" -eq 2 ]
}

@test "sourceable: functions load without running anything" {
  run bash -c "source '$RD' && declare -F ritual-due"
  [ "$status" -eq 0 ]
}

@test "a stale Friday retro claim is not finished by a Saturday standup (companion follows its own standup only)" {
  at "$FRI_NOON" claim >/dev/null                       # Friday standup + retro claimed, job dies
  at $((FRI_NOON + 21600 + 60)) claim >/dev/null        # re-claimed ipm etc. later; now Saturday's standup:
  run at "$SAT_NOON" claim
  [ "$output" = "standup 2026-11-14" ]
  at "$SAT_NOON" done standup 2026-11-14
  run at "$SAT_NOON" list
  [[ "$output" == *"retro 2026-11-13"* ]]               # the retro never ran: still due
}

@test "done and release require the key claim printed" {
  run at "$MON_NOON" done standup
  [ "$status" -eq 2 ]
  run at "$MON_NOON" release standup
  [ "$status" -eq 2 ]
}

@test "a job that crosses midnight finishes its own day: done with the printed key" {
  at "$MON_NOON" claim >/dev/null
  at $((MON_NOON + 43200)) done standup 2026-11-09   # finished Tuesday 00:00+ Chicago
  run at $((MON_NOON + 43200)) list
  [ "$output" = $'standup 2026-11-10\nipm 2026-11-09' ]
}

@test "DST edges: Sunday of the fall-back and spring-forward weekends stay Sunday until Chicago midnight" {
  run at 1793511000 list; [ "$output" = $'standup 2026-11-01\nretro 2026-10-30' ]   # 2026-11-01 00:30 CDT
  run at 1793597400 list; [ "$output" = $'standup 2026-11-01\nretro 2026-10-30' ]   # 2026-11-01 23:30 CST
  run at 1773030600 list; [ "$output" = $'standup 2026-03-08\nretro 2026-03-06' ]   # 2026-03-08 23:30 CDT
  run at 1773034200 list; [ "$output" = $'standup 2026-03-09\nipm 2026-03-09' ]     # 2026-03-09 00:30 CDT
}

@test "a claim file that is empty (writer mid-write) counts as in flight until it is older than the TTL" {
  local d; at "$MON_NOON" claim >/dev/null
  d="$(dirname "$(find "$CCXP_RITUAL_DIR" -name 'standup-2026-11-09.claim.1')")"
  : >"$d/standup-2026-11-09.claim.1"
  run at "$MON_NOON" list; [ "$output" = "ipm 2026-11-09" ]
  touch -t 202611080000 "$d/standup-2026-11-09.claim.1"
  run at "$MON_NOON" list; [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
}

@test "the marker dir name is a hash: a credential in the origin URL never reaches the filesystem" {
  git -C "$REPO" remote set-url origin "https://user:s3cr3t-token@example.com/acme/widgets.git"
  at "$MON_NOON" claim >/dev/null
  run bash -c "find '$CCXP_RITUAL_DIR' | grep -c 's3cr3t'"
  [ "$output" = "0" ]
  [ -n "$(find "$CCXP_RITUAL_DIR" -name 'standup-*')" ]
}
