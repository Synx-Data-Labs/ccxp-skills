#!/usr/bin/env bats
# Tests for agent-pairing/scripts/routine-due.sh (T20261114-144275): the config-driven generalization of ritual-due.sh.
# Fake clock via CCXP_RITUAL_NOW; the Chicago-time epochs were computed with `TZ=America/Chicago date -d`.

bats_require_minimum_version 1.5.0
load test_helper
RT="$REPO_ROOT/agent-pairing/scripts/routine-due.sh"
RD="$REPO_ROOT/agent-pairing/scripts/ritual-due.sh"

MON_NOON=1794247200   # 2026-11-09 Mon 12:00 CST
MON_0700=1794229200   # 2026-11-09 Mon 07:00 CST
MON_0800=1794232800   # 2026-11-09 Mon 08:00 CST
TUE_NOON=1794333600   # 2026-11-10 Tue 12:00
FRI_NOON=1794592800   # 2026-11-13 Fri 12:00
SAT_NOON=1794679200   # 2026-11-14 Sat 12:00
SUN_2330=1794202200   # 2026-11-08 Sun 23:30
SUN2_2330=1794807000  # 2026-11-15 Sun 23:30

setup() {
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers"
  export CCXP_RITUAL_TZ="America/Chicago"
  export CCXP_ROUTINES_PROFILE_FILE="$BATS_TEST_TMPDIR/profile.yml"
  unset CCXP_RITUALS CCXP_RITUAL_TTL
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dev/TODO"
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin git@example.com:acme/widgets.git
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in gh curl wget claude ssh; do printf '#!/bin/sh\necho "NETWORK CALL: %s" >&2\nexit 99\n' "$t" >"$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

at() { CCXP_RITUAL_NOW="$1" bash "$RT" --repo "$REPO" "${@:2}"; }
tracked() { cat >"$REPO/dev/.routines.yml"; }
profile() { cat >"$CCXP_ROUTINES_PROFILE_FILE"; }

# --- compat with ritual-due.sh (no config) ---

@test "compat: list matches ritual-due.sh over a week and the boundaries" {
  for now in $MON_0700 $MON_NOON $TUE_NOON $FRI_NOON $SAT_NOON $SUN_2330 $SUN2_2330 $((MON_NOON + 86400 * 2)); do
    want="$(CCXP_RITUAL_NOW=$now bash "$RD" --repo "$REPO" list)"
    got="$(at "$now" list)"
    [ "$got" = "$want" ]
  done
}

@test "compat: Friday standup claim also claims retro; done and release follow it only" {
  run at "$FRI_NOON" claim
  [ "$output" = "standup 2026-11-13" ]
  run at "$FRI_NOON" list
  [ "$output" = "ipm 2026-11-09" ]
  # releasing the standup makes both due again
  run at "$FRI_NOON" release standup 2026-11-13
  run at "$FRI_NOON" list
  [ "$output" = $'standup 2026-11-13\nipm 2026-11-09\nretro 2026-11-13' ]
  run at "$FRI_NOON" claim
  run at "$FRI_NOON" done standup 2026-11-13
  run at "$FRI_NOON" list
  [ "$output" = "ipm 2026-11-09" ]
}

@test "compat: claim order and exclusivity match ritual-due.sh" {
  run at "$MON_NOON" claim
  [ "$output" = "standup 2026-11-09" ]
  run at "$MON_NOON" claim
  [ "$output" = "ipm 2026-11-09" ]
  run at "$MON_NOON" claim
  [ -z "$output" ]
}

@test "done and release need the key; unknown routine is a usage error" {
  run -2 --separate-stderr at "$MON_NOON" done standup
  run -2 --separate-stderr at "$MON_NOON" done nosuch 2026-11-09
  run -2 --separate-stderr at "$MON_NOON" bogus
}

@test "off switches and unknown profile dir are silent no-ops" {
  CCXP_RITUALS=0 run at "$MON_NOON" list
  [ -z "$output" ]
  mkdir -p "$CCXP_RITUAL_DIR"; touch "$CCXP_RITUAL_DIR/off"
  run at "$MON_NOON" list
  [ -z "$output" ]
}

@test "TTL: an abandoned claim is superseded; a fresh one blocks" {
  run at "$MON_NOON" claim
  CCXP_RITUAL_TTL=60 run at "$((MON_NOON + 30))" list
  [ "$output" = "ipm 2026-11-09" ]
  CCXP_RITUAL_TTL=60 run at "$((MON_NOON + 120))" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
}

@test "claim race: two shells, exactly one winner" {
  CCXP_RITUAL_NOW=$MON_NOON bash "$RT" --repo "$REPO" claim >"$BATS_TEST_TMPDIR/a" &
  CCXP_RITUAL_NOW=$MON_NOON bash "$RT" --repo "$REPO" claim >"$BATS_TEST_TMPDIR/b" &
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" | grep -c '^standup')" -eq 1 ]
}

