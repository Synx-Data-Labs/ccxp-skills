#!/usr/bin/env bats
# ccxp/scripts/standup-data.sh (fact collection) and
# ccxp/scripts/render-standup.sh (deterministic text). Offline: a fixture git
# repo under $BATS_TEST_TMPDIR, the shared fake gh, fake task ids. Nothing is
# posted; the scripts have no send path.

load test_helper

DATA="$REPO_ROOT/ccxp/scripts/standup-data.sh"
RENDER="$REPO_ROOT/ccxp/scripts/render-standup.sh"

setup() {
  R="$(make_fixture_repo "$BATS_TEST_TMPDIR/repo")"
  FX="$BATS_TEST_TMPDIR/ghfx"; mkdir -p "$FX"
  fake_gh "$FX"
  export STANDUP_GH=gh
  export TMPDIR="$BATS_TEST_TMPDIR"
  export THREADS_FILE="$R/.claude/state/drive-threads.json"
  export NOW=2026-10-30T12:00:00Z TZ=UTC
  # fake PR -> task id mapping: PR 11 -> T20000101-000011, others none
  cat > "$BATS_TEST_TMPDIR/prid.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = 11 ] && echo T20000101-000011
exit 0
SH
  export STANDUP_PR_TASK_ID="bash $BATS_TEST_TMPDIR/prid.sh"
}

# commit <iso-date> <subject>
commit_at() {
  ( cd "$R" && echo "$2" >> f.txt && git add -A &&
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q -m "$2" )
}

seed_gh() {
  cat > "$FX/pr_list_state_merged.json" <<'J'
[{"number":21,"title":"second merged","mergedAt":"2026-10-29T15:00:00Z"},
 {"number":20,"title":"first merged","mergedAt":"2026-10-29T09:00:00Z"}]
J
  cat > "$FX/pr_list_state_open.json" <<'J'
[
 {"number":10,"title":"quiet","body":"- [x] done\n- [ ] tests","mergeable":"MERGEABLE","updatedAt":"2026-10-29T01:00:00Z"},
 {"number":11,"title":"needs a call","body":"## Pre-merge\n- [ ] Maintainer release-strategy call\n","mergeable":"MERGEABLE","updatedAt":"2026-10-28T01:00:00Z"},
 {"number":12,"title":"conflicted","body":"","mergeable":"CONFLICTING","updatedAt":"2026-10-27T01:00:00Z"},
 {"number":13,"title":"checked decision","body":"- [x] maintainer approve\n","mergeable":"MERGEABLE","updatedAt":"2026-10-27T01:00:00Z"}
]
J
  cat > "$FX/run_list_branch_main.json" <<'J'
[{"databaseId":901,"name":"Nightly A","conclusion":"success","createdAt":"2026-10-30T03:00:00Z"},
 {"databaseId":902,"name":"Nightly B","conclusion":"failure","createdAt":"2026-10-30T03:05:00Z"},
 {"databaseId":903,"name":"Nightly C","conclusion":"cancelled","createdAt":"2026-10-30T03:10:00Z"}]
J
}

data() { run bash "$DATA" --dir "$R" "$@"; }

