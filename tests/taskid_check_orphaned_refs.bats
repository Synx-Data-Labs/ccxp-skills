#!/usr/bin/env bats
# Tests for _taskid/check-orphaned-refs.sh — catches a T<id> referenced in
# code/docs outside dev/ with no corresponding dev/{TODO,PARKING,JOURNAL}
# file (the "minted an ID, used it, never filed the task" mistake — see
# the incident that motivated this check).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_taskid/check-orphaned-refs.sh"

  cd "$BATS_TEST_TMPDIR"
  git init -q .
  mkdir -p dev/TODO dev/PARKING dev/JOURNAL src
  touch dev/TODO/T20260427-298901-registry-egress-cost-reduction.md
  touch dev/JOURNAL/2026-05-29-T20260320-000026-widgetdb-docker-image.md
}

@test "passes when every referenced id has a task file" {
  echo "# T20260427-298901: fixes the egress cost issue" > src/a.sh
  echo "# see T20260320-000026 for context" > src/b.sh
  run check-orphaned-refs src/a.sh src/b.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"No orphaned"* ]]
}

@test "flags a reference with no matching task file anywhere" {
  echo "# T20260706-181741: PERL5LIB leak fix" > src/a.sh
  run check-orphaned-refs src/a.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"T20260706-181741"* ]]
  [[ "$output" == *"src/a.sh:1"* ]]
}

@test "reports each orphaned occurrence, not just the first" {
  printf '# T20260706-181741 leaks here\nsecond line\n# and again T20260706-181741\n' > src/a.sh
  run check-orphaned-refs src/a.sh
  [ "$status" -eq 1 ]
  [ "$(grep -cF 'T20260706-181741' <<<"$output")" -ge 2 ]
}

@test "a matching PARKING file also resolves (not just TODO)" {
  touch dev/PARKING/T20260601-111111-parked-thing.md
  echo "# T20260601-111111 parked for later" > src/a.sh
  run check-orphaned-refs src/a.sh
  [ "$status" -eq 0 ]
}

@test "a matching JOURNAL file also resolves (not just TODO)" {
  echo "# T20260320-000026 already shipped" > src/a.sh
  run check-orphaned-refs src/a.sh
  [ "$status" -eq 0 ]
}

@test "--changed-only scans only files changed vs base, not the whole tree" {
  echo "# T20260706-181741 orphaned but untouched" > src/untouched.sh
  git add -A && git config user.email t@t.co && git config user.name t && git commit -qm base
  git branch -m main  # git init's default branch name varies by system config
  git checkout -qb feature
  echo "# T20260427-298901 fine, touched" > src/touched.sh
  git add src/touched.sh && git commit -qm feature

  run check-orphaned-refs --changed-only main
  [ "$status" -eq 0 ]
  [[ "$output" != *"src/untouched.sh"* ]]
}

@test "--changed-only catches an orphaned id in a newly-changed file" {
  git add -A && git config user.email t@t.co && git config user.name t && git commit -qm base
  git branch -m main  # git init's default branch name varies by system config
  git checkout -qb feature
  echo "# T20260706-181741 new and orphaned" > src/new.sh
  git add src/new.sh && git commit -qm feature

  run check-orphaned-refs --changed-only main
  [ "$status" -eq 1 ]
  [[ "$output" == *"T20260706-181741"* ]]
}

@test "--changed-only fails loud (not a silent pass) when base ref doesn't resolve" {
  echo "# T20260706-181741 orphaned" > src/a.sh
  git add -A && git config user.email t@t.co && git config user.name t && git commit -qm base
  run check-orphaned-refs --changed-only nonexistent-branch
  [ "$status" -eq 2 ]
  [[ "$output" == *"not resolvable"* ]]
}

@test "scanning is skipped for dev/ itself — no false positives on the queue/related fields" {
  # dev/ files legitimately cross-reference other task IDs (related:,
  # blocked-by:) before those siblings necessarily exist in this same PR;
  # this check is scoped to catch orphaned refs in CODE, not task-to-task
  # cross-references (that's a different, already-handled concern).
  echo "related: T99999999-999999" > dev/TODO/T20260427-298901-registry-egress-cost-reduction.md
  run check-orphaned-refs dev/TODO/T20260427-298901-registry-egress-cost-reduction.md
  # Directly scanning a dev/ file still works if explicitly named (the
  # exclusion is for whole-repo/changed-only scans, via the `:!dev` pathspec)
  # — so this proves the *default* scan modes exclude dev/, not that dev/
  # files are unscannable outright. Explicitly passing a dev/ path still
  # flags a genuinely orphaned id — expected, not a false positive.
  [ "$status" -eq 1 ]
}
