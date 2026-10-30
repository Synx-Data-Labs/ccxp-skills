#!/usr/bin/env bats
# retro/scripts/window.sh (review window) and retro/scripts/metrics.sh (the
# weekly numbers). Offline: a temp fixture repo, the shared fake gh, fake task
# ids (T20000101-...), a pinned clock. Nothing is posted; the scripts only read.

load test_helper

WINDOW="$REPO_ROOT/retro/scripts/window.sh"
METRICS="$REPO_ROOT/retro/scripts/metrics.sh"

setup() {
  R="$(make_fixture_repo "$BATS_TEST_TMPDIR/repo")"
  FX="$BATS_TEST_TMPDIR/ghfx"; mkdir -p "$FX"
  fake_gh "$FX"
  export METRICS_GH=gh
  export TMPDIR="$BATS_TEST_TMPDIR"
  export THREADS_FILE="$R/.claude/state/drive-threads.json"
  # Friday 2026-10-30; its Monday is 2026-10-26
  export TODAY=2026-10-30 NOW=2026-10-30T12:00:00Z TZ=UTC
}

val() { printf '%s\n' "$output" | sed -n "s/^$1=//p"; }

# ---- window.sh ------------------------------------------------------------

@test "window: defaults to one week, KEY=value lines" {
  run bash "$WINDOW" --repo-root "$R"
  [ "$status" -eq 0 ]
  [ "$(val WEEKS)" = 1 ]
  [ "$(val START)" = 2026-10-23 ]
  [ "$(val END)" = 2026-10-30 ]
  [ "$(val SINCE_ISO)" = 2026-10-23T12:00:00Z ]
  [ "$(val THIS_MONDAY)" = 2026-10-26 ]
  [ -z "$(val IPM_FILE)" ]
  [ -z "$(val PRIOR_RETRO)" ]
}

@test "window: N weeks goes back N*7 days" {
  run bash "$WINDOW" 2 --repo-root "$R"
  [ "$status" -eq 0 ]
  [ "$(val START)" = 2026-10-16 ]
  [ "$(val SINCE_ISO)" = 2026-10-16T12:00:00Z ]
}

@test "window: crossing a month and a leap day is calendar-correct" {
  TODAY=2028-03-02 NOW=2028-03-02T00:00:00Z run bash "$WINDOW" 1 --repo-root "$R"
  [ "$(val START)" = 2028-02-24 ]
  TODAY=2028-03-01 NOW=2028-03-01T00:00:00Z run bash "$WINDOW" 1 --repo-root "$R"
  [ "$(val START)" = 2028-02-23 ]
}

@test "window: THIS_MONDAY is the previous Monday from Tue..Sun, itself on Monday" {
  for pair in "2026-10-26 2026-10-26" "2026-10-27 2026-10-26" "2026-11-01 2026-10-26" "2026-11-02 2026-11-02"; do
    set -- $pair
    TODAY="$1" run bash "$WINDOW" --repo-root "$R"
    [ "$(val THIS_MONDAY)" = "$2" ]
  done
}

@test "window: IPM_FILE set only when this Monday's ipm-weekly exists" {
  touch "$R/dev/JOURNAL/2026-10-19-ipm-weekly.md"
  run bash "$WINDOW" --repo-root "$R"
  [ -z "$(val IPM_FILE)" ]
  touch "$R/dev/JOURNAL/2026-10-26-ipm-weekly.md"
  run bash "$WINDOW" --repo-root "$R"
  [ "$(val IPM_FILE)" = dev/JOURNAL/2026-10-26-ipm-weekly.md ]
}

@test "window: PRIOR_RETRO is the newest retro dated before END" {
  touch "$R/dev/JOURNAL/2026-10-09-retro-weekly.md" "$R/dev/JOURNAL/2026-10-16-retro-weekly.md" \
        "$R/dev/JOURNAL/2026-10-30-retro-weekly.md" "$R/dev/JOURNAL/2026-10-31-retro-weekly.md" \
        "$R/dev/JOURNAL/2026-10-29-note.md"
  run bash "$WINDOW" --repo-root "$R"
  [ "$(val PRIOR_RETRO)" = dev/JOURNAL/2026-10-16-retro-weekly.md ]
}

