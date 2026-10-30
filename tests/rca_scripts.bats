#!/usr/bin/env bats
# rca/scripts/action-plan.sh (the step 6 gating matrix) and
# rca/scripts/midweek-add.sh (the mid-week table row). Offline: temp IPM
# fixtures, fake task ids (T20000101-...), a pinned clock. Neither script runs,
# posts or pushes anything.

load test_helper

PLAN="$REPO_ROOT/rca/scripts/action-plan.sh"
ADD="$REPO_ROOT/rca/scripts/midweek-add.sh"

setup() {
  export TODAY=2026-10-30 TZ=UTC TMPDIR="$BATS_TEST_TMPDIR"
  IPM="$BATS_TEST_TMPDIR/2026-10-26-ipm-weekly.md"
}

# plan <args...>: stdout lines joined with ';' in $output
plan() { run bash "$PLAN" "$@"; out="$(printf '%s' "$output" | paste -sd';' -)"; }

fixture() {   # fixture [rows...]: an IPM file whose mid-week table holds the rows
  {
    printf '# IPM\n\n## Committed\n\n| # | Task |\n|---|------|\n| 1 | T20000101-000099 |\n\n'
    printf '## Mid-week additions (appended after IPM commit)\n\n*note line*\n\n'
    printf '| # | Task | Est | Added | Why this iteration |\n|---|------|-----|-------|--------------------|\n'
    if [ $# -eq 0 ]; then printf '| (none yet) | | | | |\n'; else printf '%s\n' "$@"; fi
    printf '\n## Considered but cut\n\n| Task | Reason |\n|------|--------|\n| T20000101-000098 | big |\n'
  } > "$IPM"
}

# ---- action-plan.sh: class x confidence matrix -----------------------------

@test "plan: our code / upstream / configuration confirmed -> fix task + promote" {
  for c in our-code upstream configuration "Our code" Upstream; do
    plan --class "$c" --confidence confirmed
    [ "$status" -eq 0 ]
    [ "$out" = "TASK kind=fix;PROMOTE" ]
  done
}

@test "plan: the same three unconfirmed -> instrumentation task + promote" {
  for c in our-code upstream configuration; do
    plan --class "$c" --confidence Unconfirmed
    [ "$out" = "TASK kind=instrument;PROMOTE" ]
  done
}

@test "plan: transient files a task only at 3+ occurrences in the week" {
  plan --class transient --confidence confirmed --recent 2
  [ "$out" = "NOTE reason=transient, fewer than 3 occurrences in the last 7 days" ]
  plan --class transient --confidence confirmed --recent 3
  [ "$out" = "TASK kind=fix;PROMOTE" ]
  plan --class transient --confidence confirmed --recent 0
  [[ "$out" == NOTE* ]]
}

@test "plan: transient unconfirmed always files the instrumentation task" {
  plan --class transient --confidence unconfirmed --recent 0
  [ "$out" = "TASK kind=instrument;PROMOTE" ]
}

@test "plan: infrastructure always retries first; the task depends on the retry" {
  plan --class infrastructure --confidence confirmed
  [ "$out" = "RETRY;IF_RETRY_FAILS TASK kind=fix;IF_RETRY_FAILS PROMOTE" ]
  plan --class infrastructure --confidence confirmed --retry-result fail
  [ "$out" = "RETRY;TASK kind=fix;PROMOTE" ]
  plan --class infrastructure --confidence confirmed --retry-result pass
  [ "$out" = "RETRY;NOTE reason=retry passed, no task needed" ]
}

@test "plan: infrastructure unconfirmed retries AND files, whatever the retry did" {
  for r in pending pass fail; do
    plan --class infrastructure --confidence unconfirmed --retry-result "$r"
    [ "$out" = "RETRY;TASK kind=instrument;PROMOTE" ]
  done
}

@test "plan: an open KB task re-tops instead of filing; infra still retries" {
  plan --class our-code --confidence confirmed --kb-task-open T20000101-000001
  [ "$out" = "TOP id=T20000101-000001" ]
  plan --class our-code --confidence confirmed --kb-task-open
  [ "$out" = "TOP" ]
  plan --class transient --confidence confirmed --kb-task-open T20000101-000001 --recent 1
  [ "$out" = "TOP id=T20000101-000001" ]
  plan --class infrastructure --confidence confirmed --kb-task-open T20000101-000001 --retry-result pass
  [ "$out" = "RETRY;TOP id=T20000101-000001" ]
}

@test "plan: every class x confidence cell is covered and exits 0" {
  for c in our-code upstream configuration transient infrastructure; do
    for k in confirmed unconfirmed; do
      extra=(); [ "$c" = transient ] && extra=(--recent 1)
      plan --class "$c" --confidence "$k" "${extra[@]}"
      [ "$status" -eq 0 ]
      [ -n "$output" ]
    done
  done
}

@test "plan: inconsistent or missing inputs exit 2 and print no plan" {
  for args in "" "--class our-code" "--confidence confirmed" \
      "--class weather --confidence confirmed" "--class our-code --confidence maybe" \
      "--class transient --confidence confirmed" "--class transient --confidence confirmed --recent x" \
      "--class our-code --confidence confirmed --recent 3" \
      "--class our-code --confidence unconfirmed --kb-task-open" \
      "--class our-code --confidence confirmed --retry-result fail" \
      "--class infrastructure --confidence confirmed --retry-result later" \
      "--class our-code --confidence confirmed --bogus"; do
    # shellcheck disable=SC2086
    run bash "$PLAN" $args
    [ "$status" -eq 2 ]
    [[ "$output" != *TASK* && "$output" != *PROMOTE* ]]
  done
}

# ---- midweek-add.sh ---------------------------------------------------------

@test "midweek: placeholder row is replaced by row 1" {
  fixture
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why "RCA auto-promote - Our code failure"
  [ "$status" -eq 0 ]
  [ "$output" = "ADDED #1 T20000101-000001" ]
  grep -qxF '| 1 | T20000101-000001 | 2 | 2026-10-30 | RCA auto-promote - Our code failure |' "$IPM"
  ! grep -q 'none yet' "$IPM"
}

@test "midweek: appends after the last data row with the next number" {
  fixture '| 1 | T20000101-000010 | 1 | 2026-10-27 | a |' '| 4 | T20000101-000011 | 3 | 2026-10-28 | b |'
  run bash "$ADD" --file "$IPM" --task T20000101-000002 --est 5 --why w --added 2026-10-29
  [ "$status" -eq 0 ]
  [ "$output" = "ADDED #5 T20000101-000002" ]
  rows="$(sed -n '/^## Mid-week/,/^## Considered/p' "$IPM" | grep -c '^| [0-9]')"
  [ "$rows" -eq 3 ]
  grep -qxF '| 5 | T20000101-000002 | 5 | 2026-10-29 | w |' "$IPM"
}

@test "midweek: the rest of the file is byte-identical" {
  fixture
  cp "$IPM" "$BATS_TEST_TMPDIR/before"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/before" "$IPM"
  # only the placeholder line left and the new row arrived
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
  grep -qxF '| 1 | T20000101-000099 |' "$IPM"
  grep -qxF '| T20000101-000098 | big |' "$IPM"
}

@test "midweek: a task already listed exits 10 and writes nothing (idempotent)" {
  fixture
  bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w
  cp "$IPM" "$BATS_TEST_TMPDIR/after-first"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 8 --why other
  [ "$status" -eq 10 ]
  [[ "$output" == *"ALREADY T20000101-000001"* ]]
  cmp "$IPM" "$BATS_TEST_TMPDIR/after-first"
}

@test "midweek: a task in a link cell counts as listed" {
  fixture '| 1 | [T20000101-000001](https://example.com/i/1) | 1 | 2026-10-27 | a |'
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w
  [ "$status" -eq 10 ]
}

@test "midweek: a task listed in ANOTHER table does not block the add" {
  fixture
  sed -i.bak 's/T20000101-000098/T20000101-000001/' "$IPM"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w
  [ "$status" -eq 0 ]
}

@test "midweek: --url renders a link cell; --dry-run writes nothing" {
  fixture
  cp "$IPM" "$BATS_TEST_TMPDIR/before"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w --url https://example.com/issues/1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "DRY-RUN | 1 | [T20000101-000001](https://example.com/issues/1) | 2 | 2026-10-30 | w |" ]]
  cmp "$IPM" "$BATS_TEST_TMPDIR/before"
}

@test "midweek: a table at the very end of the file (no trailing section) works" {
  printf '## Mid-week additions\n\n| # | Task | Est | Added | Why |\n|---|---|---|---|---|\n| (none yet) | | | | |\n' > "$IPM"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$IPM")" = '| 1 | T20000101-000001 | 2 | 2026-10-30 | w |' ]
}

