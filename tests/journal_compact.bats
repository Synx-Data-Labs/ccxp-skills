#!/usr/bin/env bats
# Tests for _journal/compact.sh — monthly JOURNAL compaction into
# archive/YYYY-MM/ + a YYYY-MM-digest.md summary (T20260515-128802).
# Isolated tmp git repos only — never touches the real ccxp-skills/hub-repo repos.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/_journal/compact.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev/JOURNAL"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name tester
}

commit_dated() {
  local d="$1" msg="$2"
  git -C "$WORK" add -A
  GIT_AUTHOR_DATE="${d}T12:00:00" GIT_COMMITTER_DATE="${d}T12:00:00" \
    git -C "$WORK" commit -q -m "$msg"
}

@test "month with 0 closures -> valid empty digest, N=0" {
  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/JOURNAL/2026-04-digest.md" ]
  grep -q '\*\*Files archived\*\*: 0' "$WORK/dev/JOURNAL/2026-04-digest.md"
  grep -q '### Tasks closed this month' "$WORK/dev/JOURNAL/2026-04-digest.md"
  grep -q '### Other files archived this month' "$WORK/dev/JOURNAL/2026-04-digest.md"
}

@test "month with 100+ closures completes without truncation" {
  local i n
  for i in $(seq 1 120); do
    n="$(printf '%06d' "$i")"
    cat > "$WORK/dev/JOURNAL/2026-04-01-T20260401-$n-fix.md" <<EOF
# T20260401-$n: Fix $i

## Closed (2026-04-05)
Shipped via ccxp-skills#$i — fixed thing $i.
EOF
  done
  commit_dated 2026-04-05 "add 120 closure files"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  grep -q '\*\*Files archived\*\*: 120' "$WORK/dev/JOURNAL/2026-04-digest.md"
  [ "$(grep -c '^| T' "$WORK/dev/JOURNAL/2026-04-digest.md")" -eq 120 ]
}

@test "month-boundary crossing: filename date wins over content date" {
  cat > "$WORK/dev/JOURNAL/2026-05-01-T20260501-000001-x.md" <<'EOF'
# T20260501-000001: Boundary case

## Closed (2026-04-30)
Work was actually closed on 2026-04-30 per the prose here.
EOF
  commit_dated 2026-05-01 "add boundary file"

  run bash "$SCRIPT" 2026-05 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/JOURNAL/archive/2026-05/2026-05-01-T20260501-000001-x.md" ]
  grep -q 'T20260501-000001' "$WORK/dev/JOURNAL/2026-05-digest.md"

  # A fresh clone (April run must not have picked it up) -- re-derive from a
  # second independent WORK copy so the May run above doesn't interfere.
  local WORK2="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$WORK2/dev/JOURNAL"
  git -C "$WORK2" init -q
  git -C "$WORK2" config user.email t@example.com
  git -C "$WORK2" config user.name tester
  cp "$WORK/dev/JOURNAL/archive/2026-05/2026-05-01-T20260501-000001-x.md" \
     "$WORK2/dev/JOURNAL/2026-05-01-T20260501-000001-x.md" 2>/dev/null || true
  git -C "$WORK2" add -A
  GIT_AUTHOR_DATE="2026-05-01T12:00:00" GIT_COMMITTER_DATE="2026-05-01T12:00:00" \
    git -C "$WORK2" commit -q -m "add boundary file"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK2"
  [ "$status" -eq 0 ]
  grep -q '\*\*Files archived\*\*: 0' "$WORK2/dev/JOURNAL/2026-04-digest.md"
}

@test "no filename date prefix falls back to last-commit date" {
  printf '# Retro notes\n\nSome weekly retro content.\n' > "$WORK/dev/JOURNAL/retro-notes.md"
  commit_dated 2026-04-15 "add retro notes"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/JOURNAL/archive/2026-04/retro-notes.md" ]
  grep -q 'retro-notes.md' "$WORK/dev/JOURNAL/2026-04-digest.md"
}

