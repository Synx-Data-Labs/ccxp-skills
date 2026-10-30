#!/usr/bin/env bats
# Tests for drive/scripts/preflight.sh and drive/scripts/cross-repo-guard.sh.
# Offline: a throwaway repo, an isolated claimant identity, the shared fake gh.

load test_helper
PREFLIGHT="$REPO_ROOT/drive/scripts/preflight.sh"
GUARD="$REPO_ROOT/drive/scripts/cross-repo-guard.sh"
ID="T20000101-000001"

setup() {
  isolate_claimant_state
  unset DRIVE_STRICT_CLONE LINT_FROZEN_IDS TASK_CLAIM_DIR
  WS="$BATS_TEST_TMPDIR/ws"
  HUB="$WS/hub"
  mkdir -p "$WS"
  make_fixture_repo "$HUB" >/dev/null
  git -C "$HUB" remote add origin https://github.com/acme/hub.git
  mkdir -p "$HUB/dev/PARKING"
  cd "$HUB"
}

_task() { # <dir> [claimed_by] — task file with frontmatter and a body that mentions claimed_by
  mkdir -p "dev/$1"
  printf -- '---\nstatus: Open\nclaimed_by: %s\n---\n\n# %s\n\nBody text: claimed_by: someone-else\n' "${2:-}" "$ID" > "dev/$1/$ID-thing.md"
}
_pf() { run bash "$PREFLIGHT" "$@"; }
_mine() { bash "$REPO_ROOT/_session/task_claim.sh" claimant-id; }

# A task_claim.sh stand-in: real read/claimant-id, scripted reclaimable verdict.
_claim_stub() {
  cat > "$BATS_TEST_TMPDIR/claim-stub.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = reclaimable ]; then echo "\${STUB_RECLAIM:-live}"; exit 0; fi
exec bash "$REPO_ROOT/_session/task_claim.sh" "\$@"
STUB
  export TASK_CLAIM_SH="$BATS_TEST_TMPDIR/claim-stub.sh"
}

# --- preflight: arguments and the Phase 0 skip rule --------------------------

@test "preflight: usage errors exit 2" {
  _pf; [ "$status" -eq 2 ]
  _pf not-an-id; [ "$status" -eq 2 ]
  _pf "$ID" --bogus; [ "$status" -eq 2 ]
  _pf "$ID" T20000101-000002; [ "$status" -eq 2 ]
}

@test "preflight: bare auto-pick is go and never skips Phase 0" {
  _pf -
  [ "$status" -eq 0 ]; [ "$output" = "verdict=go phase0=run detail=auto-pick" ]
  _pf - --auto-selected
  [ "$output" = "verdict=go phase0=run detail=auto-pick" ]
}

@test "preflight: a human's explicit id skips Phase 0; --auto-selected does not" {
  _task TODO
  _pf "$ID"
  [ "$status" -eq 0 ]; [ "$output" = "verdict=go phase0=skip detail=free" ]
  _pf "$ID" --auto-selected
  [ "$status" -eq 0 ]; [ "$output" = "verdict=go phase0=run detail=free" ]
  _pf --auto-selected "$ID"
  [ "$output" = "verdict=go phase0=run detail=free" ]
}

# --- preflight: gates --------------------------------------------------------

@test "preflight: absent from every dev dir is cross-repo (12), naming the sibling clone's slug" {
  mkdir -p "$WS/other/dev/TODO"
  git -C "$WS/other" init -q
  git -C "$WS/other" remote add origin https://github.com/acme/other.git
  : > "$WS/other/dev/TODO/$ID-thing.md"
  _pf "$ID"
  [ "$status" -eq 12 ]
  [[ "$output" == "verdict=cross-repo phase0=skip detail=not in this clone; clone acme/other fresh" ]]
}

@test "preflight: cross-repo with no sibling says the slug is unknown; strict mode is named" {
  _pf "$ID"
  [ "$status" -eq 12 ]; [[ "$output" == *"slug unknown"* ]]; [[ "$output" != *STRICT* ]]
  DRIVE_STRICT_CLONE=1 _pf "$ID"
  [ "$status" -eq 12 ]; [[ "$output" == *"DRIVE_STRICT_CLONE=1 refuses"* ]]
}

@test "preflight: a task only in dev/JOURNAL is closed (13)" {
  _task JOURNAL
  _pf "$ID"
  [ "$status" -eq 13 ]; [[ "$output" == verdict=closed* ]]
}

@test "preflight: a claim by another live session is held (10)" {
  _task TODO "cc1-deadbeef:0123456789abcdef"
  _claim_stub; STUB_RECLAIM=live _pf "$ID"
  [ "$status" -eq 10 ]; [[ "$output" == "verdict=held "*"cc1-deadbeef:0123456789abcdef"* ]]
}

@test "preflight: a stale foreign claim is reclaimable, so go" {
  _task TODO "cc1-deadbeef:0123456789abcdef"
  _claim_stub; STUB_RECLAIM=reclaimable _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"detail=reclaimable"* ]]
}

