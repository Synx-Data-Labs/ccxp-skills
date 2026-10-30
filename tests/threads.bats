#!/usr/bin/env bats
# _threads/threads.sh — sole owner of drive-threads.json — and the
# ccxp/scripts/prune-drive-threads.sh wrapper that delegates to it.

load test_helper

THREADS="$REPO_ROOT/_threads/threads.sh"
PRUNE="$REPO_ROOT/ccxp/scripts/prune-drive-threads.sh"

setup() {
  F="$BATS_TEST_TMPDIR/state/drive-threads.json"
  export NOW=2026-10-30T12:00:00Z
}

seed() {
  mkdir -p "$(dirname "$F")"
  cat > "$F" <<'JSON'
{
  "T1": {"channel_id":"C1","message_ts":"1","type":"design","summary":"old resolved","sent_at":"2026-10-01T00:00:00Z","resolved":true,"resolved_at":"2026-10-02T00:00:00Z"},
  "T2": {"channel_id":"C1","message_ts":"2","type":"design","summary":"recent resolved","sent_at":"2026-10-01T00:00:00Z","resolved":true,"resolved_at":"2026-10-29T00:00:00Z"},
  "T3": {"channel_id":"C1","message_ts":"3","type":"blocker","summary":"old but unresolved","sent_at":"2026-09-01T00:00:00Z","resolved":false},
  "T4": {"channel_id":"C1","message_ts":"4","type":"design","summary":"resolved, no resolved_at","sent_at":"2026-10-01T00:00:00Z","resolved":true}
}
JSON
}
t() { bash "$THREADS" --file "$F" "$@"; }

@test "add creates the file and directory with the documented shape" {
  run t add T9 --channel C9 --ts 123.4 --type design-decision --summary "pick a queue"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.T9 | [.channel_id,.message_ts,.type,.summary,.sent_at,(.resolved|tostring)] | join("|")' "$F")" \
     = "C9|123.4|design-decision|pick a queue|2026-10-30T12:00:00Z|false" ]
}

@test "add replaces an existing entry for the same key and keeps the others" {
  seed
  run t add T3 --channel C2 --ts 9 --type blocker --summary "again" --sent-at 2026-10-30T01:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r '.T3.summary' "$F")" = again ]
  [ "$(jq -r '.T3.resolved' "$F")" = false ]
  [ "$(jq 'length' "$F")" = 4 ]
}

@test "add requires its fields (exit 2) and writes nothing" {
  run t add T9 --channel C9
  [ "$status" -eq 2 ]
  [ ! -e "$F" ]
  run t add
  [ "$status" -eq 2 ]
}

@test "resolve marks resolved with resolved_at and optional resolution" {
  seed
  run t resolve T3 --at 2026-10-30T00:00:00Z --resolution "answered in thread"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.T3 | [(.resolved|tostring),.resolved_at,.resolution] | join("|")' "$F")" \
     = "true|2026-10-30T00:00:00Z|answered in thread" ]
}

@test "resolve exits 3 for an absent key, an already-resolved key, or a missing file" {
  seed
  run t resolve NOPE;  [ "$status" -eq 3 ]
  run t resolve T1;    [ "$status" -eq 3 ]
  [ "$(jq -r '.T1.resolved_at' "$F")" = 2026-10-02T00:00:00Z ]   # untouched
  run bash "$THREADS" --file "$BATS_TEST_TMPDIR/none.json" resolve T1
  [ "$status" -eq 3 ]
}

@test "list prints TSV; --unresolved filters; a missing file lists nothing" {
  seed
  run t list
  [ "${#lines[@]}" -eq 4 ]
  run t list --unresolved
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == $'T3\tfalse\tblocker\t2026-09-01T00:00:00Z\told but unresolved' ]]
  run bash "$THREADS" --file "$BATS_TEST_TMPDIR/none.json" list
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "prune drops only resolved entries older than the window (resolved_at, else sent_at)" {
  seed
  run t prune --days 7
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | join(",")' "$F")" = "T2,T3" ]
}