@test "file with no ## Closed section still listed with - placeholders" {
  cat > "$WORK/dev/JOURNAL/2026-04-02-T20260402-000002-y.md" <<'EOF'
# T20260402-000002: Something

Some prose, no Closed heading at all.
EOF
  commit_dated 2026-04-02 "add no-closed task file"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  grep -qE '^\| T20260402-000002 \| Something \| - \| - \|$' "$WORK/dev/JOURNAL/2026-04-digest.md"
}

@test "git mv preserves history: git log --follow shows original commits" {
  printf '# T20260403-000003: Zed\n\nInitial body.\n' > "$WORK/dev/JOURNAL/2026-04-03-T20260403-000003-z.md"
  commit_dated 2026-04-03 "add zed task file"
  printf '# T20260403-000003: Zed\n\n## Closed (2026-04-04)\nDone via hub-repo#42.\n' > "$WORK/dev/JOURNAL/2026-04-03-T20260403-000003-z.md"
  commit_dated 2026-04-04 "close zed task file"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  commit_dated 2026-04-06 "compact 2026-04"

  local n
  n="$(git -C "$WORK" log --follow --oneline -- dev/JOURNAL/archive/2026-04/2026-04-03-T20260403-000003-z.md | wc -l)"
  [ "$n" -ge 2 ]
}

@test "end-to-end: ~10 mixed files produce correct digest and archive layout" {
  # 3 task-closure files (with ## Closed + PR refs)
  cat > "$WORK/dev/JOURNAL/2026-06-01-T20260601-100001-a.md" <<'EOF'
# T20260601-100001: Alpha fix

## Closed (2026-06-02)
Landed via ccxp-skills#10 — fixed alpha.
EOF
  cat > "$WORK/dev/JOURNAL/2026-06-02-T20260601-100002-b.md" <<'EOF'
# T20260601-100002: Bravo fix

## Closed (2026-06-03)
Landed via hub-repo#11 — fixed bravo.
EOF
  cat > "$WORK/dev/JOURNAL/2026-06-03-T20260601-100003-c.md" <<'EOF'
# T20260601-100003: Charlie fix

## Closed (2026-06-04)
Landed via #12 — fixed charlie.
EOF
  # 1 task-closure file with no ## Closed
  cat > "$WORK/dev/JOURNAL/2026-06-04-T20260601-100004-d.md" <<'EOF'
# T20260601-100004: Delta fix

No closed heading here.
EOF
  # 1 retro-weekly + 1 ipm-weekly, no date prefix (commit-dated)
  printf '# Retro weekly\n\nWeekly retro content.\n' > "$WORK/dev/JOURNAL/retro-weekly.md"
  printf '# IPM weekly\n\nWeekly IPM content.\n' > "$WORK/dev/JOURNAL/ipm-weekly.md"
  # 1 out-of-month control file (must NOT be archived)
  cat > "$WORK/dev/JOURNAL/2026-05-15-T20260501-999999-control.md" <<'EOF'
# T20260501-999999: Out of month control

## Closed (2026-05-16)
Landed via ccxp-skills#99.
EOF
  # 3 more mixed task files to reach ~10
  cat > "$WORK/dev/JOURNAL/2026-06-05-T20260601-100005-e.md" <<'EOF'
# T20260601-100005: Echo fix

## Closed (2026-06-06)
Landed via ccxp-skills#13 — fixed echo.
EOF
  cat > "$WORK/dev/JOURNAL/2026-06-06-T20260601-100006-f.md" <<'EOF'
# T20260601-100006: Foxtrot fix

## Closed (2026-06-07)
Landed via ccxp-skills#14 — fixed foxtrot.
EOF
  cat > "$WORK/dev/JOURNAL/2026-06-07-T20260601-100007-g.md" <<'EOF'
# T20260601-100007: Golf fix

## Closed (2026-06-08)
Landed via ccxp-skills#15 — fixed golf.
EOF
  commit_dated 2026-06-10 "add ~10 mixed june journal files"

  run bash "$SCRIPT" 2026-06 --repo-root "$WORK"
  [ "$status" -eq 0 ]

  grep -q '\*\*Files archived\*\*: 9' "$WORK/dev/JOURNAL/2026-06-digest.md"
  grep -qE '^\| T20260601-100001 \| Alpha fix \| ccxp-skills#10 \| Landed via ccxp-skills#10 — fixed alpha\. \|$' "$WORK/dev/JOURNAL/2026-06-digest.md"
  grep -qE '^\| T20260601-100004 \| Delta fix \| - \| - \|$' "$WORK/dev/JOURNAL/2026-06-digest.md"
  grep -q -- '- retro-weekly.md' "$WORK/dev/JOURNAL/2026-06-digest.md"
  grep -q -- '- ipm-weekly.md' "$WORK/dev/JOURNAL/2026-06-digest.md"

  local listing
  listing="$(ls "$WORK/dev/JOURNAL/archive/2026-06/" | sort)"
  [[ "$listing" == *"2026-06-01-T20260601-100001-a.md"* ]]
  [[ "$listing" == *"2026-06-07-T20260601-100007-g.md"* ]]
  [[ "$listing" == *"retro-weekly.md"* ]]
  [[ "$listing" == *"ipm-weekly.md"* ]]
  [[ "$listing" != *"control"* ]]

  # out-of-month control file stays un-archived
  [ -f "$WORK/dev/JOURNAL/2026-05-15-T20260501-999999-control.md" ]
  [ ! -d "$WORK/dev/JOURNAL/archive/2026-05" ]
}

