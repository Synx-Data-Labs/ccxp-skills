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
 {"ref":"d13","text":"Taste for the weekly agenda lives in the profile","quote":"","source":"r1","scope":"global","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
 {"ref":"d14","text":"Block merges that skip the rebase-on-main gate","quote":"","source":"r1","scope":"repo:demo","context":"","added_at":"2026-11-10T10:00:00Z","status":"active","superseded_by":"","reason":"","closed_at":""},
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
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 12 ]
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
  [[ "$output" == *$'d3\tscript-or-hook'* ]]
  [[ "$output" == *$'d13\tprofile-config'* ]]
  [[ "$output" == *$'d14\tscript-or-hook'*$'\tscript\tdemo'* ]]   # stage and repo columns, repo from the scope
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
  for s in list overlap size bucket commands tasks retire-enforced; do run_s "$s"; [ "$status" -eq 0 ]; done
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

@test "bucket: every row carries a target stage and repo" {
  run_s bucket
  [[ "$output" == *$'d4\tpersona'*$'\tpersona\tccxp-skills'* ]]
  [[ "$output" == *$'d2\tskill-task'*$'\tskill\tdemo'* ]]
  [[ "$output" == *$'d13\tprofile-config'*$'\tprofile-config\tlocal-profile'* ]]
  [[ "$output" == *$'d10\tcontradiction'*$'\towner-review\t-'* ]]
}

mkrepo() { # a git repo whose origin/main holds scripts/gate.sh, plus an open task naming d3 and a done one naming d1, d4, d6, d9
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R/scripts" "$R/dev/TODO" "$R/dev/JOURNAL"
  git -C "$R" init -q . && echo ok > "$R/scripts/gate.sh"
  git -C "$R" add . && git -C "$R" -c user.email=a@b -c user.name=n commit -qm x
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  printf -- '---\nstatus: Open\n---\n# T20261124-111111: gate\n\n- folds d3 into scripts/gate.sh\n' > "$R/dev/TODO/T20261124-111111-gate.md"
  printf -- '# T20261124-222222: done\n\n- d1 to scripts/gate.sh, d4 to #7, d6 to #8, d9 to scripts/nope.sh fold\n' > "$R/dev/JOURNAL/2026-11-24-T20261124-222222-done.md"
  FAKE="$BATS_TEST_TMPDIR/fakegh"
  printf '#!/usr/bin/env bash\n[[ "$3" == 7 ]] && echo MERGED || echo OPEN\n' > "$FAKE"; chmod +x "$FAKE"
  export PR_GH="bash $FAKE"
}

@test "tasks: one row per conversion, deduped against open tasks naming the ref" {
  mkrepo
  run_s tasks --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d3\tscript-or-hook\tscript\tccxp-skills\texists:T20261124-111111\t'* ]]
  [[ "$output" == *$'d4\tpersona\tpersona\tccxp-skills\tfile\t'* ]]   # the done task does not dedupe
  [[ "$output" != *$'d10\t'* && "$output" != *$'d5\t'* ]]
  [ "$(cksum < "$CCXP_DECISIONS_FILE")" = "$BEFORE_DEC" ]
}

@test "retire-enforced: dry-run reports, --apply retires only merged or on-main targets with a task" {
  mkrepo
  jq '.decisions |= map(if .ref == "d1" then .enforced_by = "scripts/gate.sh"
      elif .ref == "d4" then .enforced_by = "#7" elif .ref == "d6" then .enforced_by = "#8"
      elif .ref == "d9" then .enforced_by = "scripts/nope.sh" elif .ref == "d3" then .enforced_by = "scripts/gate.sh"
      elif .ref == "d12" then .enforced_by = "T20261124-111111" else . end)' "$CCXP_DECISIONS_FILE" > "$BATS_TEST_TMPDIR/n.json"
  cp "$BATS_TEST_TMPDIR/n.json" "$CCXP_DECISIONS_FILE"
  run_s retire-enforced --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d1\twould-retire\tfolded into scripts/gate.sh (task T20261124-222222)'* ]]
  [[ "$output" == *$'d4\twould-retire\tfolded into #7'* ]]
  [[ "$output" == *$'d6\tpending\t#8 is not merged yet'* ]]
  [[ "$output" == *$'d9\tpending\tscripts/nope.sh is not on origin/main'* ]]
  [[ "$output" == *$'d12\tpending\t'*"task id"* ]]
  [[ "$output" == *$'d3\twould-retire\tfolded into scripts/gate.sh (task T20261124-111111)'* ]]
  [ "$(jq '[.decisions[] | select(.status == "retired")] | length' "$CCXP_DECISIONS_FILE")" = "1" ]
  run_s retire-enforced --repo "$R" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *$'d1\tretired\t'* && "$output" == *$'d4\tretired\t'* && "$output" == *$'d3\tretired\t'* ]]
  [ "$(jq -r '.decisions[] | select(.ref == "d1") | .status + ":" + .reason' "$CCXP_DECISIONS_FILE")" = "retired:folded into scripts/gate.sh (task T20261124-222222)" ]
  [ "$(jq -r '.decisions[] | select(.ref == "d6") | .status' "$CCXP_DECISIONS_FILE")" = "active" ]
  [ "$(jq -r '.decisions[] | select(.ref == "d9") | .status' "$CCXP_DECISIONS_FILE")" = "active" ]
}

@test "retire-enforced: a resolved target without any task naming the ref is never retired" {
  mkrepo
  jq '.decisions |= map(if .ref == "d2" then .enforced_by = "scripts/gate.sh" else . end)' "$CCXP_DECISIONS_FILE" > "$BATS_TEST_TMPDIR/n.json"
  cp "$BATS_TEST_TMPDIR/n.json" "$CCXP_DECISIONS_FILE"
  run_s retire-enforced --repo "$R" --apply
  [[ "$output" == *$'d2\tpending\tno task names both d2'* ]]
  [ "$(jq -r '.decisions[] | select(.ref == "d2") | .status' "$CCXP_DECISIONS_FILE")" = "active" ]
}

@test "retire-enforced: no enforced-by anywhere prints a note" {
  run_s retire-enforced
  [ "$status" -eq 0 ]
  [[ "$output" == *"no active decision has enforced-by"* ]]
}
