#!/usr/bin/env bats
# Tests for retro/scripts/estimation-revisions.sh — emits each task's
# estimation-revision arc from the task file's git history (both metadata
# formats: frontmatter `estimation:` and legacy `- **Estimation**:` bullet),
# windowed by --since. Deterministic: commit dates are injected via
# GIT_AUTHOR_DATE/GIT_COMMITTER_DATE, and --since is passed explicitly.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/retro/scripts/estimation-revisions.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev/TODO" "$WORK/dev/JOURNAL"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name tester
}

# commit everything with an injected date. $1=YYYY-MM-DD $2=message
commit_dated() {
  local d="$1" msg="$2"
  git -C "$WORK" add -A
  GIT_AUTHOR_DATE="${d}T12:00:00" GIT_COMMITTER_DATE="${d}T12:00:00" \
    git -C "$WORK" commit -q -m "$msg"
}

# write a frontmatter task file. $1=path-rel $2=estimation-value
mk_fm() {
  { echo '---'; echo 'status: Open'; echo "estimation: $2"; echo '---';
    echo; echo '# Task'; } > "$WORK/$1"
}

run_script() { run bash "$SCRIPT" --repo-root "$WORK" "$@"; }

@test "(a) frontmatter estimation revised twice — arc shows filed + both revisions" {
  mk_fm dev/TODO/T20260601-111111-x.md '1h'
  commit_dated 2026-06-22 'file task'
  mk_fm dev/TODO/T20260601-111111-x.md '2h'
  commit_dated 2026-06-23 'revise est to 2h'
  mk_fm dev/TODO/T20260601-111111-x.md '1-2d'
  commit_dated 2026-06-24 'revise est to 1-2d'

  run_script --since 2026-06-20 T20260601-111111
  [ "$status" -eq 0 ]
  [[ "$output" == *"filed \`1h\`"* ]]
  [[ "$output" == *"\`2h\`"* ]]
  [[ "$output" == *"\`1-2d\`"* ]]
}

@test "(b) legacy '- **Estimation**:' bullet is parsed too" {
  { echo '# Task'; echo; echo '- **Status**: Open'; echo '- **Estimation**: 1d'; } \
    > "$WORK/dev/TODO/T20260602-222222-y.md"
  commit_dated 2026-06-22 'file legacy task'
  { echo '# Task'; echo; echo '- **Status**: Open'; echo '- **Estimation**: 2d'; } \
    > "$WORK/dev/TODO/T20260602-222222-y.md"
  commit_dated 2026-06-23 'revise legacy est to 2d'

  run_script --since 2026-06-20 T20260602-222222
  [ "$status" -eq 0 ]
  [[ "$output" == *"filed \`1d\`"* ]]
  [[ "$output" == *"\`2d\`"* ]]
}

@test "(c) no in-window estimation change — emits 'no revisions'" {
  mk_fm dev/TODO/T20260603-333333-z.md '4h'
  commit_dated 2026-01-01 'file task long ago'

  run_script --since 2026-06-20 T20260603-333333
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260603-333333: no revisions"* ]]
}

@test "(d) --follow captures a file moved TODO->JOURNAL" {
  mk_fm dev/TODO/T20260604-444444-w.md '2h'
  commit_dated 2026-06-22 'file task'
  mk_fm dev/TODO/T20260604-444444-w.md '4h'
  commit_dated 2026-06-23 'revise est to 4h'
  git -C "$WORK" mv dev/TODO/T20260604-444444-w.md \
    dev/JOURNAL/2026-06-24-T20260604-444444-w.md
  commit_dated 2026-06-24 'close: move to journal'

  run_script --since 2026-06-20 T20260604-444444
  [ "$status" -eq 0 ]
  [[ "$output" == *"filed \`2h\`"* ]]
  [[ "$output" == *"\`4h\`"* ]]
}

@test "(e) --since window excludes an older revision" {
  mk_fm dev/TODO/T20260605-555555-v.md '1h'
  commit_dated 2026-01-01 'file task (out of window)'
  mk_fm dev/TODO/T20260605-555555-v.md '2h'
  commit_dated 2026-01-05 'revise to 2h (out of window)'
  mk_fm dev/TODO/T20260605-555555-v.md '1d'
  commit_dated 2026-06-24 'revise to 1d (in window)'

  run_script --since 2026-06-20 T20260605-555555
  [ "$status" -eq 0 ]
  [[ "$output" == *"\`1d\`"* ]]
  [[ "$output" != *"\`2h\`"* ]]
  # the in-window first event is NOT a file-creation, so it must not say "filed"
  [[ "$output" != *"filed"* ]]
}

@test "missing task file is reported, not fatal" {
  run_script --since 2026-06-20 T20269999-000000
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20269999-000000: (task file not found)"* ]]
}

@test "no task ids -> usage error (exit 2)" {
  run bash "$SCRIPT" --repo-root "$WORK"
  [ "$status" -eq 2 ]
}
