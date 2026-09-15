#!/usr/bin/env bats
# Tests for ccxp/scripts/epic-status.sh — the token-free, hub-repo epic
# rollup for the ccxp daily standup (T20260911-347027). Same
# ROADMAP_TARGET_REPO / ENV_FILE / ~/.claude/.env resolution convention as
# ccxp/scripts/update-roadmap.sh (see tests/update_roadmap.bats).
#
# I/O is hermetic throughout:
#   - a throwaway git repo under $BATS_TEST_TMPDIR stands in for the
#     CONSUMER (local) repo that dev/TODO|PARKING|JOURNAL resolve against;
#   - a plain directory tree (tests/fixtures/epics/fake-gh.sh's
#     EPIC_FAKE_GH_HUB_DIR) stands in for the HUB repo's contents, served
#     through a fake `gh` on $PATH — see that script's own header for the
#     full fake-gh contract;
#   - $TMPDIR is pointed at $BATS_TEST_TMPDIR so _gh/gh.sh's account-pick
#     cache (normally a real /tmp file, shared across processes) can't leak
#     between tests.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/ccxp/scripts/epic-status.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/epics"

  unset ROADMAP_TARGET_REPO ENV_FILE EPIC_FAKE_GH_EPICS_MISSING EPIC_FAKE_GH_PR_FOR_ID

  export TMPDIR="$BATS_TEST_TMPDIR"

  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$FIXTURES/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  export PATH="$FAKEBIN:$PATH"
  export EPIC_FAKE_GH_CALLLOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : > "$EPIC_FAKE_GH_CALLLOG"

  # --- local (consumer) repo -------------------------------------------
  LOCAL_REPO="$BATS_TEST_TMPDIR/local-repo"
  mkdir -p "$LOCAL_REPO/dev/TODO" "$LOCAL_REPO/dev/PARKING" "$LOCAL_REPO/dev/JOURNAL"
  (
    cd "$LOCAL_REPO"
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git remote add origin git@github.com:local-org/local-repo.git
    cp "$FIXTURES/task-open.md"    dev/TODO/T20260101-000001-open.md
    cp "$FIXTURES/task-design.md"  dev/TODO/T20260101-000002-design.md
    cp "$FIXTURES/task-coding.md"  dev/TODO/T20260101-000003-coding.md
    cp "$FIXTURES/task-review.md"  dev/TODO/T20260101-000004-review.md
    cp "$FIXTURES/task-done.md"    dev/JOURNAL/T20260101-000005-done.md
    cp "$FIXTURES/task-blocked.md" dev/TODO/T20260101-000006-blocked.md
    cp "$FIXTURES/task-parked.md"  dev/PARKING/T20260101-000007-parked.md
    git add dev
    git commit -q -m "fixture tasks"
  )

  # --- hub repo tree (served by fake-gh.sh via EPIC_FAKE_GH_HUB_DIR) ----
  HUB_DIR="$BATS_TEST_TMPDIR/hub-tree"
  mkdir -p "$HUB_DIR/dev/TODO" "$HUB_DIR/dev/PARKING" "$HUB_DIR/dev/JOURNAL"
  cp "$FIXTURES/EPICS.md" "$HUB_DIR/dev/EPICS.md"
  cp "$FIXTURES/hub-task-todo.md" "$HUB_DIR/dev/TODO/T20260202-000001-hub-todo.md"
  cp "$FIXTURES/hub-task-journal.md" "$HUB_DIR/dev/JOURNAL/T20260202-000002-hub-journal.md"
  export EPIC_FAKE_GH_HUB_DIR="$HUB_DIR"

  # --- two-account gh setup: "hub-user" can see the hub slug, "other-user"
  #     can see the local repo's slug. Every hub-scoped call in
  #     epic-status.sh must end up using hub-user's token regardless of
  #     $PWD's own origin.
  export ROADMAP_TARGET_REPO="hub-org/hub-repo"
  export EPIC_FAKE_GH_ACCOUNTS="hub-user other-user"
  export EPIC_FAKE_GH_ACCESS="hub-user-token hub-org/hub-repo
other-user-token local-org/local-repo"
  export EPIC_FAKE_GH_COMMIT_DATE="2026-09-01T00:00:00Z"   # >7 days before "now" in this suite's fixture dates

  cd "$LOCAL_REPO"
  SKILLS_ROOT="$REPO_ROOT"
  export SKILLS_ROOT
}

