#!/usr/bin/env bats
# Tests for _docs/doc-impact.sh — stale-docs detection from a git diff.
#
# Each test builds a throwaway git repo in $BATS_TEST_TMPDIR, commits an
# initial state (the "base"), then creates the change and runs the script
# against the base commit SHA so we don't rely on any remote ref.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/_docs/doc-impact.sh"
  # Each test gets its own isolated repo under $BATS_TEST_TMPDIR.
  TESTREPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TESTREPO"
  cd "$TESTREPO"
  git init -q
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
}

# ---------------------------------------------------------------------------
# Helper: commit all staged/unstaged changes.
# ---------------------------------------------------------------------------
_commit() { git add -A && git commit -qm "$1"; }

# ---------------------------------------------------------------------------
# 1. Reference match flags
#    README.md mentions "foo.sh"; a commit changes foo.sh → script exits 1
#    and names README.md in its output.
# ---------------------------------------------------------------------------
@test "1: reference match — README mentioning foo.sh is flagged when foo.sh changes" {
  # Base state: README mentions foo.sh, plus foo.sh itself.
  printf 'See foo.sh for details.\n' > README.md
  printf '#!/bin/bash\necho hello\n' > foo.sh
  _commit "base"
  base="$(git rev-parse HEAD)"

  # Change: modify foo.sh only.
  printf '#!/bin/bash\necho world\n' > foo.sh
  _commit "change foo.sh"

  run bash "$SCRIPT" "$base"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md"* ]]
}

# ---------------------------------------------------------------------------
# 2. No false positive
#    Change a code file that no doc mentions → exit 0.
# ---------------------------------------------------------------------------
@test "2: no false positive — unmentioned code file change exits 0" {
  printf '# My project\n' > README.md
  printf '#!/bin/bash\necho hello\n' > unrelated.sh
  _commit "base"
  base="$(git rev-parse HEAD)"

  printf '#!/bin/bash\necho changed\n' > unrelated.sh
  _commit "change unrelated.sh"

  run bash "$SCRIPT" "$base"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no docs look stale"* ]]
}

# ---------------------------------------------------------------------------
# 3. Docs-only change → exit 0
# ---------------------------------------------------------------------------
@test "3: docs-only change exits 0" {
  printf '# Project\n' > README.md
  printf '#!/bin/bash\necho hello\n' > tool.sh
  _commit "base"
  base="$(git rev-parse HEAD)"

  printf '# Project (updated)\n' > README.md
  _commit "update README only"

  run bash "$SCRIPT" "$base"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs-only"* ]]
}

# ---------------------------------------------------------------------------
# 4. New workflow → README flagged
#    Add .github/workflows/new.yml; README.md present and untouched → exit 1.
# ---------------------------------------------------------------------------
@test "4: new workflow — README flagged for new .github/workflows/new.yml" {
  printf '# Project\n' > README.md
  _commit "base"
  base="$(git rev-parse HEAD)"

  mkdir -p .github/workflows
  printf 'name: new\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: []\n' > .github/workflows/new.yml
  _commit "add new workflow"

  run bash "$SCRIPT" "$base"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md"* ]]
}

# ---------------------------------------------------------------------------
# 5. Touched doc excluded
#    Change foo.sh AND update README.md (which mentions foo.sh) in same range
#    → README must NOT be flagged; exit 0.
# ---------------------------------------------------------------------------
@test "5: touched doc excluded — README updated alongside foo.sh exits 0" {
  printf 'See foo.sh for details.\n' > README.md
  printf '#!/bin/bash\necho hello\n' > foo.sh
  _commit "base"
  base="$(git rev-parse HEAD)"

  printf '#!/bin/bash\necho world\n' > foo.sh
  printf 'See foo.sh for details. (updated)\n' > README.md
  _commit "change foo.sh and update README"

  run bash "$SCRIPT" "$base"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. No changes — base == HEAD → exit 0
# ---------------------------------------------------------------------------
@test "6: no changes — base equals HEAD exits 0" {
  printf '# Project\n' > README.md
  printf '#!/bin/bash\necho hello\n' > tool.sh
  _commit "base"
  base="$(git rev-parse HEAD)"

  # No new commits; compare HEAD against itself.
  run bash "$SCRIPT" "$base"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes"* ]]
}