@test "prune honors the window: a wider one keeps more" {
  seed
  run t prune --days 40
  [ "$status" -eq 3 ]
  [ "$(jq 'length' "$F")" = 4 ]
}

@test "prune is idempotent and leaves the file byte-identical when nothing is dropped" {
  seed
  t prune --days 7
  cp "$F" "$BATS_TEST_TMPDIR/after1.json"
  run t prune --days 7
  [ "$status" -eq 3 ]
  cmp "$F" "$BATS_TEST_TMPDIR/after1.json"
}

@test "a malformed state file is never modified by any writer (exit 4)" {
  mkdir -p "$(dirname "$F")"; printf '{ not json' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/bad.json"
  run t add T9 --channel C --ts 1 --type t --summary s;  [ "$status" -eq 4 ]
  run t resolve T9;                                       [ "$status" -eq 4 ]
  run t prune;                                            [ "$status" -eq 4 ]
  run t list;                                             [ "$status" -eq 4 ]
  cmp "$F" "$BATS_TEST_TMPDIR/bad.json"
}

@test "a JSON array (wrong top-level type) is treated as malformed" {
  mkdir -p "$(dirname "$F")"; echo '[]' > "$F"
  run t add T9 --channel C --ts 1 --type t --summary s
  [ "$status" -eq 4 ]
}

@test "--dry-run prints the would-be file and writes nothing" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before.json"
  run t --dry-run resolve T3
  [ "$status" -eq 0 ]
  [ "$(jq -r '.T3.resolved' <<<"$output")" = true ]
  cmp "$F" "$BATS_TEST_TMPDIR/before.json"
  run t --dry-run add T7 --channel C --ts 1 --type t --summary s
  [ "$status" -eq 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before.json"
}

@test "writes leave no temp files behind" {
  seed
  t resolve T3
  t add T8 --channel C --ts 1 --type t --summary s
  [ "$(find "$(dirname "$F")" -type f | wc -l | tr -d ' ')" = 1 ]
}

@test "THREADS_FILE env is the default file" {
  THREADS_FILE="$F" run bash "$THREADS" add T5 --channel C --ts 1 --type t --summary s
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys[0]' "$F")" = T5 ]
}

@test "unknown command and unknown flag exit 2" {
  run t bogus;                 [ "$status" -eq 2 ]
  run t list-all;              [ "$status" -eq 2 ]
  run t prune --weeks 1;       [ "$status" -eq 2 ]
}

@test "prune-drive-threads.sh: same CLI, prunes via the shared lib, exits 0 on nothing to do" {
  seed
  run bash "$PRUNE" --file "$F" --days 7
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | join(",")' "$F")" = "T2,T3" ]
  run bash "$PRUNE" --file "$F" --days 7
  [ "$status" -eq 0 ]
}

@test "prune-drive-threads.sh: missing file is a no-op; malformed file is untouched and fails; bad flag exits 2" {
  run bash "$PRUNE" --file "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ]
  mkdir -p "$(dirname "$F")"; printf 'oops' > "$F.bad"
  run bash "$PRUNE" --file "$F.bad"
  [ "$status" -eq 4 ]
  [ "$(cat "$F.bad")" = oops ]
  run bash "$PRUNE" --nope
  [ "$status" -eq 2 ]
}

@test "a flag without its value is a usage error (exit 2), not an abort" {
  run t add T9 --channel
  [ "$status" -eq 2 ]
  run t prune --days
  [ "$status" -eq 2 ]
}

@test "an object whose values are not objects is malformed (exit 4), left untouched" {
  mkdir -p "$(dirname "$F")"; echo '{"a":"str"}' > "$F"
  run t prune;  [ "$status" -eq 4 ]
  run t resolve a; [ "$status" -eq 4 ]
  [ "$(cat "$F")" = '{"a":"str"}' ]
}
