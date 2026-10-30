#!/usr/bin/env bats
# Tests for drive/scripts/{preflight,cross-repo-guard,classify-change,verify-close}.sh.
# Offline: a throwaway repo, an isolated claimant identity, the shared fake gh.

load test_helper
PREFLIGHT="$REPO_ROOT/drive/scripts/preflight.sh"
GUARD="$REPO_ROOT/drive/scripts/cross-repo-guard.sh"
CLASSIFY="$REPO_ROOT/drive/scripts/classify-change.sh"
VCLOSE="$REPO_ROOT/drive/scripts/verify-close.sh"
THREADS="$REPO_ROOT/_threads/threads.sh"
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
  [[ "$output" == "verdict=cross-repo phase0=skip detail=not in this clone; hub is acme/other; clone it fresh" ]]
}

@test "preflight: cross-repo with no sibling says the slug is unknown" {
  _pf "$ID"
  [ "$status" -eq 12 ]; [[ "$output" == *"slug could not be detected"* ]]
}

@test "preflight: DRIVE_STRICT_CLONE=1 turns cross-repo into refused (14) but leaves closed alone" {
  DRIVE_STRICT_CLONE=1 _pf "$ID"
  [ "$status" -eq 14 ]; [[ "$output" == verdict=refused* ]]
  _task JOURNAL
  DRIVE_STRICT_CLONE=1 _pf "$ID"
  [ "$status" -eq 13 ]
}

@test "preflight: the task file is matched by whole id, not by prefix" {
  mkdir -p dev/TODO
  printf -- '---\nstatus: Open\nclaimed_by: cc1-deadbeef:0123456789abcdef\n---\n' > dev/TODO/T20000101-0000019-longer.md
  _pf "$ID"
  [ "$status" -eq 0 ]; [[ "$output" == *"no task file"* ]]
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

# --- classify-change ---------------------------------------------------------

_branch_with() { # <path>... — commit each path on a feature branch off main
  git checkout -q -b feat
  local p
  for p in "$@"; do mkdir -p "$(dirname "$p")"; echo x > "$p"; done
  git add -A; git commit -q -m change
}

@test "classify: usage errors exit 2; outside a repo exit 3" {
  run bash "$CLASSIFY" a b; [ "$status" -eq 2 ]
  run bash "$CLASSIFY" --bogus; [ "$status" -eq 2 ]
  cd "$BATS_TEST_TMPDIR"; run env GIT_DIR=/nonexistent bash "$CLASSIFY"; [ "$status" -eq 3 ]
}

@test "classify: no change is empty" {
  git checkout -q -b feat
  run bash "$CLASSIFY"; [ "$status" -eq 0 ]; [ "$output" = empty ]
}

@test "classify: docs-only paths at any depth are docs" {
  _branch_with dev/TODO/T1-x.md docs/a/b.txt pkg/docs/guide.txt README.md sub/CLAUDE.md x/SKILL.md \
    .github/ISSUE_TEMPLATE/bug.yml .github/pull_request_template.md
  run bash "$CLASSIFY"; [ "$status" -eq 0 ]; [ "$output" = docs ]
}

@test "classify: any code path makes the whole change code (mixed = code)" {
  _branch_with README.md scripts/run.sh
  run bash "$CLASSIFY"; [ "$output" = code ]
}

@test "classify: workflows, bats, Makefile and a dev-named source dir are code" {
  local f
  for f in .github/workflows/ci.yml tests/x.bats Makefile src/dev/tool.sh; do
    git checkout -q main; git branch -q -D feat 2>/dev/null || true
    _branch_with "$f"
    run bash "$CLASSIFY"; [ "$output" = code ] || { echo "$f -> $output"; return 1; }
  done
}

@test "classify: an explicit base is honoured and a missing base falls back to the working tree" {
  git checkout -q -b feat
  echo x > a.sh; git add a.sh; git commit -q -m a
  git checkout -q -b feat2; echo y > b.md; git add b.md; git commit -q -m b
  run bash "$CLASSIFY" feat; [ "$output" = docs ]
  run bash "$CLASSIFY" main; [ "$output" = code ]
  git checkout -q main; echo z > new.sh
  run bash "$CLASSIFY" no-such-ref; [ "$status" -eq 0 ]; [ "$output" = code ]
  rm -f new.sh; mkdir newdir; echo q > newdir/a.md
  run bash "$CLASSIFY" no-such-ref; [ "$output" = docs ]
}

# --- verify-close ------------------------------------------------------------

_close() { # [status] [claimed_by] [closed:yes|no] [mode:mv-edit|mv-only] — task moves TODO -> JOURNAL on a branch
  local st="${1:-Done}" cb="${2:-}" closed="${3:-yes}" mode="${4:-mv-edit}"
  _task TODO "x"; git add -A; git commit -q -m "add task"
  git checkout -q -b close
  local j="dev/JOURNAL/2026-01-01-$ID-thing.md"
  git mv "dev/TODO/$ID-thing.md" "$j"
  if [ "$mode" = mv-edit ]; then
    {
      printf -- '---\nstatus: %s\nclaimed_by: %s\n---\n\n# %s\n\nBody text: claimed_by: someone-else\n' "$st" "$cb" "$ID"
      [ "$closed" = yes ] && printf '\n## Closed (2026-01-01)\n\nShipped.\n'
    } > "$j"
    git add "$j"
  fi
  git commit -q -m close
  VC_FILE="$j"
}

@test "verify-close: usage errors exit 2" {
  run bash "$VCLOSE"; [ "$status" -eq 2 ]
  run bash "$VCLOSE" nope; [ "$status" -eq 2 ]
  run bash "$VCLOSE" "$ID" --base; [ "$status" -eq 2 ]
  run bash "$VCLOSE" "$ID" extra; [ "$status" -eq 2 ]
}

@test "verify-close: a proper close passes, and a body mention of claimed_by is ignored" {
  _close
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 0 ]; [ "$output" = "ok $VC_FILE" ]
}