@test "--dry-run does not modify the filesystem" {
  cat > "$WORK/dev/JOURNAL/2026-07-01-T20260701-000001-a.md" <<'EOF'
# T20260701-000001: A task

## Closed (2026-07-02)
Landed via ccxp-skills#20.
EOF
  printf '# Retro weekly\n' > "$WORK/dev/JOURNAL/retro-weekly-07.md"
  commit_dated 2026-07-02 "add july fixtures"

  local before_find before_status after_find after_status
  before_find="$(find "$WORK/dev/JOURNAL" -type f | sort)"
  before_status="$(git -C "$WORK" status --porcelain)"

  run bash "$SCRIPT" 2026-07 --repo-root "$WORK" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would archive"* ]]
  [[ "$output" == *"JOURNAL digest: 2026-07"* ]]

  after_find="$(find "$WORK/dev/JOURNAL" -type f | sort)"
  after_status="$(git -C "$WORK" status --porcelain)"

  [ "$before_find" = "$after_find" ]
  [ "$before_status" = "$after_status" ]
  [ ! -d "$WORK/dev/JOURNAL/archive" ]
  [ ! -f "$WORK/dev/JOURNAL/2026-07-digest.md" ]
}

@test "missing <month> argument -> usage error, exit 2" {
  run bash "$SCRIPT" --repo-root "$WORK"
  [ "$status" -eq 2 ]
}

@test "invalid month format -> usage error, exit 2" {
  run bash "$SCRIPT" 2026-13 --repo-root "$WORK"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 2026/04 --repo-root "$WORK"
  [ "$status" -eq 2 ]
}

