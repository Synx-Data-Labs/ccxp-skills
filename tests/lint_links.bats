#!/usr/bin/env bats
# lint.sh step 7 (lint_links.py): warn by default, hard with LINT_LINKS_HARD=1.

load test_helper
setup() {
  LINT="$REPO_ROOT/repo-conventions/scripts/lint.sh"
  cd "$BATS_TEST_TMPDIR"
  mkdir -p dev/TODO dev/JOURNAL
  printf '# c\n' > CLAUDE.md
  printf '# g\n## TODO Lifecycle\n' > dev/guidelines.md
  printf '[x](missing.md)\n' > dev/TODO/note.md
}

@test "broken link: lint_links.py exits non-zero" {
  run python3 "$REPO_ROOT/repo-conventions/scripts/lint_links.py" --all .
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing.md"* ]]
}

@test "lint.sh warns but does not count the link by default" {
  run bash "$LINT" .
  [[ "$output" == *"warn-only"* ]]
  [[ "$output" == *"missing.md"* ]]
}

@test "LINT_LINKS_HARD=1 makes lint.sh fail on a broken link" {
  LINT_LINKS_HARD=1 run bash "$LINT" .
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing.md"* ]]
}

@test "allow-list clears the hard gate for the link step" {
  printf 'missing.md\n' > dev/.link-allowlist
  run python3 "$REPO_ROOT/repo-conventions/scripts/lint_links.py" --all .
  [ "$status" -eq 0 ]
}
