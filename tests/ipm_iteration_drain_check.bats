#!/usr/bin/env bats
#
# Unit tests for _ipm/ipm-iteration-drain-check.sh (T20260622-147834; moved
# here from build-pipeline-repo's scripts/audit/ and generalized by
# T20260719-111051).
#
# Strategy: the gate is a pure transformation over the GH Project board JSON —
# resolve the previous iteration by date window, then find non-Done items in it.
# We inject a fixtured board via IPM_DRAIN_BOARD_JSON and pin "today" with
# --today, so the production function runs exactly as in CI with no network, no
# `gh`, and no dependence on the wall clock (guidelines: dependency-inject I/O).
#
# All fixture boards below use "your-org/build-pipeline-repo" as the
# illustrative "home" repo string. Since --home-repo now defaults to the
# --repo-path clone's own git remote (no hardcoded default), every test that
# depends on that string being "home" passes --home-repo explicitly — relying
# on whatever repo bats happens to run inside would make the test non-hermetic.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_ROOT/_ipm/ipm-iteration-drain-check.sh"
HOME_REPO="your-org/build-pipeline-repo"

setup() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

# A 3-iteration board (start dates 06-08, 06-15, 06-22) where the 06-15
# iteration is clean — every item Done.
_board_clean() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":2,"title":"prev-done"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

# Same board but the 06-15 iteration carries a stranded non-Done item (#42).
_board_offender() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":2,"title":"prev-done"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":42,"title":"stranded-task"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

# Previous iteration (06-15) carries ONLY a cross-repo (hub-repo) non-Done
# item — not drainable from the build-pipeline clone (T20260628-592642).
_board_crossrepo() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Coding", "content": {"repository":"your-org/hub-repo","number":95,"title":"cross-repo-compliance"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

# Previous iteration (06-15) carries TWO same-repo offenders whose titles carry
# real task IDs (board titles are "T<id> — <H1>"), so the lint-frozen probe can
# key off IPM_DRAIN_FROZEN_IDS (T20260628-951477). #42 = T20260529-269038,
# #43 = T20260615-296902.
_board_two_taskid() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Open",   "content": {"repository":"your-org/build-pipeline-repo","number":42,"title":"T20260529-269038 — frozen offender"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Open",   "content": {"repository":"your-org/build-pipeline-repo","number":43,"title":"T20260615-296902 — clean offender"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

# Previous iteration (06-15): one same-repo task-id offender + one cross-repo offender.
_board_frozen_plus_cross() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Open",   "content": {"repository":"your-org/build-pipeline-repo","number":42,"title":"T20260529-269038 — frozen offender"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Open",   "content": {"repository":"your-org/hub-repo","number":95,"title":"cross-repo-compliance"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

# Previous iteration (06-15) carries BOTH a same-repo and a cross-repo non-Done item.
_board_mixed() {
  cat <<'JSON'
{ "items": [
  { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current-wip"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":42,"title":"home-stranded"} },
  { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Open",   "content": {"repository":"your-org/hub-repo","number":95,"title":"cross-stranded"} },
  { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
] }
JSON
}

@test "clean previous iteration -> exit 0" {
  export IPM_DRAIN_BOARD_JSON="$(_board_clean)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-15"* ]]
}

@test "non-Done item in previous iteration -> exit 1 and lists the offender" {
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"42"* ]]
  [[ "$output" == *"stranded-task"* ]]
}

@test "previous = second-latest distinct startDate <= today (date window, not a counter)" {
  # today 2026-06-23 -> current=06-22, previous=06-15. The older 06-08 items
  # must NOT be treated as offenders.
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2026-06-15"* ]]
  [[ "$output" != *"old-done"* ]]
}

@test "--prev-start override targets a specific iteration" {
  # Force previous=06-08; all its items are Done -> exit 0 even though 06-15 is dirty.
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --prev-start 2026-06-08 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-08"* ]]
}

@test "future iterations are excluded by the today window" {
  # today 2026-06-16 -> distinct starts <= today = [06-08, 06-15];
  # current=06-15, previous=06-08 (all Done) -> exit 0. The 06-15 offender is
  # now the *current* iteration, not the previous one.
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --today 2026-06-16 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-08"* ]]
}

