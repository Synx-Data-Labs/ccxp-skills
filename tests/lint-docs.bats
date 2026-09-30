#!/usr/bin/env bats
# Tests for _docs/lint-docs.sh's mandatory-explicit-path scoping (T20260910-919422,
# T20260928-608242).
#
# `--fix` (and its isolated safe-fix override, T20260922-383156) was removed
# entirely by T20260928-608242 — a caller-side bug that yields an empty path
# list used to silently fall back to an unscoped, non-isolated `--fix` over
# the whole repo, the third distinct incident in that code path. The script
# is check-only now and a path argument is mandatory (covered by
# `_docs/lint-docs.bats`'s zero-args-errors case).
#
# What's still worth its own coverage here: does `lint_docs_run` add
# `--no-globs` for every call (paths are always explicit now), and does that
# actually prevent an unrelated file elsewhere in the repo from being pulled
# in via the config's own `globs` — i.e. does check-only mode stay scoped to
# exactly the given path(s), the same guarantee T20260910-919422 established
# for the (now-removed) `--fix` case.
#
# Two styles, same file: a fake markdownlint-cli2 (argv-inspection, fast,
# hermetic, no network) for "was --no-globs passed, from where", and the real
# tool via npx (already used elsewhere in this suite) for an end-to-end proof
# that scoping actually works, not just that the flag was passed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO/dev/JOURNAL" "$CWD_REPO/dev/TODO"
  cd "$CWD_REPO"

  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cp "$REPO_ROOT/tests/fixtures/lint-docs/fake-markdownlint-cli2.sh" "$FAKEBIN/markdownlint-cli2"
  chmod +x "$FAKEBIN/markdownlint-cli2"

  CALLLOG="$BATS_TEST_TMPDIR/calllog"
}

@test "lint_docs_run adds --no-globs for an explicit path" {
  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  echo "# a task" > dev/TODO/some-task.md

  PATH="$FAKEBIN:$PATH" FAKE_MDL_CALLLOG="$CALLLOG" \
    run lint_docs_run dev/TODO/some-task.md

  [ "$status" -eq 0 ]
  run grep -c -- '--no-globs' "$CALLLOG"
  [ "$output" = "1" ]
  run grep -- 'dev/TODO/some-task.md' "$CALLLOG"
  [ "$status" -eq 0 ]
  # --fix was removed entirely — never passed, even implicitly.
  run grep -c -- '--fix' "$CALLLOG"
  [ "$output" = "0" ]
}

@test "explicit-path scoping (real markdownlint-cli2) ignores a violation in an unrelated file" {
  # No fake binary here — this is the real end-to-end proof the flag works,
  # using the real repo config shape, mirroring the manual repro from the
  # design phase.
  cat > .markdownlint-cli2.jsonc <<'EOF'
{
  "config": { "default": true, "MD004": { "style": "dash" }, "MD013": false, "MD041": false },
  "globs": [ "**/*.md" ]
}
EOF
  printf '# target\n\nSome prose paragraph.\n\n- a real dash bullet\n' > dev/TODO/target.md
  printf '# other\n\n* this unrelated file has a real MD004 violation\n' > dev/JOURNAL/unrelated.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  # Check-only: target.md is clean, so the call should exit 0 — if
  # unrelated.md's asterisk-bullet MD004 violation leaked in via the
  # config's own **/*.md glob, this would exit 1 instead.
  run lint_docs_run dev/TODO/target.md
  [ "$status" -eq 0 ]

  # Both files are untouched either way (no --fix exists anymore).
  run grep -c '^- a real dash bullet$' dev/TODO/target.md
  [ "$output" = "1" ]
  run grep -c '^\* this unrelated file has a real MD004 violation$' dev/JOURNAL/unrelated.md
  [ "$output" = "1" ]
}

@test "lint_docs_run still detects a real violation in the given explicit path" {
  # Force the vendored floor — deterministic, no network/config dependency;
  # the real-runner path is exercised by the test above.
  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  printf 'Intro line:\n- one\n- two\n' > dev/TODO/target.md

  LINT_DOCS_FORCE_VENDORED=1 run lint_docs_run dev/TODO/target.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"MD032"* ]]
}
