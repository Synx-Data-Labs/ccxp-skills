#!/usr/bin/env bats
# ccxp/scripts/cheap-hold.sh (Phase 1.1a gate) and the
# ccxp/scripts/prune-drive-threads.sh wrapper (Phase 0.5). Offline: pure
# arguments, and a fixture drive-threads.json under $BATS_TEST_TMPDIR with
# fake ids. Nothing is posted or sent.

load test_helper

HOLD="$REPO_ROOT/ccxp/scripts/cheap-hold.sh"
PRUNE="$REPO_ROOT/ccxp/scripts/prune-drive-threads.sh"

hold() { run bash "$HOLD" "$@"; }

@test "cheap-hold: all four checks clear on a non-Friday -> hold" {
  hold --replies 0 --nightly-failures 0 --drainable 0 --clean-leg 0 --dow 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "DECISION=hold" ]
  [ "${lines[1]}" = "REASONS=none" ]
}

@test "cheap-hold: truth table, every combination of the four checks plus Friday" {
  local mask i args dow expect reasons
  for mask in $(seq 0 31); do
    args=(); expect=hold; reasons=""
    for i in 0 1 2 3; do
      local v=0; [ $(( (mask >> i) & 1 )) -eq 1 ] && v=1
      case $i in
        0) args+=(--replies "$v"); [ $v = 1 ] && { expect=full; reasons+="replies,"; } ;;
        1) args+=(--nightly-failures "$v"); [ $v = 1 ] && { expect=full; reasons+="nightly-red,"; } ;;
        2) args+=(--drainable "$v"); [ $v = 1 ] && { expect=full; reasons+="drainable-pr,"; } ;;
        3) args+=(--clean-leg "$v"); [ $v = 1 ] && { expect=full; reasons+="clean-leg,"; } ;;
      esac
    done
    dow=3
    if [ $(( (mask >> 4) & 1 )) -eq 1 ]; then dow=5; expect=full; reasons+="friday,"; fi
    hold "${args[@]}" --dow "$dow"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "DECISION=$expect" ] || { echo "mask $mask: $output"; false; }
    [ "$expect" = hold ] && reasons=none || reasons="${reasons%,}"
    [ "${lines[1]}" = "REASONS=$reasons" ] || { echo "mask $mask: $output"; false; }
  done
}

@test "cheap-hold: a check that did not run never justifies a hold" {
  hold --replies 0 --nightly-failures 0 --drainable 0 --dow 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "DECISION=full" ]
  [ "${lines[1]}" = "REASONS=unknown-clean-leg" ]
}

@test "cheap-hold: no arguments -> full with every input unknown" {
  hold --dow 2
  [ "${lines[0]}" = "DECISION=full" ]
  [ "${lines[1]}" = "REASONS=unknown-replies,unknown-nightly-failures,unknown-drainable,unknown-clean-leg" ]
}

@test "cheap-hold: Friday in the reference timezone blocks a hold when --dow is omitted" {
  # 2026-10-31T03:00Z is Saturday in UTC but still Friday evening in Chicago.
  pin_now 2026-10-31T03:00:00Z
  CCXP_REF_TZ=America/Chicago hold --replies 0 --nightly-failures 0 --drainable 0 --clean-leg 0
  [ "${lines[1]}" = "REASONS=friday" ]
  CCXP_REF_TZ=UTC hold --replies 0 --nightly-failures 0 --drainable 0 --clean-leg 0
  [ "${lines[0]}" = "DECISION=hold" ]
}

@test "cheap-hold: invalid input fails closed (exit 2, DECISION=full on stdout)" {
  hold --replies x --nightly-failures 0 --drainable 0 --clean-leg 0 --dow 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"DECISION=full"* ]]
  [[ "$output" == *"REASONS=invalid-input"* ]]
  hold --replies -1
  [ "$status" -eq 2 ]
  hold --replies 99999999999999999999 --nightly-failures 0 --drainable 0 --clean-leg 0 --dow 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"DECISION=full"* ]]
  hold --dow 9
  [ "$status" -eq 2 ]
  hold --time 25:99 --note
  [ "$status" -eq 2 ]
  hold --bogus
  [ "$status" -eq 2 ]
  hold --replies
  [ "$status" -eq 2 ]
}