@test "single iteration <= today -> no previous, nothing to drain (exit 0)" {
  export IPM_DRAIN_BOARD_JSON="$(_board_clean)"
  run ipm-iteration-drain-check --today 2026-06-08 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no previous iteration"* ]]
}

@test "Parked item on the previous iteration is terminal (not an offender)" {
  export IPM_DRAIN_BOARD_JSON='{ "items": [
    { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current"} },
    { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Parked", "content": {"repository":"your-org/build-pipeline-repo","number":7,"title":"set-aside"} },
    { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
  ] }'
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"set-aside"* ]]
}

@test "--terminal override can make Parked an offender (strict mode)" {
  export IPM_DRAIN_BOARD_JSON='{ "items": [
    { "iteration": {"startDate":"2026-06-22","title":"Cur"},  "status":"Coding", "content": {"repository":"your-org/build-pipeline-repo","number":1,"title":"current"} },
    { "iteration": {"startDate":"2026-06-15","title":"Prev"}, "status":"Parked", "content": {"repository":"your-org/build-pipeline-repo","number":7,"title":"set-aside"} },
    { "iteration": {"startDate":"2026-06-08","title":"Old"},  "status":"Done",   "content": {"repository":"your-org/build-pipeline-repo","number":3,"title":"old-done"} }
  ] }'
  run ipm-iteration-drain-check --today 2026-06-23 --terminal "Done" --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"set-aside"* ]]
}

@test "cross-repo-only offender in previous iteration -> exit 0 + non-blocking warning (T592642)" {
  # The IPM clone cannot drain a hub-repo task file, so a cross-repo offender
  # must NOT deadlock the gate — it is surfaced as a warning, exit stays 0.
  export IPM_DRAIN_BOARD_JSON="$(_board_crossrepo)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hub-repo"* ]]
  [[ "$output" == *"95"* ]]
  [[ "$output" == *"WARNING"* || "$output" == *"⚠"* ]]
  [[ "$output" != *"❌"* ]]   # not a hard-fail block
}

@test "mixed same-repo + cross-repo offenders -> exit 1 (same-repo blocks); cross-repo still warned (T592642)" {
  export IPM_DRAIN_BOARD_JSON="$(_board_mixed)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"home-stranded"* ]]    # blocking same-repo offender listed
  [[ "$output" == *"cross-stranded"* ]]   # cross-repo offender warned, not dropped
}

@test "--home-repo override makes the cross-repo offender block (exit 1) (T592642)" {
  # Same board as the cross-repo-only case, but treat hub-repo as home:
  # the previously-warned item now blocks. Proves the partition is flag-driven.
  export IPM_DRAIN_BOARD_JSON="$(_board_crossrepo)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo your-org/hub-repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"95"* ]]
  [[ "$output" == *"❌"* ]]
}

# --- Lint-frozen same-repo offenders (T20260628-951477) ---------------------
# IPM_DRAIN_FROZEN_IDS short-circuits the real lint so these stay hermetic.

@test "all same-repo offenders lint-frozen -> exit 0 + non-blocking warning, no block" {
  export IPM_DRAIN_BOARD_JSON="$(_board_two_taskid)"
  export IPM_DRAIN_FROZEN_IDS="T20260529-269038 T20260615-296902"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT-FROZEN"* ]]
  [[ "$output" == *"T20260529-269038"* ]]
  [[ "$output" == *"T20260615-296902"* ]]
  [[ "$output" == *"T20260626-353630"* ]]   # cites the root-cause schema fork
  [[ "$output" != *"❌"* ]]                  # no hard-fail block
}

@test "clean same-repo offender still blocks (exit 1) even when another is frozen" {
  export IPM_DRAIN_BOARD_JSON="$(_board_two_taskid)"
  export IPM_DRAIN_FROZEN_IDS="T20260529-269038"   # #42 frozen, #43 clean
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"❌"* ]]
  [[ "$output" == *"T20260615-296902"* ]]   # the clean offender blocks
  [[ "$output" == *"LINT-FROZEN"* ]]        # the frozen one is still warned
  [[ "$output" == *"T20260529-269038"* ]]   # ...and listed, not dropped
}