_split_resolve() {
  # $1 = one epic_resolve TSV line -> sets st/claimed/src/repo/path/epoch.
  # NOT `IFS=$'\t' read -r ... <<<"$1"`: tab is "IFS whitespace" to bash's
  # `read` regardless of what IFS is set to, so an empty column (claimed_by
  # routinely is) collapses two adjacent tabs into one delimiter and shifts
  # every field after it — verified: `printf 'x\t\ty' | IFS=$'\t' read -r a
  # b c` gives b="y" c="", not b="" c="y". awk's -F'\t' has no such
  # collapsing (same fix applied in epic-status.sh's own epic_render).
  local f
  mapfile -t f < <(awk -F'\t' '{for (i=1;i<=6;i++) print $i}' <<<"$1")
  st="${f[0]}"; claimed="${f[1]}"; src="${f[2]}"; repo="${f[3]}"; path="${f[4]}"; epoch="${f[5]}"
}

# ============================================================================
# env resolution
# ============================================================================

@test "_epic_status_load_env: no default — ROADMAP_TARGET_REPO empty with nothing configured" {
  result=$(env -u ROADMAP_TARGET_REPO -u ENV_FILE bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

@test "_epic_status_load_env: ENV_FILE override wins when set" {
  envfile="$BATS_TEST_TMPDIR/custom.env"
  cat > "$envfile" <<'EOF'
ROADMAP_TARGET_REPO=some-org/some-repo
EOF
  result=$(env -u ROADMAP_TARGET_REPO ENV_FILE="$envfile" bash -c "source '$SCRIPT'; echo \"\$ROADMAP_TARGET_REPO\"")
  [ "$result" = "some-org/some-repo" ]
}

@test "_epic_status_load_env: already-exported ROADMAP_TARGET_REPO is left alone (no file needed)" {
  result=$(ROADMAP_TARGET_REPO=preset-org/preset-repo bash -c "source '$SCRIPT'; echo \"\$ROADMAP_TARGET_REPO\"")
  [ "$result" = "preset-org/preset-repo" ]
}

@test "_epic_status_load_env: does not abort the shell when ~/.claude/.env is absent (real, non-BATS code path)" {
  fakehome="$BATS_TEST_TMPDIR/no-env-here"
  mkdir -p "$fakehome"
  result=$(env -u ROADMAP_TARGET_REPO -u ENV_FILE -u BATS_TEST_TMPDIR HOME="$fakehome" \
    bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

@test "_epic_status_load_env: a failing last statement in ~/.claude/.env degrades to unset, does not abort" {
  fakehome="$BATS_TEST_TMPDIR/bad-home-env"
  mkdir -p "$fakehome/.claude"
  echo 'false' > "$fakehome/.claude/.env"
  result=$(env -u ROADMAP_TARGET_REPO -u ENV_FILE -u BATS_TEST_TMPDIR HOME="$fakehome" \
    bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

# ============================================================================
# epic_fetch
# ============================================================================

@test "epic_fetch: returns 1 and prints nothing when ROADMAP_TARGET_REPO is unset" {
  run env -u ROADMAP_TARGET_REPO -u ENV_FILE PATH="$PATH" \
    bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "epic_fetch: returns 1 when no authenticated gh account can access the hub repo" {
  run env EPIC_FAKE_GH_ACCESS="other-user-token local-org/local-repo" \
    bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 1 ]
}

@test "epic_fetch: returns 1 when dev/EPICS.md does not exist in the hub repo (404 / empty content)" {
  run env EPIC_FAKE_GH_EPICS_MISSING=1 bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 1 ]
}

@test "epic_fetch: on success, base64-decodes to a tmp file matching EPICS.md byte-for-byte" {
  run bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  diff -q "$output" "$FIXTURES/EPICS.md"
  rm -f "$output"
}

# ============================================================================
# epic_parse_file
# ============================================================================

@test "epic_parse_file: extracts EPIC/GOAL/DONE/DEADLINE/TASK records for all 3 epics" {
  run bash -c "source '$SCRIPT'; epic_parse_file '$FIXTURES/EPICS.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'EPIC\tE1\tShip the pgrx bump'* ]]
  [[ "$output" == *$'EPIC\tE2\tCross-repo compliance audit'* ]]
  [[ "$output" == *$'EPIC\tE3\tKeep vendor egress under budget'* ]]
  [[ "$output" == *$'GOAL\tE1\tkeep the pgrx bump shippable through the next major Postgres release'* ]]
  [[ "$output" == *$'DEADLINE\tE1\t2026-12-31'* ]]
  [[ "$output" == *$'TASK\tE1\tT20260101-000001'* ]]
  [[ "$output" == *$'TASK\tE3\tT20260101-000003'* ]]
}

@test "epic_parse_file: an epic with no Deadline: line omits DEADLINE but keeps GOAL/DONE/TASK" {
  run bash -c "source '$SCRIPT'; epic_parse_file '$FIXTURES/EPICS.md'"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'DEADLINE\tE2\t'* ]]
  [[ "$output" == *$'GOAL\tE2\tpass the compliance audit by Q3'* ]]
  [[ "$output" == *$'DONE\tE2\taudit sign-off received from the compliance team'* ]]
  [[ "$output" == *$'TASK\tE2\tT20260202-000001'* ]]
}

@test "epic_parse_file: a task bullet with trailing prose after the ID still yields the bare Tid" {
  run bash -c "source '$SCRIPT'; epic_parse_file '$FIXTURES/EPICS.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'TASK\tE1\tT20260101-000004'* ]]
  [[ "$output" != *"near done"* ]]
}

@test "epic_parse_file: EPICS-empty.md yields zero EPIC records" {
  run bash -c "source '$SCRIPT'; epic_parse_file '$FIXTURES/EPICS-empty.md'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"EPIC"$'\t'* ]]
}

# ============================================================================
# epic_resolve — local
# ============================================================================

@test "epic_resolve: resolves status + claimed_by + a numeric epoch from dev/TODO" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000001"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Open" ]
  [ "$src" = "local" ]
  [[ "$epoch" =~ ^[0-9]+$ ]]
}

@test "epic_resolve: resolves status from dev/PARKING" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000007"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Parked" ]
  [ "$src" = "local" ]
}