@test "-h/--help prints usage and exits 0" {
  run bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"compact.sh"* ]]
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "idempotent: running twice on an already-compacted month is a safe no-op" {
  cat > "$WORK/dev/JOURNAL/2026-08-01-T20260801-000001-a.md" <<'EOF'
# T20260801-000001: A task

## Closed (2026-08-02)
Landed via ccxp-skills#30.
EOF
  commit_dated 2026-08-02 "add august fixture"

  run bash "$SCRIPT" 2026-08 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  commit_dated 2026-08-03 "compact 2026-08 (first run)"

  local digest1
  digest1="$(cat "$WORK/dev/JOURNAL/2026-08-digest.md")"

  run bash "$SCRIPT" 2026-08 --repo-root "$WORK"
  [ "$status" -eq 0 ]

  local digest2 n
  digest2="$(cat "$WORK/dev/JOURNAL/2026-08-digest.md")"
  [ "$digest1" = "$digest2" ]
  # Nothing new left to archive under dev/JOURNAL/ -- still exactly 1 file.
  n="$(find "$WORK/dev/JOURNAL/archive/2026-08" -type f | wc -l)"
  [ "$n" -eq 1 ]
}

@test "relative --repo-root (non-'.') resolves correctly for git add" {
  cat > "$WORK/dev/JOURNAL/2026-09-01-T20260901-000001-a.md" <<'EOF'
# T20260901-000001: A task

## Closed (2026-09-02)
Landed via ccxp-skills#40.
EOF
  commit_dated 2026-09-02 "add september fixture"

  cd "$BATS_TEST_TMPDIR"
  run bash "$SCRIPT" 2026-09 --repo-root repo
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/JOURNAL/2026-09-digest.md" ]
  git -C "$WORK" diff --cached --name-only | grep -q '2026-09-digest.md'
}

@test "pipe characters in title/notes are escaped in the digest table" {
  cat > "$WORK/dev/JOURNAL/2026-10-01-T20261001-000001-a.md" <<'EOF'
# T20261001-000001: Fix A | B toggle bug

## Closed (2026-10-02)
Landed via ccxp-skills#50 — fixed the A | B toggle.
EOF
  commit_dated 2026-10-02 "add pipe-in-title fixture"

  run bash "$SCRIPT" 2026-10 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  grep -qE '^\| T20261001-000001 \| Fix A \\\| B toggle bug \|' "$WORK/dev/JOURNAL/2026-10-digest.md"
  # exactly 4 unescaped column-separator pipes on the row (a corrupted row would have more)
  local row
  row="$(grep '^| T20261001-000001' "$WORK/dev/JOURNAL/2026-10-digest.md")"
  [ "$(grep -o '[^\\]|' <<<"$row" | wc -l)" -eq 4 ]
}

@test "invalid month-shaped filename prefix (2026-13-01-) falls back to commit date" {
  printf '# Bogus month prefix\n' > "$WORK/dev/JOURNAL/2026-13-01-bogus.md"
  commit_dated 2026-04-20 "add bogus-month-prefix file"

  run bash "$SCRIPT" 2026-04 --repo-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$WORK/dev/JOURNAL/archive/2026-04/2026-13-01-bogus.md" ]
  grep -q -- '- 2026-13-01-bogus.md' "$WORK/dev/JOURNAL/2026-04-digest.md"
}

@test "--repo-root pointing at a non-git directory fails loudly, no phantom dirs" {
  local BOGUS="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$BOGUS"

  run bash "$SCRIPT" 2026-04 --repo-root "$BOGUS"
  [ "$status" -ne 0 ]
  [ ! -d "$BOGUS/dev" ]
}

@test "--repo-root with no value -> usage error, exit 2 (not bash's exit 1)" {
  run bash "$SCRIPT" 2026-04 --repo-root
  [ "$status" -eq 2 ]
}

@test "--dry-run does not create dev/JOURNAL/ in a repo that never had one" {
  local NOJ="$BATS_TEST_TMPDIR/no-journal-repo"
  mkdir -p "$NOJ"
  git -C "$NOJ" init -q
  git -C "$NOJ" config user.email t@example.com
  git -C "$NOJ" config user.name tester

  run bash "$SCRIPT" 2026-04 --repo-root "$NOJ" --dry-run
  [ "$status" -eq 0 ]
  [ ! -d "$NOJ/dev" ]
}