@test "window: bad weeks / unknown flag / bad date exit 2, missing dir exit 3" {
  for bad in 0 53 abc -1 1.5; do
    run bash "$WINDOW" "$bad" --repo-root "$R"
    [ "$status" -eq 2 ]
  done
  run bash "$WINDOW" --bogus; [ "$status" -eq 2 ]
  TODAY=2026-02-31 run bash "$WINDOW" --repo-root "$R"; [ "$status" -eq 2 ]
  run bash "$WINDOW" --repo-root "$BATS_TEST_TMPDIR/nope"; [ "$status" -eq 3 ]
}

@test "window/metrics scripts use no GNU-only date -d or grep -P" {
  run grep -nE 'date[^|;]* -d |grep[^|;]* -[a-zA-Z]*P' \
    "$REPO_ROOT/retro/scripts/window.sh" "$REPO_ROOT/retro/scripts/metrics.sh"
  [ "$status" -eq 1 ]
}

# ---- metrics.sh -----------------------------------------------------------

seed() {
  cat > "$FX/pr_list_state_merged.json" <<'J'
[{"number":1,"title":"a","createdAt":"2026-10-27T00:00:00Z","mergedAt":"2026-10-27T12:00:00Z","additions":10,"deletions":2},
 {"number":2,"title":"b","createdAt":"2026-10-28T00:00:00Z","mergedAt":"2026-10-29T00:00:00Z","additions":5,"deletions":1},
 {"number":3,"title":"before window","createdAt":"2026-10-20T00:00:00Z","mergedAt":"2026-10-23T05:00:00Z","additions":99,"deletions":99}]
J
  cat > "$FX/pr_list_state_open.json" <<'J'
[{"number":7,"title":"old","createdAt":"2026-10-20T00:00:00Z"},
 {"number":8,"title":"fresh","createdAt":"2026-10-29T00:00:00Z"}]
J
  cat > "$FX/run_list.json" <<'J'
[{"conclusion":"success","name":"CI","createdAt":"2026-10-29T00:00:00Z"},
 {"conclusion":"success","name":"CI","createdAt":"2026-10-28T00:00:00Z"},
 {"conclusion":"failure","name":"Release","createdAt":"2026-10-27T00:00:00Z"},
 {"conclusion":"failure","name":"Release","createdAt":"2026-10-26T00:00:00Z"},
 {"conclusion":"failure","name":"Nightly","createdAt":"2026-10-25T00:00:00Z"},
 {"conclusion":"failure","name":"Lint","createdAt":"2026-10-24T00:00:00Z"},
 {"conclusion":"","name":"CI","createdAt":"2026-10-30T00:00:00Z"}]
J
  : > "$R/dev/JOURNAL/2026-10-24-T20000101-000001-in-window.md"
  : > "$R/dev/JOURNAL/2026-10-30-T20000101-000002-today.md"
  : > "$R/dev/JOURNAL/2026-10-22-T20000101-000003-too-old.md"
  : > "$R/dev/JOURNAL/2026-10-27-ipm-weekly.md"
  : > "$R/dev/TODO/T20000101-000010-open.md"
  : > "$R/dev/TODO/T20000101-000011-open.md"
  mkdir -p "$R/dev/PARKING"; : > "$R/dev/PARKING/T20000101-000012-parked.md"
  mkdir -p "$R/.claude/state"
  cat > "$THREADS_FILE" <<'J'
{"T20000101-000001":{"type":"design","summary":"s","sent_at":"2026-10-25T00:00:00Z","resolved":true},
 "T20000101-000002":{"type":"design","summary":"s","sent_at":"2026-10-26T00:00:00Z","resolved":false},
 "T20000101-000003":{"type":"design","summary":"s","sent_at":"2026-10-01T00:00:00Z","resolved":true}}
J
}