@test "midweek: missing heading / header / separator exits 4 and writes nothing" {
  printf '# IPM\n\nno table here\n' > "$IPM"; cp "$IPM" "$BATS_TEST_TMPDIR/b"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w; [ "$status" -eq 4 ]; cmp "$IPM" "$BATS_TEST_TMPDIR/b"
  printf '## Mid-week additions\n\njust prose\n\n## Next\n' > "$IPM"; cp "$IPM" "$BATS_TEST_TMPDIR/b"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w; [ "$status" -eq 4 ]; cmp "$IPM" "$BATS_TEST_TMPDIR/b"
  printf '## Mid-week additions\n\n| # | Task |\nnot a separator\n' > "$IPM"; cp "$IPM" "$BATS_TEST_TMPDIR/b"
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why w; [ "$status" -eq 4 ]; cmp "$IPM" "$BATS_TEST_TMPDIR/b"
}

@test "midweek: usage errors exit 2, a missing file exits 3" {
  fixture
  for args in "" "--task T20000101-000001 --est 2 --why w" "--file $IPM --task bad --est 2 --why w" \
      "--file $IPM --task T20000101-000001 --why w" "--file $IPM --task T20000101-000001 --est 2" \
      "--file $IPM --task T20000101-000001 --est 2 --why w --added 2026-02-31" \
      "--file $IPM --task T20000101-000001 --est 2 --why w --url ftp://x" "--file $IPM --bogus"; do
    # shellcheck disable=SC2086
    run bash "$ADD" $args
    [ "$status" -eq 2 ]
  done
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est "2|3" --why w; [ "$status" -eq 2 ]
  run bash "$ADD" --file "$IPM" --task T20000101-000001 --est 2 --why $'a\nb'; [ "$status" -eq 2 ]
  run bash "$ADD" --file "$BATS_TEST_TMPDIR/nope.md" --task T20000101-000001 --est 2 --why w; [ "$status" -eq 3 ]
  grep -q 'none yet' "$IPM"
}

@test "midweek: works from a skills root whose path contains a space" {
  fixture
  mkdir -p "$BATS_TEST_TMPDIR/skills root"
  tar -C "$REPO_ROOT" --exclude=.git -cf - rca _date | tar -C "$BATS_TEST_TMPDIR/skills root" -xf -
  run bash "$BATS_TEST_TMPDIR/skills root/rca/scripts/midweek-add.sh" --file "$IPM" --task T20000101-000001 --est 2 --why w
  [ "$status" -eq 0 ]
  run bash "$BATS_TEST_TMPDIR/skills root/rca/scripts/action-plan.sh" --class our-code --confidence confirmed
  [ "$status" -eq 0 ]
}

@test "rca scripts never call gh, git push or any network tool" {
  run grep -nE '\b(gh|curl|wget|ssh|git push|slack)\b' "$PLAN" "$ADD"
  # only comment lines may mention them
  [ -z "$(printf '%s\n' "$output" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" ]
}
