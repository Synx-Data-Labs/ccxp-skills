#!/usr/bin/env bats
# Tests for ccxp/scripts/epic-status.sh — the deterministic epic rollup for
# the ccxp daily standup (T20260911-347027). Made local-only by
# T20261005-639913 (dropped the global ROADMAP_TARGET_REPO hub config — every
# repo now owns its own dev/EPICS.md).
#
# I/O is hermetic throughout:
#   - a throwaway git repo under $BATS_TEST_TMPDIR stands in for the repo
#     dev/TODO|PARKING|JOURNAL|EPICS.md resolve against;
#   - a fake `gh` (tests/fixtures/epics/fake-gh.sh) serves the one remaining
#     external call this script makes: `gh pr list --search` for the
#     "Leading" task's PR state, plus the account-pick plumbing `_gh/gh.sh`
#     always runs first;
#   - $TMPDIR is pointed at $BATS_TEST_TMPDIR so _gh/gh.sh's account-pick
#     cache (normally a real /tmp file, shared across processes) can't leak
#     between tests.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/ccxp/scripts/epic-status.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/epics"

  unset EPIC_FAKE_GH_PR_FOR_ID

  export TMPDIR="$BATS_TEST_TMPDIR"

  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$FIXTURES/fake-gh.sh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  export PATH="$FAKEBIN:$PATH"
  export EPIC_FAKE_GH_CALLLOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : > "$EPIC_FAKE_GH_CALLLOG"

  LOCAL_REPO="$BATS_TEST_TMPDIR/local-repo"
  mkdir -p "$LOCAL_REPO/dev/TODO" "$LOCAL_REPO/dev/PARKING" "$LOCAL_REPO/dev/JOURNAL"
  (
    cd "$LOCAL_REPO"
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git remote add origin git@github.com:local-org/local-repo.git
    cp "$FIXTURES/task-open.md"         dev/TODO/T20260101-000001-open.md
    cp "$FIXTURES/task-design.md"       dev/TODO/T20260101-000002-design.md
    cp "$FIXTURES/task-in-progress.md"  dev/TODO/T20260101-000003-in-progress.md
    cp "$FIXTURES/task-review.md"       dev/TODO/T20260101-000004-review.md
    cp "$FIXTURES/task-done.md"         dev/JOURNAL/T20260101-000005-done.md
    cp "$FIXTURES/task-blocked.md"      dev/TODO/T20260101-000006-blocked.md
    cp "$FIXTURES/task-parked.md"       dev/PARKING/T20260101-000007-parked.md
    cp "$FIXTURES/EPICS.md"             dev/EPICS.md
    git add dev
    git commit -q -m "fixture tasks"

    # E2's task, committed with a deliberately old date so epic_render's
    # staleness check (>=7 days since any task under the epic last changed)
    # fires independent of wall-clock "now" at test time.
    cp "$FIXTURES/task-stale.md" dev/TODO/T20260202-000001-stale.md
    git add dev/TODO/T20260202-000001-stale.md
    GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
      git commit -q -m "stale fixture task"
  )

  # --- gh setup: one account, with write access to the local repo's slug
  #     (the only slug epic_pr_state's PR lookup ever touches now).
  export EPIC_FAKE_GH_ACCOUNTS="local-user"
  export EPIC_FAKE_GH_ACCESS="local-user-token local-org/local-repo"

  cd "$LOCAL_REPO"
  SKILLS_ROOT="$REPO_ROOT"
  export SKILLS_ROOT
}

_split_resolve() {
  # $1 = one epic_resolve TSV line -> sets st/claimed/repo/path/epoch.
  # NOT `IFS=$'\t' read -r ... <<<"$1"`: tab is "IFS whitespace" to bash's
  # `read` regardless of what IFS is set to, so an empty column (claimed_by
  # routinely is) collapses two adjacent tabs into one delimiter and shifts
  # every field after it — verified: `printf 'x\t\ty' | IFS=$'\t' read -r a
  # b c` gives b="y" c="", not b="" c="y". awk's -F'\t' has no such
  # collapsing (same fix applied in epic-status.sh's own epic_render).
  local f
  mapfile -t f < <(awk -F'\t' '{for (i=1;i<=5;i++) print $i}' <<<"$1")
  st="${f[0]}"; claimed="${f[1]}"; repo="${f[2]}"; path="${f[3]}"; epoch="${f[4]}"
}

# ============================================================================
# epic_fetch
# ============================================================================

@test "epic_fetch: returns 1 and prints nothing when dev/EPICS.md does not exist" {
  rm dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "epic_fetch: prints the local dev/EPICS.md path when it exists" {
  run bash -c "source '$SCRIPT'; epic_fetch"
  [ "$status" -eq 0 ]
  [ "$output" = "dev/EPICS.md" ]
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
# epic_resolve
# ============================================================================

@test "epic_resolve: resolves status + claimed_by + a numeric epoch from dev/TODO" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000001"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Open" ]
  [ "$repo" = "local-org/local-repo" ]
  [[ "$epoch" =~ ^[0-9]+$ ]]
}

@test "epic_resolve: resolves status from dev/PARKING" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000007"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Parked" ]
}

@test "epic_resolve: resolves status from dev/JOURNAL (Done)" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000005"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "Done" ]
}

@test "epic_resolve: a genuinely unresolvable id returns status 'unknown' and exit 0" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-999999"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "unknown" ]
}

