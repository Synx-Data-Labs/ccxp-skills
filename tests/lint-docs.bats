#!/usr/bin/env bats
# Tests for _docs/lint-docs.sh's --no-globs scoping fix (T20260910-919422).
#
# Scope: does lint_docs_run() add --no-globs to the underlying
# markdownlint-cli2 invocation exactly when the caller supplies explicit
# path(s), and does that actually prevent an unrelated file from being
# touched? The pre-existing MD032 vendored-fallback behavior is untouched by
# this fix and isn't re-tested here.
#
# Two styles, same file: a fake markdownlint-cli2 (argv-inspection, fast,
# hermetic, no network) for "was --no-globs passed", and the real tool via
# npx (already used elsewhere in this suite) for one end-to-end behavioral
# check — because argv-inspection alone can't prove the flag actually does
# what it claims; the real-tool test is what makes that claim trustworthy.

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

@test "lint_docs_run adds --no-globs when an explicit path is given" {
  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  echo "# a task" > dev/TODO/some-task.md

  PATH="$FAKEBIN:$PATH" FAKE_MDL_CALLLOG="$CALLLOG" \
    run lint_docs_run --fix dev/TODO/some-task.md

  [ "$status" -eq 0 ]
  run grep -c -- '--no-globs' "$CALLLOG"
  [ "$output" = "1" ]
  run grep -- 'dev/TODO/some-task.md' "$CALLLOG"
  [ "$status" -eq 0 ]
}

@test "lint_docs_run does not add --no-globs for the bare default-scope call" {
  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  PATH="$FAKEBIN:$PATH" FAKE_MDL_CALLLOG="$CALLLOG" \
    run lint_docs_run --fix

  [ "$status" -eq 0 ]
  run grep -c -- '--no-globs' "$CALLLOG"
  [ "$output" = "0" ]
  run grep -- 'dev/JOURNAL' "$CALLLOG"
  [ "$status" -eq 0 ]
}

@test "scoped --fix (real markdownlint-cli2) leaves an unrelated fixable file untouched" {
  # No fake binary here — this is the real end-to-end proof the flag works,
  # using the real repo config shape, mirroring the manual repro from the
  # design phase.
  cat > .markdownlint-cli2.jsonc <<'EOF'
{
  "config": { "default": true, "MD004": { "style": "dash" }, "MD013": false, "MD041": false },
  "globs": [ "**/*.md" ]
}
EOF
  printf '# target\n+ this is a bad plus continuation\n' > dev/TODO/target.md
  printf '# other\n+ this unrelated file should not be touched\n' > dev/JOURNAL/unrelated.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/target.md

  # target.md's own bad + IS fixed (MD004 dash-style, same as before this
  # change — scoping doesn't touch this bug, only the blast radius).
  run grep -c '^- this is a bad plus continuation$' dev/TODO/target.md
  [ "$output" = "1" ]
  # unrelated.md, in a DIFFERENT dir, matched only by the config's **/*.md
  # glob (not by the explicit path arg), must be untouched.
  run grep -c '^+ this unrelated file should not be touched$' dev/JOURNAL/unrelated.md
  [ "$output" = "1" ]
}