@test "standup-data: collects every section from a fixture repo" {
  seed_gh
  # chronological order: git stops walking at the first commit older than --since
  commit_at "2026-10-28T10:00:00Z" "older work"
  commit_at "2026-10-29T10:00:00Z" "yesterday work"
  commit_at "2026-10-30T10:00:00Z" "today work"
  mkdir -p "$R/dev/JOURNAL" "$R/.claude/state"
  : > "$R/dev/JOURNAL/2026-10-29-T20000101-000011-thing.md"
  : > "$R/dev/JOURNAL/2026-10-27-daily-summary.md"
  : > "$R/dev/JOURNAL/2026-10-29-daily-summary.md"
  : > "$R/dev/JOURNAL/2026-11-05-daily-summary.md"
  cat > "$THREADS_FILE" <<'J'
{"T20000101-000011":{"channel_id":"C1","message_ts":"1","type":"design","summary":"which way","sent_at":"2026-10-29T00:00:00Z","resolved":false},
 "T20000101-000012":{"channel_id":"C1","message_ts":"2","type":"design","summary":"done","sent_at":"2026-10-29T00:00:00Z","resolved":true}}
J
  data --date 2026-10-30
  [ "$status" -eq 0 ]
  jq -e '.errors == {}' <<<"$output"
  [ "$(jq -r '.date, .since' <<<"$output" | paste -sd, -)" = "2026-10-30,2026-10-29" ]
  [ "$(jq -r '.git_log | map(.subject) | join("|")' <<<"$output")" = "yesterday work" ]
  [ "$(jq -r '.merged_prs | map(.number) | join(",")' <<<"$output")" = "20,21" ]
  [ "$(jq -r '.open_prs | length' <<<"$output")" -eq 4 ]
  [ "$(jq -r '.journal_yesterday | join(",")' <<<"$output")" = "2026-10-29-T20000101-000011-thing.md,2026-10-29-daily-summary.md" ]
  [ "$(jq -r '.previous_summary' <<<"$output")" = "dev/JOURNAL/2026-10-29-daily-summary.md" ]
  [ "$(jq -r '.threads | map(.key) | join(",")' <<<"$output")" = "T20000101-000011" ]
  [ "$(jq -r '.threads[0].summary' <<<"$output")" = "which way" ]
  [ "$(jq -r '.ipm_file' <<<"$output")" = "" ]
  [ "$(jq -r '.nightly.total, (.nightly.failures | length), .nightly.failures[0].name' <<<"$output" | paste -sd, -)" = "3,1,Nightly B" ]
  # the one task journal dated yesterday ships from an unattributed location
  [ "$(jq -r '.attribution[0] | [.location,.class,.shipped,.in_flight,.total] | join("|")' <<<"$output")" = "(unattributed)|unattributed|1|0|1" ]
  [[ "$(jq -r '.epics.text' <<<"$output")" == *"Epics unavailable"* ]]
}

@test "standup-data: attention applies the deterministic 1.2a rules only" {
  seed_gh
  mkdir -p "$R/.claude/state"
  echo '{"T20000101-000011-pr11":{"channel_id":"C","message_ts":"1","type":"x","summary":"s","sent_at":"2026-10-29T00:00:00Z","resolved":false}}' > "$THREADS_FILE"
  data --date 2026-10-30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.attention | map(.number) | join(",")' <<<"$output")" = "11,12" ]
  [ "$(jq -r '.attention[0].reasons | join("|")' <<<"$output")" = "unchecked pre-merge item needs a human decision|unresolved escalation on T20000101-000011" ]
  [ "$(jq -r '.attention[1].reasons[0]' <<<"$output")" = "merge conflicts" ]
}

@test "standup-data: a failing gh section degrades to its default with an error, exit 0" {
  seed_gh
  FAKE_GH_FAIL='^run list' data --date 2026-10-30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.errors | keys | join(",")' <<<"$output")" = "nightly" ]
  [ "$(jq -r '.nightly.total' <<<"$output")" = "0" ]
  [ "$(jq -r '.merged_prs | length' <<<"$output")" -eq 2 ]
}

@test "standup-data: gh entirely down -> every gh section errors, still valid JSON" {
  FAKE_GH_FAIL='.' data --date 2026-10-30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.errors | keys | join(",")' <<<"$output")" = "merged_prs,nightly,open_prs" ]
  [ "$(jq -r '.attention' <<<"$output")" = "[]" ]
}

@test "standup-data: the date defaults to TODAY and crosses a month boundary" {
  seed_gh
  TODAY=2026-11-01 data
  [ "$(jq -r '.since' <<<"$output")" = "2026-10-31" ]
}

@test "standup-data: bad usage and bad dates fail with exit 2/3, no JSON" {
  data --date 2026-02-31
  [ "$status" -eq 2 ]
  data --date
  [ "$status" -eq 2 ]
  data --bogus
  [ "$status" -eq 2 ]
  run bash "$DATA" --dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
}

# ---- render-standup.sh ------------------------------------------------------

FX_DIR="$BATS_TEST_DIRNAME/fixtures/standup"

render() { run bash "$RENDER" "$@"; }
# mut <file> <jq filter> -> a modified copy of a fixture under $BATS_TEST_TMPDIR
mut() { jq "$2" "$FX_DIR/$1" > "$BATS_TEST_TMPDIR/m-$1"; printf '%s' "$BATS_TEST_TMPDIR/m-$1"; }

@test "render-standup: slack output matches the golden file" {
  render "$FX_DIR/data.json" "$FX_DIR/judgment.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FX_DIR/slack.golden")" ]
}