@test "epic_resolve: resolves status from dev/JOURNAL (Done)" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000005"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Done" ]
  [ "$src" = "local" ]
}

@test "epic_resolve: local resolution takes precedence over the hub, same id in both" {
  decoy_hub="$BATS_TEST_TMPDIR/hub-tree-decoy"
  mkdir -p "$decoy_hub/dev/TODO"
  cp "$HUB_DIR/dev/EPICS.md" "$decoy_hub/dev/EPICS.md"
  # Decoy hub copy of the id that ALSO exists locally, with a different status.
  cp "$FIXTURES/task-blocked.md" "$decoy_hub/dev/TODO/T20260101-000001-decoy.md"
  run env EPIC_FAKE_GH_HUB_DIR="$decoy_hub" bash -c "source '$SCRIPT'; epic_resolve T20260101-000001"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$src" = "local" ]
  [ "$st" = "Open" ]   # the LOCAL file's status, not the decoy hub's "Blocked by..."
}

# ============================================================================
# epic_resolve — hub fallback
# ============================================================================

@test "epic_resolve: falls back to the hub dev/TODO contents search when not found locally" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260202-000001"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Open" ]
  [ "$src" = "hub" ]
  [ "$repo" = "hub-org/hub-repo" ]
  [[ "$path" == dev/TODO/T20260202-000001* ]]
}

@test "epic_resolve: falls back to the hub dev/JOURNAL contents search when not in TODO/PARKING either" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260202-000002"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Done" ]
  [ "$src" = "hub" ]
  [[ "$path" == dev/JOURNAL/T20260202-000002* ]]
}

@test "epic_resolve: a genuinely unresolvable id returns status 'unknown' and exit 0" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-999999"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "unknown" ]
}

@test "epic_resolve: never calls gh pr list under any outcome (that's epic_pr_state's job, called separately by render)" {
  bash -c "source '$SCRIPT'; epic_resolve T20260101-999999" > /dev/null
  ! grep -q '^pr ' "$EPIC_FAKE_GH_CALLLOG"
}

