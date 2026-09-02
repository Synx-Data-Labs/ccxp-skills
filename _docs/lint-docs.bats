#!/usr/bin/env bats
#
# Unit tests for lint-docs.sh (T20260626-117003; moved here from
# build-pipeline-repo's scripts/ and generalized by T20260719-111051).
#
# Strategy: source the real implementation and exercise the vendored MD032
# core + runner resolution + CLI error paths over fixtures in
# $BATS_TEST_TMPDIR. The vendored check is pure awk — no mocking needed; the
# real-runner (markdownlint-cli2 / npx) path is network-dependent and is NOT
# exercised here (a consuming repo's own CI Markdown Lint workflow covers it).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
SCRIPT="$SCRIPT_DIR/lint-docs.sh"

setup() {
  source "$SCRIPT"
  DOC="$BATS_TEST_TMPDIR/doc.md"
}

# --- vendored MD032: before-case (the recurring "colon-then-bullets" class) ---

@test "MD032 before-case: list glued to a preceding text line fails" {
  printf 'Intro line:\n- one\n- two\n' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MD032 list-item not preceded by a blank line"* ]]
}

@test "MD032 before-case: blank-separated list passes" {
  printf 'Intro line:\n\n- one\n- two\n' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "MD032 ordered list glued to text fails" {
  printf 'Steps:\n1. first\n2. second\n' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MD032"* ]]
}

# --- vendored MD032: after-case ---

@test "MD032 after-case: list glued to a following text line fails" {
  printf '%s\n' '- one' '- two' 'Trailing paragraph' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MD032 list not followed by a blank line"* ]]
}

@test "MD032 after-case: blank-separated trailing paragraph passes" {
  printf '%s\n' '- one' '- two' '' 'Trailing paragraph' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
}

# --- fence safety ---

@test "bullets inside a fenced code block are not flagged" {
  printf 'Before:\n\n```\n- not a list\n- still code\n```\n\nAfter text\n' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
}

# --- nested / continuation lines stay part of the list ---

@test "indented sub-list after a continuation line does not false-positive" {
  printf '%s\n' \
    '- parent item' \
    '  continuation text under the item' \
    '  - nested child' \
    '' \
    'Next paragraph' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
}

@test "well-formed list surrounded by blanks and headings passes" {
  printf '%s\n' \
    '## Heading' \
    '' \
    'A paragraph.' \
    '' \
    '- a' \
    '- b' \
    '' \
    'Another paragraph.' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
}

# --- YAML frontmatter is skipped (not treated as markdown) ---

@test "YAML frontmatter is not linted as markdown" {
  printf '%s\n' \
    '---' \
    'status: Open' \
    'estimation: 2h' \
    '---' \
    '' \
    '# Title' \
    '' \
    'Body:' \
    '' \
    '- item' > "$DOC"
  run _lint_docs_md032 "$DOC"
  [ "$status" -eq 0 ]
}

# --- error paths ---

@test "missing file returns exit 2" {
  run _lint_docs_md032 "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file not found"* ]]
}

# --- runner resolution ---

@test "runner resolution returns empty when no markdownlint-cli2 / npx on PATH" {
  # Empty PATH inside the subshell: command -v is a builtin, so resolution runs
  # with no binaries findable and both runners come back absent.
  run bash -c "PATH=''; source '$SCRIPT'; _lint_docs_runner"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "runner resolution honors LINT_DOCS_FORCE_VENDORED=1" {
  LINT_DOCS_FORCE_VENDORED=1 run _lint_docs_runner
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- CLI: vendored fallback end-to-end + exit codes ---
# Force the deterministic vendored floor (the box has npx, so the real-runner
# path is network-dependent and not the unit under test here).

@test "lint_docs_run on a clean dir exits 0 (vendored fallback)" {
  local d="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$d"
  printf 'Intro:\n\n- a\n- b\n' > "$d/ok.md"
  LINT_DOCS_FORCE_VENDORED=1 run lint_docs_run "$d"
  [ "$status" -eq 0 ]
}

@test "lint_docs_run on a broken doc exits 1 (vendored fallback)" {
  local d="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$d"
  printf 'Intro:\n- a\n- b\n' > "$d/bad.md"
  LINT_DOCS_FORCE_VENDORED=1 run lint_docs_run "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MD032"* ]]
}

@test "lint_docs_run rejects an unknown option with exit 2" {
  run lint_docs_run --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}