@test "render-standup: journal output matches the golden file" {
  render "$FX_DIR/data.json" "$FX_DIR/judgment.json" --format journal
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FX_DIR/journal.golden")" ]
}

@test "render-standup: deterministic, byte-identical on a second run" {
  a="$(bash "$RENDER" "$FX_DIR/data.json" "$FX_DIR/judgment.json")"
  b="$(bash "$RENDER" "$FX_DIR/data.json" "$FX_DIR/judgment.json")"
  [ "$a" = "$b" ]
}

@test "render-standup: optional blocks vanish, headline blocks fall back (omit-rule matrix)" {
  d="$(mut data.json '.merged_prs=[] | .attention=[] | .threads=[] | .attribution=[] | .epics={text:"",slack:[]} | .nightly.failures=[]')"
  j="$(mut judgment.json 'del(.weekly_focus) | .top5=[] | .nightly_failures=[]')"
  render "$d" "$j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing merged yesterday"* ]]
  [[ "$output" == *"*🌙 Nightly*: all green (3 runs)"* ]]
  [[ "$output" == *"None — every open PR is actionable or already in flight"* ]]
  [[ "$output" == *"None — nothing workable in the queue"* ]]
  [[ "$output" == *"• None"* ]]
  [[ "$output" != *"Epic progress"* ]]
  [[ "$output" != *"Weekly focus"* ]]
  [[ "$output" != *"Attribution"* ]]
}

@test "render-standup: a failure with no task renders the no-task fallback" {
  j="$(mut judgment.json '.nightly_failures=[{run:902,classification:"Infrastructure"}]')"
  render "$FX_DIR/data.json" "$j"
  [[ "$output" == *"Nightly B (run 902) — Infrastructure — no task filed (transient/infra)"* ]]
}

@test "render-standup: a nightly failure without judgment is an input error (exit 4)" {
  j="$(mut judgment.json '.nightly_failures=[]')"
  render "$FX_DIR/data.json" "$j"
  [ "$status" -eq 4 ]
  [[ "$output" == *"nightly_failures run 902"* ]]
}

@test "render-standup: judgment without top5 is an input error (exit 4)" {
  j="$(mut judgment.json 'del(.top5)')"
  render "$FX_DIR/data.json" "$j"
  [ "$status" -eq 4 ]
}

@test "render-standup: a failed data section renders unavailable, never clean" {
  d="$(mut data.json '.errors={nightly:"x",merged_prs:"x",open_prs:"x"}')"
  j="$(mut judgment.json 'del(.attention)')"
  render "$d" "$j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*✅ Resolved*: unavailable"* ]]
  [[ "$output" == *"*🌙 Nightly*: unavailable"* ]]
  [[ "$output" == *"*🔀 Needs your attention*: unavailable"* ]]
}

@test "render-standup: judgment attention replaces the data list (CI rule)" {
  j="$(mut judgment.json '.attention=[{pr:5,title:"flaky",why:"CI red twice"}]')"
  render "$FX_DIR/data.json" "$j"
  [[ "$output" == *"• PR #5 — flaky — CI red twice"* ]]
  [[ "$output" != *"needs a call"* ]]
}

@test "render-standup: 60 merged PRs trigger the trim ladder, headline sections survive" {
  d="$(mut data.json '.merged_prs=[range(100;160) | {number:., title:"pr", mergedAt:"x"}]')"
  j="$(mut judgment.json '.resolved=[range(100;160) | {pr:., text:("<u|T20000101-\(.)> — " + ("detail " * 8) + "\nextra second line")}]')"
  render "$d" "$j" --max-chars 100000
  [ "$status" -eq 0 ]
  [[ "$output" == *"*📊 Attribution*"* ]]
  full="${#output}"
  render "$d" "$j" --max-chars "$(( full - 1 ))"
  [ "$status" -eq 0 ]
  [[ "$output" != *"extra second line"* ]]
  [[ "$output" == *"*📊 Attribution*"* ]]
  [ "${#output}" -lt "$full" ]
  # tighter still: Attribution goes before any headline section
  l1="${#output}"
  render "$d" "$j" --max-chars "$(( l1 - 1 ))"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Attribution"* ]]
  [[ "$output" == *"*✅ Resolved* (60)"* ]]
  [[ "$output" == *"*🚧 Blockers*"* ]]
  [ "${#output}" -le "$(( l1 - 1 ))" ]
}