@test "epic_resolve hub path: picks the hub-scoped account even though \$PWD's origin resolves elsewhere" {
  # $PWD (LOCAL_REPO) origin is local-org/local-repo, which "other-user" can
  # see — but ROADMAP_TARGET_REPO is hub-org/hub-repo, which only
  # "hub-user" can see. If the account-scoping fix ever regressed to
  # deriving the slug from $PWD, this would 401/return empty instead.
  run bash -c "source '$SCRIPT'; epic_resolve T20260202-000001"
  [ "$status" -eq 0 ]
  [[ "$output" == Open* ]]
  grep -q "repo view hub-org/hub-repo" "$EPIC_FAKE_GH_CALLLOG"
}

@test "epic_resolve: local staleness epoch comes from git log, not wall-clock time" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000001"
  _split_resolve "$output"
  expected="$(git -C "$LOCAL_REPO" log -1 --format=%ct -- dev/TODO/T20260101-000001-open.md)"
  [ "$epoch" = "$expected" ]
}

@test "epic_resolve: hub staleness epoch comes from the commits API, not the contents API" {
  export EPIC_FAKE_GH_COMMIT_DATE_dev_TODO_T20260202_000001_hub_todo_md="2020-01-01T00:00:00Z"
  run bash -c "source '$SCRIPT'; epic_resolve T20260202-000001"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  expected="$(date -u -d 2020-01-01T00:00:00Z +%s)"
  [ "$epoch" = "$expected" ]
}

# ============================================================================
# bucket + rank
# ============================================================================

@test "_epic_status_bucket: all 7 lifecycle statuses map to distinct buckets" {
  run env bash -c "source '$SCRIPT'
    for s in Open Design Coding Review 'Blocked by T20260101-000099' Parked Done; do
      _epic_status_bucket \"\$s\"; echo
    done"
  [ "$status" -eq 0 ]
  expected=$'Open\nDesign\nCoding\nReview\nBlocked\nParked\nDone'
  [ "$output" = "$expected" ]
}

@test "_epic_status_bucket: empty or garbage status maps to unknown, never silently into Open" {
  run bash -c "source '$SCRIPT'; _epic_status_bucket ''; echo; _epic_status_bucket 'Garbage'"
  [ "$status" -eq 0 ]
  [ "$output" = $'unknown\nunknown' ]
}

# ============================================================================
# epic_render — text
# ============================================================================

@test "epic_render text: full 7-way bucket line + unresolved line for E1" {
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == "### E1 — Ship the pgrx bump"* ]]
  [[ "$output" == *"8 tasks: 1 Done"*"1 Review"*"1 Coding"*"1 Design"*"2 Blocked/Parked"*"1 Open"* ]]
  [[ "$output" == *"⚠ T20260101-999999 unresolved"* ]]
}

@test "epic_render text: marks E2 stale (hub commit date is old)" {
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  e2_block="$(awk '/^### E2/{f=1} f{print} /^### E3/{exit}' <<<"$output")"
  [[ "$e2_block" == *"⚠ stale: no task under this epic changed in ≥7 days"* ]]
}

@test "epic_render text: does not mark E3 stale (local commit is recent)" {
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  e3_block="$(awk '/^### E3/{f=1} f{print}' <<<"$output")"
  [[ "$e3_block" != *"stale"* ]]
}

@test "epic_render text: prints Deadline with day count for E1/E3, omits it for E2" {
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deadline: 2026-12-31 ("*" days)"* ]]
  [[ "$output" == *"Deadline: 2026-10-01 ("*" days)"* ]]
  e2_block="$(awk '/^### E2/{f=1} f{print} /^### E3/{exit}' <<<"$output")"
  [[ "$e2_block" != *"Deadline:"* ]]
}

@test "epic_render text: ROADMAP_TARGET_REPO unset -> one-line note, exit 0" {
  run env -u ROADMAP_TARGET_REPO -u ENV_FILE bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == "Epics unavailable — ROADMAP_TARGET_REPO is not set."* ]]
}

@test "epic_render text: EPICS.md fetch failure -> one-line note, exit 0" {
  run env EPIC_FAKE_GH_EPICS_MISSING=1 bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == "Epics unavailable"* ]]
}