@test "metrics: computes every number on fixture data" {
  seed
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .tasks_completed == 2 and .backlog == {todo: 2, parking: 1}
    and .prs.merged == 2 and .prs.open == 2 and .prs.stale_open == 1
    and .prs.avg_cycle_hours == 18 and .prs.additions == 15 and .prs.deletions == 3
    and .ci.total == 6 and .ci.green == 2 and .ci.failed == 4
    and .ci.pass_rate_pct == 33.3 and .ci.truncated == false
    and .ci.top_failing == [{name:"Release",failures:2},{name:"Lint",failures:1},{name:"Nightly",failures:1}]
    and .escalations == {sent: 2, resolved: 1}
    and .since == "2026-10-23T12:00:00Z"'
}

@test "metrics: window and repo flags drive the exact gh calls (read-only)" {
  seed
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 0 ]
  assert_calls "$FAKE_GH_LOG" '^pr list --state merged --search merged:>=2026-10-23 .*--limit 500'
  assert_calls "$FAKE_GH_LOG" '^run list --created >=2026-10-23T12:00:00Z --limit 1000 '
  refute_calls "$FAKE_GH_LOG" '^(pr (comment|merge|create|review|close)|api|issue)'
}

@test "metrics: a run list that hits the cap is reported truncated" {
  seed
  jq -n '[range(0;1000) | {conclusion:"success",name:"CI",createdAt:"2026-10-29T00:00:00Z"}]' > "$FX/run_list.json"
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ci.truncated == true and .ci.total == 1000 and .ci.pass_rate_pct == 100'
}

@test "metrics: METRICS_RUN_LIMIT is the cap used" {
  seed
  METRICS_RUN_LIMIT=7 run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ci.truncated == true and .ci.run_limit == 7'
  assert_calls "$FAKE_GH_LOG" '--limit 7 '
}

@test "metrics: an empty window gives nulls, not divide-by-zero" {
  echo '[]' > "$FX/pr_list_state_merged.json"; echo '[]' > "$FX/pr_list_state_open.json"; echo '[]' > "$FX/run_list.json"
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.prs.avg_cycle_hours == null and .ci.pass_rate_pct == null
    and .ci.oldest_created == null and .ci.top_failing == [] and .escalations.sent == 0
    and .tasks_completed == 0 and .ci.truncated == false'
}

@test "metrics: any gh failure fails closed (exit 3, no JSON)" {
  seed
  for pat in 'pr list --state merged' 'pr list --state open' '^run list'; do
    FAKE_GH_FAIL="$pat" run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
    [ "$status" -eq 3 ]
    [[ "$output" != *'{'* ]]
  done
}

@test "metrics: unmapped gh output / non-JSON fails closed" {
  seed
  echo 'not json' > "$FX/run_list.json"
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 3 ]
}

@test "metrics: malformed drive-threads file exits 4 and is left untouched" {
  seed
  echo '[1,2' > "$THREADS_FILE"
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"
  [ "$status" -eq 4 ]
  [ "$(cat "$THREADS_FILE")" = '[1,2' ]
}

@test "metrics: usage errors exit 2" {
  run bash "$METRICS" --repo-root "$R"; [ "$status" -eq 2 ]
  run bash "$METRICS" --since yesterday --repo-root "$R"; [ "$status" -eq 2 ]
  run bash "$METRICS" --since 2026-10-23T12:00:00Z --bogus; [ "$status" -eq 2 ]
  METRICS_RUN_LIMIT=0 run bash "$METRICS" --since 2026-10-23T12:00:00Z --repo-root "$R"; [ "$status" -eq 2 ]
}

@test "metrics: window.sh SINCE_ISO feeds metrics.sh end to end" {
  seed
  since="$(bash "$WINDOW" --repo-root "$R" | sed -n 's/^SINCE_ISO=//p')"
  run bash "$METRICS" --since "$since" --repo-root "$R"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.since == "2026-10-23T12:00:00Z"'
}