@test "render-standup: still too long after the ladder -> exit 5, empty stdout" {
  run bash -c 'bash "$1" "$2" "$3" --max-chars 50 2>/dev/null' _ "$RENDER" "$FX_DIR/data.json" "$FX_DIR/judgment.json"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "render-standup: bad usage and bad input fail closed" {
  render
  [ "$status" -eq 2 ]
  render "$FX_DIR/data.json" "$FX_DIR/judgment.json" --format html
  [ "$status" -eq 2 ]
  render "$FX_DIR/data.json" "$FX_DIR/judgment.json" --max-chars abc
  [ "$status" -eq 2 ]
  render "$FX_DIR/data.json" "$FX_DIR/judgment.json" --bogus x
  [ "$status" -eq 2 ]
  render "$BATS_TEST_TMPDIR/missing.json" "$FX_DIR/judgment.json"
  [ "$status" -eq 3 ]
  echo '{}' > "$BATS_TEST_TMPDIR/empty.json"
  render "$BATS_TEST_TMPDIR/empty.json" "$FX_DIR/judgment.json"
  [ "$status" -eq 3 ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  render "$FX_DIR/data.json" "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 3 ]
}

@test "standup end to end: data feeds the renderer; gh output needs no network" {
  seed_gh
  commit_at "2026-10-29T10:00:00Z" "yesterday work"
  data --date 2026-10-30
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/data.json"
  echo '{"top5":["<u|T1> — first"],"nightly_failures":[{"run":902,"classification":"Transient"}]}' > "$BATS_TEST_TMPDIR/j.json"
  render "$BATS_TEST_TMPDIR/data.json" "$BATS_TEST_TMPDIR/j.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*Daily Standup* (2026-10-30)"* ]]
  [[ "$output" == *"• first merged (PR #20)"* ]]
  [[ "$output" == *"1 failure(s) / 3 runs"* ]]
  [[ "$output" == *"• PR #12 — conflicted — merge conflicts"* ]]
  # nothing was posted anywhere: only read-only gh calls were made
  ! grep -Eq '^(pr (merge|comment|create)|api .*POST)' "$FAKE_GH_LOG"
}

@test "render-standup: failed threads/epics/attribution reads render unavailable (slack and journal)" {
  d="$(mut data.json '.errors={threads:"x",epics:"x",attribution:"x",attention:"x"} | .threads=[]')"
  j="$(mut judgment.json 'del(.attention)')"
  render "$d" "$j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"• unavailable (escalation read failed)"* ]]
  [[ "$output" == *"unavailable (epic read failed)"* ]]
  [[ "$output" == *"unavailable (attribution read failed)"* ]]
  [[ "$output" == *"*🔀 Needs your attention*: unavailable"* ]]
  [[ "$output" != *"• None"* ]]
  render "$d" "$j" --format journal
  [[ "$output" == *"Unavailable — escalation read failed."* ]]
  [[ "$output" == *"Unavailable — epic read failed."* ]]
  [[ "$output" == *"Unavailable — attribution read failed."* ]]
}

@test "render-standup: data-derived text is Slack-escaped (no <!channel> injection)" {
  d="$(mut data.json '.merged_prs=[{number:30,title:"<!channel> & more",mergedAt:"x"}] | .attention=[{number:31,title:"<@U1> hi",reasons:["merge conflicts"]}] | .threads[0].summary="<!here>"')"
  j="$(mut judgment.json 'del(.resolved) | del(.attention)')"
  render "$d" "$j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"&lt;!channel&gt; &amp; more (PR #30)"* ]]
  [[ "$output" == *"PR #31 — &lt;@U1&gt; hi"* ]]
  [[ "$output" == *"&lt;!here&gt;"* ]]
  [[ "$output" != *"<!channel>"* && "$output" != *"<!here>"* && "$output" != *"<@U1>"* ]]
}

@test "standup-data: an unreadable threads file fails threads and attention, never 'none'" {
  seed_gh
  mkdir -p "$R/.claude/state"
  printf '{not json' > "$THREADS_FILE"
  data --date 2026-10-30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.errors | keys | join(",")' <<<"$output")" = "attention,threads" ]
}

@test "standup-data: a failing PR-to-task lookup fails the attention section" {
  seed_gh
  export STANDUP_PR_TASK_ID="false"
  data --date 2026-10-30
  [ "$(jq -r '.errors | keys | join(",")' <<<"$output")" = "attention" ]
}