@test "outside a repo only scope any routines can fire" {
  run env CCXP_RITUAL_NOW=$MON_NOON bash "$RT" --repo "$BATS_TEST_TMPDIR" list
  [ -z "$output" ]
  profile <<'Y'
routines:
  inbox:
    schedule: {days: weekdays, at: "07:30"}
    scope: any
    steps: [{skill: "/email-triage"}]
Y
  run env CCXP_RITUAL_NOW=$MON_NOON bash "$RT" --repo "$BATS_TEST_TMPDIR" list
  [ "$output" = "inbox 2026-11-09" ]
  run env CCXP_RITUAL_NOW=$MON_NOON bash "$RT" --repo "$BATS_TEST_TMPDIR" claim
  [ "$output" = "inbox 2026-11-09" ]
  [ -e "$CCXP_RITUAL_DIR/_any/inbox-2026-11-09.claim.1" ]
}

# --- config layers ---

@test "tracked file adds inbox, disables retro, overrides standup.at" {
  tracked <<'Y'
routines:
  inbox:
    description: clean the inbox
    schedule: {days: weekdays, at: "07:30"}
    steps: [{skill: "/email-triage", args: "--window 24h"}]
  retro: {enabled: false}
  standup:
    schedule: {at: "08:30"}
Y
  run at "$MON_0700" list
  [ "$output" = "ipm 2026-11-09" ]
  run at "$((MON_0800 + 3600))" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09\ninbox 2026-11-09' ]
  run at "$FRI_NOON" list
  [[ "$output" != *retro* ]]
}

@test "profile layer overrides the tracked layer; routines-file: redirects the tracked path" {
  tracked <<'Y'
routines:
  retro: {enabled: false}
Y
  profile <<'Y'
routines:
  retro: {enabled: true}
Y
  run at "$FRI_NOON" list
  [[ "$output" == *"retro 2026-11-13"* ]]
  printf 'routines:\n  ipm: {enabled: false}\n' >"$BATS_TEST_TMPDIR/hub.yml"
  profile <<Y
routines-file: $BATS_TEST_TMPDIR/hub.yml
Y
  run at "$MON_NOON" list
  [ "$output" = "standup 2026-11-09" ]
}

@test "once_per week: a missed run catches up later in the window; at gates only the key day" {
  tracked <<'Y'
routines:
  weekly:
    schedule: {days: weekdays, at: "09:00", once_per: week}
    steps: [{skill: "/ipm"}]
Y
  run at "$MON_0800" list
  [[ "$output" != *weekly* ]]
  run at "$TUE_NOON" list
  [[ "$output" == *"weekly 2026-11-09"* ]]
}

@test "not_before and not_after bound the time of day" {
  tracked <<'Y'
routines:
  window:
    schedule: {not_before: "08:00", not_after: "11:00"}
    steps: [{skill: "/ccxp"}]
Y
  run at "$MON_0700" list
  [[ "$output" != *window* ]]
  run at "$((MON_0800 + 600))" list
  [[ "$output" == *"window 2026-11-09"* ]]
  run at "$MON_NOON" list
  [[ "$output" != *window* ]]
}

@test "routine tz moves the day boundary" {
  tracked <<'Y'
routines:
  east:
    schedule: {days: [mon]}
    tz: Asia/Shanghai
    steps: [{skill: "/ccxp"}]
Y
  # Sunday 23:30 Chicago is Monday afternoon in Shanghai
  run at "$SUN_2330" list
  [[ "$output" == *"east 2026-11-09"* ]]
}