@test "verify-close: a pure 100% rename fails on rename, status and closed" {
  _close Done "" yes mv-only
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rename"* ]]; [[ "$output" == *"FAIL status"* ]]; [[ "$output" == *"FAIL closed"* ]]
}

@test "verify-close: unstaged edits after git mv are caught as uncommitted" {
  _close Done "" yes mv-only
  printf '\n## Closed (2026-01-01)\n' >> "$VC_FILE"
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL committed"* ]]
}

@test "verify-close: a surviving claim and a non-Done status are listed together" {
  _close "In Progress" "host-1234"
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL status: status is 'In Progress'"* ]]; [[ "$output" == *"FAIL claim: claimed_by is still 'host-1234'"* ]]
}

@test "verify-close: a missing Closed section fails" {
  _close Done "" no
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 1 ]; [ "$output" = "FAIL closed: no '## Closed (YYYY-MM-DD)' section" ]
}

@test "verify-close: a task left in dev/TODO, or never journaled, fails on moved" {
  _task TODO; git add -A; git commit -q -m t
  run bash "$VCLOSE" "$ID"
  [ "$status" -eq 1 ]; [[ "$output" == *"FAIL moved"* ]]
}

@test "verify-close: the rename check is skipped when the base does not resolve (post-merge on main)" {
  _close Done "" yes mv-only
  git checkout -q main; git merge -q --ff-only close
  run bash "$VCLOSE" "$ID" --base no-such-ref
  [[ "$output" != *"FAIL rename"* ]]; [[ "$output" == *"FAIL closed"* ]]
}

# --- threads adoption (drive Phase 0.5 / Sending use _threads/threads.sh) ----

@test "drive threads: an escalation is recorded, superseded by a re-send, then resolved" {
  export THREADS_FILE="$BATS_TEST_TMPDIR/state/drive-threads.json"
  run bash "$THREADS" add "$ID" --channel C1 --ts 1.1 --type design-decision --summary "pick A or B"
  [ "$status" -eq 0 ]
  run bash "$THREADS" add "$ID" --channel C1 --ts 2.2 --type design-decision --summary "pick A or B again"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg k "$ID" '.[$k].message_ts' "$THREADS_FILE")" = 2.2 ]
  run bash "$THREADS" list --unresolved; [[ "$output" == "$ID"* ]]
  run bash "$THREADS" resolve "$ID" --resolution "go with A"; [ "$status" -eq 0 ]
  run bash "$THREADS" list --unresolved; [ -z "$output" ]
  run bash "$THREADS" resolve "$ID"; [ "$status" -eq 3 ]
}

@test "drive skills: SKILL.md files no longer hand-edit drive-threads.json and cite the scripts" {
  run grep -n 'jq .*drive-threads' "$REPO_ROOT/drive/SKILL.md" "$REPO_ROOT/retro/SKILL.md" "$REPO_ROOT/ccxp/SKILL.md"
  [ "$status" -eq 1 ]
  grep -q 'drive/scripts/classify-change.sh' "$REPO_ROOT/drive/SKILL.md"
  grep -q 'drive/scripts/verify-close.sh' "$REPO_ROOT/drive/SKILL.md"
  grep -q '_threads/threads.sh' "$REPO_ROOT/drive/SKILL.md"
  grep -q '_threads/threads.sh' "$REPO_ROOT/retro/SKILL.md"
}