@test "epic_render text: zero epics -> one-line note, exit 0" {
  run env EPIC_FAKE_GH_HUB_DIR="$BATS_TEST_TMPDIR/empty-hub" bash -c "
    mkdir -p '$BATS_TEST_TMPDIR/empty-hub/dev'
    cp '$FIXTURES/EPICS-empty.md' '$BATS_TEST_TMPDIR/empty-hub/dev/EPICS.md'
    source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == "No epics defined"* ]]
}

# ============================================================================
# epic_render --slack
# ============================================================================

@test "epic_render --slack: one compact line per epic, in file order" {
  run bash -c "source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
  line1="$(printf '%s\n' "$output" | sed -n 1p)"
  line2="$(printf '%s\n' "$output" | sed -n 2p)"
  line3="$(printf '%s\n' "$output" | sed -n 3p)"
  [[ "$line1" == *"E1 — Ship the pgrx bump"* ]]
  [[ "$line1" == *"1D/1R/1C/1Dsg/2B·P/1O"* ]]
  [[ "$line2" == *"E2 — Cross-repo compliance audit"* ]]
  [[ "$line2" == *"⚠ stale"* ]]
  [[ "$line3" == *"E3 — Keep vendor egress under budget"* ]]
}

@test "epic_render --slack: ROADMAP_TARGET_REPO unset -> emits nothing, exit 0" {
  run env -u ROADMAP_TARGET_REPO -u ENV_FILE bash -c "source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "epic_render --slack: a title containing a printf-%b-special backslash sequence is not truncated" {
  run env EPIC_FAKE_GH_HUB_DIR="$BATS_TEST_TMPDIR/backslash-hub" bash -c "
    mkdir -p '$BATS_TEST_TMPDIR/backslash-hub/dev'
    cp '$FIXTURES/EPICS-backslash-title.md' '$BATS_TEST_TMPDIR/backslash-hub/dev/EPICS.md'
    source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Ship \cool feature'* ]]
  [[ "$output" == *"0D/0R/0C/0Dsg/0B·P/1O"* ]]
}

@test "epic_render --slack: zero epics -> emits nothing, exit 0" {
  run env EPIC_FAKE_GH_HUB_DIR="$BATS_TEST_TMPDIR/empty-hub2" bash -c "
    mkdir -p '$BATS_TEST_TMPDIR/empty-hub2/dev'
    cp '$FIXTURES/EPICS-empty.md' '$BATS_TEST_TMPDIR/empty-hub2/dev/EPICS.md'
    source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# epic_pr_state
# ============================================================================

@test "epic_pr_state: renders 'PR #N STATE' when the fake returns one, 'no PR' otherwise" {
  run env EPIC_FAKE_GH_PR_FOR_ID="T20260202-000001" EPIC_FAKE_GH_PR_LINE="PR #42 OPEN" \
    bash -c "source '$SCRIPT'; epic_pr_state T20260202-000001 hub-org/hub-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "PR #42 OPEN" ]

  run bash -c "source '$SCRIPT'; epic_pr_state T20260202-000001 hub-org/hub-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "no PR" ]
}

@test "epic_pr_state: a local-repo leading task uses the plain _gh/gh.sh path, not the hub token" {
  run env EPIC_FAKE_GH_PR_FOR_ID="T20260101-000001" EPIC_FAKE_GH_PR_LINE="PR #7 MERGED" \
    bash -c "source '$SCRIPT'; epic_pr_state T20260101-000001 local-org/local-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "PR #7 MERGED" ]
  grep -q "repo view local-org/local-repo" "$EPIC_FAKE_GH_CALLLOG"
}

# ============================================================================
# main dispatch + direct-execution guard
# ============================================================================

@test "main: fetch/resolve/render/render --slack dispatch correctly; unknown subcommand exits 2" {
  run bash "$SCRIPT" resolve T20260101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == Open* ]]

  run bash "$SCRIPT" render
  [ "$status" -eq 0 ]
  [[ "$output" == "### E1"* || "$output" == "Epics unavailable"* || "$output" == "No epics defined"* ]]

  run bash "$SCRIPT" render --slack
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "direct-execution guard: sourcing defines functions but calls none of them" {
  run bash -c "source '$SCRIPT'; type -t epic_render"
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
  # No stdout beyond the type check above means main() never ran on source.
  run bash -c "source '$SCRIPT' 2>&1 1>/dev/null; echo done"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}