@test "every: routines list as 'every', are never claimed, and wait out the interval" {
  tracked <<'Y'
routines:
  poll:
    schedule: {every: 5m}
    steps: [{skill: "/slack"}]
Y
  run at "$MON_NOON" list
  [[ "$output" == *"poll every"* ]]
  run at "$MON_NOON" claim
  [[ "$output" != *poll* ]]
  run at "$MON_NOON" done poll every
  run at "$((MON_NOON + 60))" list
  [[ "$output" != *poll* ]]
  run at "$((MON_NOON + 301))" list
  [[ "$output" == *"poll every"* ]]
  [ "$(ls "$CCXP_RITUAL_DIR"/*/poll* | wc -l)" -eq 1 ]
  run -2 --separate-stderr at "$MON_NOON" done poll 2026-11-09
}

@test "also_claims from config follows done and release" {
  tracked <<'Y'
routines:
  ipm: {also_claims: [standup]}
  standup: {also_claims: []}
Y
  run at "$MON_NOON" claim
  [ "$output" = "standup 2026-11-09" ]
  run at "$MON_NOON" claim
  [ "$output" = "ipm 2026-11-09" ]
  run at "$MON_NOON" list
  [ -z "$output" ]
}

@test "show prints the merged routine; unknown name exits 3" {
  run at "$MON_NOON" show ipm
  [[ "$output" == *'"weekdays"'* ]]
  run -3 --separate-stderr at "$MON_NOON" show nosuch
}

# --- malformed config falls back ---

@test "a broken override warns once and keeps the built-in; list still works" {
  tracked <<'Y'
routines:
  standup:
    schedule: {at: 1030}
Y
  run --separate-stderr at "$MON_NOON" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  [ "$(grep -c 'warning' <<<"$stderr")" -eq 1 ]
}

@test "an unparsable file is skipped whole with a warning" {
  printf 'routines: [unclosed\n' | tracked
  run --separate-stderr at "$MON_NOON" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  [[ "$stderr" == *warning* ]]
}

@test "no YAML reader: built-ins still work with one warning" {
  mkdir -p "$BATS_TEST_TMPDIR/nopy"
  for t in python3 yq; do printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/nopy/$t"; chmod +x "$BATS_TEST_TMPDIR/nopy/$t"; done
  PATH="$BATS_TEST_TMPDIR/nopy:$PATH" run --separate-stderr at "$MON_NOON" list
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  [[ "$stderr" == *"built-in routines only"* ]]
}

@test "drift guard: the compiled-in fallback rows equal the rows of routines.default.yml" {
  want="$(python3 -I "$REPO_ROOT/agent-pairing/scripts/routine-config.py" --default "$REPO_ROOT/agent-pairing/routines.default.yml" rows)"
  mkdir -p "$BATS_TEST_TMPDIR/nopy"
  for t in python3 yq; do printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/nopy/$t"; chmod +x "$BATS_TEST_TMPDIR/nopy/$t"; done
  got="$(PATH="$BATS_TEST_TMPDIR/nopy:$PATH" bash -c '. "$1"; rt-builtin-rows' _ "$RT" 2>/dev/null)"
  [ "$got" = "$want" ]
}

# --- review fixes ---

@test "every: honors days and the not_before/not_after window" {
  tracked <<'Y'
routines:
  hourly:
    schedule: {every: 1h, not_before: "09:00", not_after: "10:00", days: [sat]}
    steps: [{skill: "/ccxp"}]
Y
  run at "$MON_NOON" list
  [[ "$output" != *hourly* ]]
  run at "$SAT_NOON" list
  [[ "$output" != *hourly* ]]
  run at "$((SAT_NOON - 9000))" list   # Sat 09:30
  [[ "$output" == *"hourly every"* ]]
}

@test "a non-string or unsafe routine name warns and never aborts list, claim or done" {
  tracked <<'Y'
routines:
  2026: {steps: [{skill: "/ccxp"}]}
  yes: {steps: [{skill: "/ccxp"}]}
  "../x": {steps: [{skill: "/ccxp"}]}
Y
  run --separate-stderr at "$MON_NOON" list
  [ "$status" -eq 0 ]
  [ "$output" = $'standup 2026-11-09\nipm 2026-11-09' ]
  [[ "$stderr" == *"bad routine name"* ]]
  run --separate-stderr at "$MON_NOON" claim
  [ "$output" = "standup 2026-11-09" ]
}