@test "cheap-hold --note: renders the hold note bullets after the decision" {
  hold --replies 0 --nightly-failures 0 --drainable 0 --clean-leg 0 --dow 3 --note --time 04:03 --why "TA peer, TB supervised"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "DECISION=hold" ]
  # bats drops the blank separator line from ${lines[@]}
  [ "${lines[2]}" = "*hold 04:03Z*" ]
  [ "${lines[3]}" = "• slack: 0 new" ]
  [ "${lines[4]}" = "• nightly: green" ]
  [ "${lines[5]}" = "• drainable PR: 0" ]
  [ "${lines[6]}" = "• clean leg: 0 (TA peer, TB supervised)" ]
}

@test "cheap-hold --note: prints no note when the decision is full" {
  hold --replies 2 --nightly-failures 0 --drainable 0 --clean-leg 0 --dow 3 --note
  [ "${lines[0]}" = "DECISION=full" ]
  [[ "$output" != *'*hold'* ]]
  [ "${#lines[@]}" -eq 2 ]
}

# ---- prune-drive-threads.sh ------------------------------------------------

seed_threads() {
  F="$BATS_TEST_TMPDIR/state/drive-threads.json"
  mkdir -p "$(dirname "$F")"
  cat > "$F" <<'JSON'
{
  "T20000101-000001": {"channel_id":"C1","message_ts":"1","type":"design","summary":"old resolved","sent_at":"2026-10-01T00:00:00Z","resolved":true,"resolved_at":"2026-10-02T00:00:00Z"},
  "T20000101-000002": {"channel_id":"C1","message_ts":"2","type":"design","summary":"recent resolved","sent_at":"2026-10-01T00:00:00Z","resolved":true,"resolved_at":"2026-10-29T00:00:00Z"},
  "T20000101-000003": {"channel_id":"C1","message_ts":"3","type":"blocker","summary":"old unresolved","sent_at":"2026-09-01T00:00:00Z","resolved":false},
  "T20000101-000004": {"channel_id":"C1","message_ts":"4","type":"design","summary":"resolved, no resolved_at","sent_at":"2026-10-01T00:00:00Z","resolved":true}
}
JSON
  export NOW=2026-10-30T12:00:00Z
}

@test "prune-drive-threads: drops only resolved entries older than the window" {
  seed_threads
  run bash "$PRUNE" --file "$F"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | join(",")' "$F")" = "T20000101-000002,T20000101-000003" ]
}

@test "prune-drive-threads: --days widens the grace window" {
  seed_threads
  run bash "$PRUNE" --file "$F" --days 60
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$F")" -eq 4 ]
}

@test "prune-drive-threads: idempotent; a second run is a no-op and exits 0" {
  seed_threads
  bash "$PRUNE" --file "$F"
  before="$(cat "$F")"
  run bash "$PRUNE" --file "$F"
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$before" ]
}

@test "prune-drive-threads: a missing file is success (exit 3 from threads.sh mapped to 0)" {
  run bash "$PRUNE" --file "$BATS_TEST_TMPDIR/nope/drive-threads.json"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/nope" ]
}

@test "prune-drive-threads: THREADS_FILE is honored when --file is absent" {
  seed_threads
  THREADS_FILE="$F" run bash "$PRUNE"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$F")" -eq 2 ]
}

@test "prune-drive-threads: a malformed file is left untouched and exits non-zero" {
  F="$BATS_TEST_TMPDIR/bad.json"
  printf '{not json' > "$F"
  run bash "$PRUNE" --file "$F"
  [ "$status" -ne 0 ]
  [ "$(cat "$F")" = '{not json' ]
}

@test "prune-drive-threads: unknown flag exits 2" {
  run bash "$PRUNE" --nope
  [ "$status" -eq 2 ]
}