@test "no same-repo offender frozen -> all block (exit 1)" {
  export IPM_DRAIN_BOARD_JSON="$(_board_two_taskid)"
  export IPM_DRAIN_FROZEN_IDS="T99999999-999999"   # matches neither
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"❌"* ]]
  [[ "$output" == *"T20260529-269038"* ]]
  [[ "$output" == *"T20260615-296902"* ]]
  [[ "$output" != *"LINT-FROZEN"* ]]        # nothing frozen -> no frozen warning
}

@test "frozen same-repo + cross-repo offender -> exit 0, both warned non-blocking" {
  export IPM_DRAIN_BOARD_JSON="$(_board_frozen_plus_cross)"
  export IPM_DRAIN_FROZEN_IDS="T20260529-269038"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT-FROZEN"* ]]
  [[ "$output" == *"T20260529-269038"* ]]   # frozen same-repo warned
  [[ "$output" == *"hub-repo"* ]]        # cross-repo warned
  [[ "$output" == *"95"* ]]
  [[ "$output" != *"❌"* ]]
}

@test "fail-safe: same-repo offender with no task-id in title -> blocking" {
  # No IPM_DRAIN_FROZEN_IDS and a title carrying no T-id => cannot probe =>
  # treated as clean/BLOCKING (gate keeps its teeth; no silent exemption).
  unset IPM_DRAIN_FROZEN_IDS
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --today 2026-06-23 --home-repo "$HOME_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stranded-task"* ]]
  [[ "$output" == *"❌"* ]]
}

@test "unknown argument -> exit 2 with usage" {
  run ipm-iteration-drain-check --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* || "$output" == *"unknown arg"* ]]
}

@test "sourceable without side effects" {
  run source "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- --home-repo/--owner auto-detect from git remote (T20260719-111051) ----
# Replaces the old hardcoded default (your-org/build-pipeline-repo)
# with detection from --repo-path's `origin` remote — same idiom as
# _taskid/url.sh's taskid-repo-slug.

@test "_ipm_drain_repo_slug resolves owner/repo from an ssh-form git remote" {
  local d="$BATS_TEST_TMPDIR/fixture-ssh"
  mkdir -p "$d" && git -C "$d" init -q
  git -C "$d" remote add origin git@github.com:your-org/example-repo.git
  run _ipm_drain_repo_slug "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "your-org/example-repo" ]
}

@test "_ipm_drain_repo_slug resolves owner/repo from an https-form git remote" {
  local d="$BATS_TEST_TMPDIR/fixture-https"
  mkdir -p "$d" && git -C "$d" init -q
  git -C "$d" remote add origin https://github.com/your-org/example-repo.git
  run _ipm_drain_repo_slug "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "your-org/example-repo" ]
}

@test "_ipm_drain_repo_slug fails when the path has no origin remote" {
  local d="$BATS_TEST_TMPDIR/no-remote"
  mkdir -p "$d" && git -C "$d" init -q
  run _ipm_drain_repo_slug "$d"
  [ "$status" -ne 0 ]
}

@test "--home-repo auto-detected from --repo-path's git remote when not given explicitly" {
  local d="$BATS_TEST_TMPDIR/auto-detect-repo"
  mkdir -p "$d" && git -C "$d" init -q
  git -C "$d" remote add origin "git@github.com:${HOME_REPO}.git"
  export IPM_DRAIN_BOARD_JSON="$(_board_offender)"
  run ipm-iteration-drain-check --today 2026-06-23 --repo-path "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stranded-task"* ]]
  [[ "$output" == *"❌"* ]]
}

@test "no --home-repo and --repo-path has no git remote -> exit 2 with actionable error" {
  local d="$BATS_TEST_TMPDIR/no-remote-gate"
  mkdir -p "$d" && git -C "$d" init -q
  export IPM_DRAIN_BOARD_JSON="$(_board_clean)"
  run ipm-iteration-drain-check --today 2026-06-23 --repo-path "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--home-repo"* ]]
}