@test "also_claims with a glob character or the routine itself is rejected, no globbing happens" {
  touch "$REPO/retro"
  tracked <<'Y'
routines:
  standup: {also_claims: ["*", standup]}
Y
  run --separate-stderr at "$FRI_NOON" claim
  [ "$output" = "standup 2026-11-13" ]
  [[ "$stderr" == *"bad also_claims entry"* ]]
  # the invalid override was dropped, so the built-in standup -> retro coupling still holds
  run --separate-stderr at "$FRI_NOON" list
  [ "$output" = "ipm 2026-11-09" ]
}

@test "a later layer can switch a schedule from at to every and back, and null removes a key" {
  tracked <<'Y'
routines:
  r:
    schedule: {days: weekdays, at: "09:00", not_before: "08:00"}
    steps: [{skill: "/ccxp"}]
Y
  profile <<'Y'
routines:
  r:
    schedule: {every: 1h, not_before: null}
Y
  run at "$MON_NOON" list
  [[ "$output" == *"r every"* ]]
  run at "$MON_NOON" show r
  [[ "$output" != *not_before* ]]
}

@test "check and show still run with the off switches set" {
  CCXP_RITUALS=0 run at "$MON_NOON" show ipm
  [ "$status" -eq 0 ]
  printf 'extra: 1\n' | tracked
  CCXP_RITUALS=0 run at "$MON_NOON" check
  [ "$status" -eq 1 ]
}

# --- starter routines (T20261114-195064) ---

EX="$REPO_ROOT/agent-pairing/routines.examples.yml"
MON_0730=1794231000   # 2026-11-09 Mon 07:30 CST
MON_0800X=1794232800  # 2026-11-09 Mon 08:00 CST
TUE_0800=1794319200   # 2026-11-10 Tue 08:00 CST

@test "starter routines: the examples file passes check as the tracked layer" {
  cp "$EX" "$REPO/dev/.routines.yml"
  run at "$MON_NOON" check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "starter routines: inbox and a second 08:00 routine each fire once at their time over a day, a second check is silent" {
  cp "$EX" "$REPO/dev/.routines.yml"
  # nightly-check is a commented example until its skill exists (T20261116-179192): simulate it in the profile layer
  profile <<'Y'
routines:
  ipm: {enabled: false}
  retro: {enabled: false}
  nightly-check:
    schedule: {days: daily, at: "08:00", once_per: day}
    steps: [{skill: "/rca"}]
Y
  run at "$((MON_0730 - 60))" list
  [[ "$output" != *inbox* ]]
  run at "$MON_0730" claim
  [ "$output" = "inbox 2026-11-09" ]
  run at "$MON_0730" claim
  [ -z "$output" ]
  run at "$MON_0800X" claim
  [ "$output" = "nightly-check 2026-11-09" ]
  run at "$MON_0800X" claim
  [ -z "$output" ]
  # done keeps them quiet for the rest of the day, the next day they are due again
  run at "$MON_0800X" done inbox 2026-11-09
  run at "$MON_0800X" done nightly-check 2026-11-09
  run at "$MON_NOON" list
  [[ "$output" != *inbox* ]]
  [[ "$output" != *nightly-check* ]]
  run at "$TUE_0800" list
  [[ "$output" == *"inbox 2026-11-10"* ]]
  [[ "$output" == *"nightly-check 2026-11-10"* ]]
}

@test "starter routines: alerts is an every: routine, listed as every and never claimed" {
  cp "$EX" "$REPO/dev/.routines.yml"
  run at "$MON_NOON" list
  [[ "$output" == *"alerts every"* ]]
  run at "$MON_NOON" claim
  [[ "$output" != *alerts* ]]
}

@test "starter routines: a disabled built-in does not fire while the starters still do" {
  cp "$EX" "$REPO/dev/.routines.yml"
  profile <<'Y'
routines:
  standup: {enabled: false}
Y
  run at "$MON_NOON" list
  [[ "$output" != *standup* ]]
  [[ "$output" == *"inbox 2026-11-09"* ]]
  # without the disable the standup (moved to 08:30 by the example) would be due at noon
  : >"$CCXP_ROUTINES_PROFILE_FILE"
  run at "$MON_NOON" list
  [[ "$output" == *"standup 2026-11-09"* ]]
}

@test "starter routines: no step of the examples reaches a send-type operation" {
  # comments may say "never sends"; no step line (live or commented) carries a send-type word
  run bash -c "grep -E '^\s*#?\s*- \{skill' '$EX' | grep -Ei 'send|forward|reply|trash|spam|delete'"
  [ "$status" -ne 0 ]
}