@test "epic_resolve: a malformed id (no T-id shape) returns 'unknown' without touching taskid-path" {
  run bash -c "source '$SCRIPT'; epic_resolve not-a-task-id"
  [ "$status" -eq 0 ]
  _split_resolve "$output"
  [ "$st" = "unknown" ]
}

@test "epic_resolve: never calls gh pr list under any outcome (that's epic_pr_state's job, called separately by render)" {
  bash -c "source '$SCRIPT'; epic_resolve T20260101-999999" > /dev/null
  ! grep -q '^pr ' "$EPIC_FAKE_GH_CALLLOG"
}

@test "epic_resolve: staleness epoch comes from git log, not wall-clock time" {
  run bash -c "source '$SCRIPT'; epic_resolve T20260101-000001"
  _split_resolve "$output"
  expected="$(git -C "$LOCAL_REPO" log -1 --format=%ct -- dev/TODO/T20260101-000001-open.md)"
  [ "$epoch" = "$expected" ]
}

# ============================================================================
# bucket + rank
# ============================================================================

@test "_epic_status_bucket: all 7 lifecycle statuses map to distinct buckets" {
  run env bash -c "source '$SCRIPT'
    for s in Open Design 'In Progress' Review 'Blocked by T20260101-000099' Parked Done; do
      _epic_status_bucket \"\$s\"; echo
    done"
  [ "$status" -eq 0 ]
  expected=$'Open\nDesign\nIn Progress\nReview\nBlocked\nParked\nDone'
  [ "$output" = "$expected" ]
}

@test "_epic_status_bucket + _epic_status_rank: \"In Progress\" buckets and ranks correctly" {
  run bash -c "source '$SCRIPT'; _epic_status_bucket 'In Progress'; _epic_status_rank 'In Progress'"
  [ "$status" -eq 0 ]
  [ "$output" = $'In Progress4' ]
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
  [[ "$output" == *"8 tasks: 1 Done"*"1 Review"*"1 In Progress"*"1 Design"*"2 Blocked/Parked"*"1 Open"* ]]
  [[ "$output" == *"⚠ T20260101-999999 unresolved"* ]]
}

@test "epic_render text: marks E2 stale (its one task's last commit is far in the past)" {
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  e2_block="$(awk '/^### E2/{f=1} f{print} /^### E3/{exit}' <<<"$output")"
  [[ "$e2_block" == *"⚠ stale: no task under this epic changed in ≥7 days"* ]]
}

@test "epic_render text: does not mark E3 stale (its task's commit is recent)" {
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

@test "epic_render text: dev/EPICS.md missing -> one-line note, exit 0" {
  rm dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_render"
  [ "$status" -eq 0 ]
  [[ "$output" == "Epics unavailable — dev/EPICS.md not found or unreadable."* ]]
}

@test "epic_render text: zero epics -> one-line note, exit 0" {
  cp "$FIXTURES/EPICS-empty.md" dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_render"
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
  [[ "$line1" == *"1D/1R/1I/1Dsg/2B·P/1O"* ]]
  [[ "$line2" == *"E2 — Cross-repo compliance audit"* ]]
  [[ "$line2" == *"⚠ stale"* ]]
  [[ "$line3" == *"E3 — Keep vendor egress under budget"* ]]
}

@test "epic_render --slack: dev/EPICS.md missing -> emits nothing, exit 0" {
  rm dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "epic_render --slack: a title containing a printf-%b-special backslash sequence is not truncated" {
  cp "$FIXTURES/EPICS-backslash-title.md" dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Ship \cool feature'* ]]
  [[ "$output" == *"0D/0R/0I/0Dsg/0B·P/1O"* ]]
}

@test "epic_render --slack: zero epics -> emits nothing, exit 0" {
  cp "$FIXTURES/EPICS-empty.md" dev/EPICS.md
  run bash -c "source '$SCRIPT'; epic_render --slack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# epic_pr_state
# ============================================================================

@test "epic_pr_state: renders 'PR #N STATE' when the fake returns one, 'no PR' otherwise" {
  run env EPIC_FAKE_GH_PR_FOR_ID="T20260101-000001" EPIC_FAKE_GH_PR_LINE="PR #7 MERGED" \
    bash -c "source '$SCRIPT'; epic_pr_state T20260101-000001 local-org/local-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "PR #7 MERGED" ]
  # _gh_account_tier() (T20260911-140914) probes via `gh api repos/<slug>
  # --jq .permissions.push`.
  grep -q "api repos/local-org/local-repo" "$EPIC_FAKE_GH_CALLLOG"

  run bash -c "source '$SCRIPT'; epic_pr_state T20260101-000001 local-org/local-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "no PR" ]
}

@test "epic_pr_state: empty id -> 'no PR' without calling gh at all" {
  run bash -c "source '$SCRIPT'; epic_pr_state '' local-org/local-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "no PR" ]
  [ ! -s "$EPIC_FAKE_GH_CALLLOG" ]
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

@test "no functional ROADMAP_TARGET_REPO / hub-contents-API dependency remains (comments aside)" {
  # Strip comment-only lines first (the header deliberately explains, in
  # prose, what was removed and why) — this checks there's no live
  # reference left, not that the words never appear anywhere.
  code_only="$(grep -vE '^\s*#' "$SCRIPT")"
  ! grep -qi "ROADMAP_TARGET_REPO\|contents/dev\|_gh_pick_account\|_epic_gh_token\|_epic_hub_lookup" <<<"$code_only"
}