@test "preflight: this clone's own claim is go (mine)" {
  _task TODO "$(_mine)"
  _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"detail=mine" ]]
}

@test "preflight: claimed_by text in the body is not a claim" {
  _task TODO ""
  _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"detail=free" ]]
}

@test "preflight: a lint-frozen task is frozen (11)" {
  _task TODO
  LINT_FROZEN_IDS="$ID" _pf "$ID"
  [ "$status" -eq 11 ]; [[ "$output" == verdict=frozen* ]]
  LINT_FROZEN_IDS="T20000101-000999" _pf "$ID"
  [ "$status" -eq 0 ]
}

@test "preflight: held wins over frozen (gate order)" {
  _task TODO "cc1-deadbeef:0123456789abcdef"
  _claim_stub
  LINT_FROZEN_IDS="$ID" STUB_RECLAIM=live _pf "$ID"
  [ "$status" -eq 10 ]
}

@test "preflight: CCXP_PEER_MODE=0 skips the claim gate but not the freeze gate" {
  _task TODO "cc1-deadbeef:0123456789abcdef"
  _claim_stub
  CCXP_PEER_MODE=0 STUB_RECLAIM=live _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"peer mode off"* ]]
  CCXP_PEER_MODE=0 LINT_FROZEN_IDS="$ID" _pf "$ID"
  [ "$status" -eq 11 ]
}

@test "preflight: a parked task passes with a note instead of failing the claim read" {
  _task PARKING
  _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"parked?"* ]]
}

# --- cross-repo-guard --------------------------------------------------------

_gh_pass() { printf '#!/usr/bin/env bash\nexec gh "$@"\n' > "$BATS_TEST_TMPDIR/ghpass.sh"; export GH_SH="$BATS_TEST_TMPDIR/ghpass.sh"; }
_fx() { # <json>
  mkdir -p "$BATS_TEST_TMPDIR/fx"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/fx/pr_list_repo_acme_target_search_${ID//-/_}_state_all.json"
  fake_gh "$BATS_TEST_TMPDIR/fx"; _gh_pass
}

@test "guard: usage errors exit 2" {
  run bash "$GUARD"; [ "$status" -eq 2 ]
  run bash "$GUARD" "$ID"; [ "$status" -eq 2 ]
  run bash "$GUARD" nope acme/target; [ "$status" -eq 2 ]
  run bash "$GUARD" "$ID" "not a repo"; [ "$status" -eq 2 ]
}

@test "guard: an open PR wins: prints its number and branch, and the search is scoped to the target repo" {
  _fx '[{"number":9,"state":"MERGED","title":"t","headRefName":"t-old","url":"u"},{"number":12,"state":"OPEN","title":"t","headRefName":"t20000101-000001-impl","url":"u"}]'
  run bash "$GUARD" "$ID" acme/target
  [ "$status" -eq 0 ]; [ "$output" = "open 12 t20000101-000001-impl" ]
  assert_calls "$FAKE_GH_LOG" "^pr list --repo acme/target --search $ID --state all"
}

@test "guard: several open PRs (a duplicate run) report the lowest number and warn on stderr" {
  _fx '[{"number":30,"state":"OPEN","title":"t","headRefName":"b30","url":"u"},{"number":20,"state":"OPEN","title":"t","headRefName":"b20","url":"u"}]'
  run bash -c "bash '$GUARD' '$ID' acme/target 2>'$BATS_TEST_TMPDIR/err'"
  [ "$output" = "open 20 b20" ]; grep -q '#30' "$BATS_TEST_TMPDIR/err"
}

@test "guard: only a merged PR is merged, with the newest number" {
  _fx '[{"number":9,"state":"MERGED","title":"t","headRefName":"a","url":"u"},{"number":11,"state":"MERGED","title":"t","headRefName":"b","url":"u"},{"number":10,"state":"CLOSED","title":"t","headRefName":"c","url":"u"}]'
  run bash "$GUARD" "$ID" acme/target
  [ "$status" -eq 0 ]; [ "$output" = "merged 11" ]
}

@test "guard: no match, or only a closed-unmerged PR, is none" {
  _fx '[]'
  run bash "$GUARD" "$ID" acme/target; [ "$status" -eq 0 ]; [ "$output" = none ]
  _fx '[{"number":10,"state":"CLOSED","title":"t","headRefName":"c","url":"u"}]'
  run bash "$GUARD" "$ID" acme/target; [ "$output" = none ]
}

@test "guard: a gh failure is exit 3, never none" {
  _fx '[]'
  FAKE_GH_FAIL='^pr list' run bash "$GUARD" "$ID" acme/target
  [ "$status" -eq 3 ]; [[ "$output" != none ]]
}

@test "guard: non-JSON gh output is exit 3" {
  _fx 'HTTP 502 bad gateway'
  run bash "$GUARD" "$ID" acme/target
  [ "$status" -eq 3 ]
}
