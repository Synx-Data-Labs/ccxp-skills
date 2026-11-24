#!/usr/bin/env bats
# Tests for retro/scripts/persona-review.sh (T20261124-147908, epic E2): the
# deterministic half of /retro's persona review. Read-only: it must never write
# the decisions log or the persona.

load test_helper
setup() {
  SCRIPT="$REPO_ROOT/retro/scripts/persona-review.sh"
  export CCXP_DECISIONS_FILE="$BATS_TEST_TMPDIR/ccxp-decisions.json"
  PERSONA="$BATS_TEST_TMPDIR/persona.md"
  CAP="$BATS_TEST_TMPDIR/cap.bats"
  printf '@test "x" {\n  [ "$(wc -c < "$f")" -lt 1000 ]\n}\n' > "$CAP"
  cat > "$PERSONA" <<'P'
# Persona
## CI rules
- Wait for ALL required checks before any merge, never use admin bypass.
- Alerts follow d9 when they arrive.
## Tiny
- small
P
  cat > "$CCXP_DECISIONS_FILE" <<'J'
{"schema":1,"counter":8,"decisions":[
 {"ref":"d1","text":"Wait for required checks before any merge, no admin bypass","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-01T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d2","text":"Autopilot reserves two slots for urgent work","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d3","text":"Slack channel whitelist for posting","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d4","text":"Never mention customer names in tickets","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d5","text":"Retire this decision after 2026-11-02 once tooling lands","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-01T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d6","text":"Plain note about demo logistics","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d9","text":"Handle alerts quickly","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d10","text":"Always push straight to main in repo demo","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d11","text":"Never push straight to main in repo demo","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d12","text":"Never write a long description in commit titles","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d8","text":"Old closed one","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-10-01T10:00:00Z","status":"retired","superseded_by":"","reason":"x","closed_at":"2026-10-02T00:00:00Z"}
]}
J
  BEFORE_DEC="$(cksum < "$CCXP_DECISIONS_FILE")"
  BEFORE_PER="$(cksum < "$PERSONA")"
}

run_s() { run bash "$SCRIPT" "$@" --persona "$PERSONA" --cap-file "$CAP" --today 2026-11-24; }

@test "list: active decisions only, with age and scope" {
  run_s list
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d1\t2026-11-01\t23\tglobal'* ]]
  [[ "$output" != *"d8"* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 10 ]
}

@test "list --scope filters exactly" {
  run_s list --scope repo:demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"d2"* && "$output" != *$'d1\t'* ]]
}

@test "overlap: shared words and cited refs are found with section names" {
  run_s overlap
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d1\t3\tCI rules'* ]]
  [[ "$output" == *$'d9\t4\tCI rules\tcites d9'* ]]
  [[ "$output" != *"d4"* ]]
}

@test "size: bytes, cap read from the bats file, headroom, sections largest first" {
  run_s size
  [ "$status" -eq 0 ]
  [[ "$output" == *"persona_bytes=$(wc -c < "$PERSONA" | tr -d ' ')"* ]]
  [[ "$output" == *"cap_bytes=1000"* ]]
  [[ "$output" == *"headroom_bytes="* ]]
  [[ "$output" == *"CI rules"* && "$output" == *"Tiny"* ]]
  [ "$(grep -n 'CI rules' <<<"$output" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Tiny' <<<"$output" | head -1 | cut -d: -f1)" ]
  [[ "$output" == *"(preamble)"* ]]
}

@test "size: missing cap file reports unknown, no headroom line" {
  run bash "$SCRIPT" size --persona "$PERSONA" --cap-file "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap_bytes=unknown"* && "$output" != *"headroom_bytes"* ]]
}

@test "bucket: one hint per active decision, each bucket reachable" {
  run_s bucket
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d1\talready-covered'* ]]
  [[ "$output" == *$'d2\tskill-task'* ]]
  [[ "$output" == *$'d3\tprofile-config'* ]]
  [[ "$output" == *$'d4\tpersona'* ]]
  [[ "$output" == *$'d5\tretire'* ]]
  [[ "$output" == *$'d6\tkeep-in-log'* ]]
  [[ "$output" == *$'d9\talready-covered'* ]]
  [[ "$output" == *$'d10\tcontradiction'* && "$output" == *$'d11\tcontradiction'* ]]
  [[ "$output" == *$'d12\tpersona'* ]]   # "description" must not match the word "script"
  [[ "$output" != *"d8"* ]]
}

@test "commands: prints retire lines only for retire-bucketed decisions, never runs them" {
  run_s commands
  [ "$status" -eq 0 ]
  [[ "$output" == *'decision retire d5 '* ]]
  [[ "$output" != *"decision retire d1"* ]]
  [ "$(cksum < "$CCXP_DECISIONS_FILE")" = "$BEFORE_DEC" ]
}

@test "read-only: no subcommand changes the decisions log or the persona" {
  ls -A "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/.ls-before"
  for s in list overlap size bucket commands; do run_s "$s"; [ "$status" -eq 0 ]; done
  ls -A "$BATS_TEST_TMPDIR" | diff - "$BATS_TEST_TMPDIR/.ls-before" >/dev/null || true
  [ "$(ls -A "$BATS_TEST_TMPDIR" | wc -l)" -eq "$(wc -l < "$BATS_TEST_TMPDIR/.ls-before")" ]
  [ "$(cksum < "$CCXP_DECISIONS_FILE")" = "$BEFORE_DEC" ]
  [ "$(cksum < "$PERSONA")" = "$BEFORE_PER" ]
}

@test "no decisions file: empty output, exit 0" {
  rm -f "$CCXP_DECISIONS_FILE"
  run_s bucket
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "broken ledger: commands and bucket exit 3 instead of reading as nothing to retire" {
  LEDGER=/nonexistent run bash "$SCRIPT" commands --persona "$PERSONA"
  [ "$status" -eq 3 ]
  LEDGER=/nonexistent run bash "$SCRIPT" bucket --persona "$PERSONA"
  [ "$status" -eq 3 ]
}

@test "usage errors: unknown subcommand and option exit 2, unreadable persona exits 3" {
  run bash "$SCRIPT" nope
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" list --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" bucket --persona "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 3 ]
}

@test "real persona asset: size runs against the shipped file and cap" {
  run bash "$SCRIPT" size
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap_bytes=48500"* ]]
  [[ "$output" == *"HUD job ledger"* ]]
}
