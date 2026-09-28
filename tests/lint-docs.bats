#!/usr/bin/env bats
# Tests for _docs/lint-docs.sh's --no-globs scoping fix (T20260910-919422)
# and its safe-fix content-corruption fix (T20260922-383156).
#
# Scope: does lint_docs_run() add --no-globs to the underlying
# markdownlint-cli2 invocation exactly when the caller supplies explicit
# path(s), and does that actually prevent an unrelated file from being
# touched? Does a scoped --fix invocation run in an isolated temp directory
# with MD004/MD037 disabled, so it no longer flips an ambiguous leading "+"
# to "-" or drops comma-spacing around glob-pattern asterisks, while other
# real fixes (MD032) still apply? The pre-existing MD032 vendored-fallback
# behavior is untouched by either fix and isn't re-tested here.
#
# Two styles, same file: a fake markdownlint-cli2 (argv-inspection, fast,
# hermetic, no network) for "was --no-globs/--config passed, from where",
# and the real tool via npx (already used elsewhere in this suite) for
# end-to-end behavioral checks — because argv-inspection alone can't prove
# the flags actually do what they claim; the real-tool tests are what make
# that claim trustworthy.

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
  printf '# target\nSome prose paragraph.\n\n- a real dash bullet\n' > dev/TODO/target.md
  printf '# other\n+ this unrelated file should not be touched\n' > dev/JOURNAL/unrelated.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/target.md

  # target.md's own real dash bullet is untouched (nothing to fix there).
  run grep -c '^- a real dash bullet$' dev/TODO/target.md
  [ "$output" = "1" ]
  # unrelated.md, in a DIFFERENT dir, matched only by the config's **/*.md
  # glob (not by the explicit path arg), must be untouched.
  run grep -c '^+ this unrelated file should not be touched$' dev/JOURNAL/unrelated.md
  [ "$output" = "1" ]
}

@test "safe-fix (T20260922-383156): preserves an ambiguous leading + and glob-comma spacing, still fixes real MD032 gaps" {
  # No fake binary — real end-to-end proof, mirroring the design phase's
  # own repro exactly.
  cat > .markdownlint-cli2.jsonc <<'EOF'
{
  "config": { "default": true, "MD004": { "style": "dash" }, "MD013": false, "MD041": false },
  "globs": [ "**/*.md" ]
}
EOF
  printf '# target\nSome paragraph text that discusses a topic and mentions PDF\n+ PDF) as a parenthetical continuation that happens to start with plus.\n\nAnother paragraph with a comma list: *.lyrics.md, *.service.md should stay spaced.\n' > dev/TODO/target.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/target.md
  [ "$status" -eq 0 ]

  # The ambiguous "+" line is preserved, not flipped to "-".
  run grep -c '^+ PDF) as a parenthetical continuation' dev/TODO/target.md
  [ "$output" = "1" ]
  # The comma-spacing around the glob-pattern asterisks is preserved.
  run grep -c '\*\.lyrics\.md, \*\.service\.md' dev/TODO/target.md
  [ "$output" = "1" ]
  # MD032 (blank line around the list-like "+" line) still gets fixed —
  # disabling MD004/MD037 doesn't disable every other real fix. Checked via
  # plain grep/awk, not bats' $lines (which squeezes a leading blank line
  # out of a -B1 match, making that array unreliable for this check).
  preceding_line="$(grep -B1 '^+ PDF)' dev/TODO/target.md | head -1)"
  [ -z "$preceding_line" ]
}

@test "safe-fix (T20260922-383156): does not rewrite a genuine non-dash bullet list, but check-only still flags it" {
  cat > .markdownlint-cli2.jsonc <<'EOF'
{
  "config": { "default": true, "MD004": { "style": "dash" }, "MD013": false, "MD041": false },
  "globs": [ "**/*.md" ]
}
EOF
  printf '# target\n\n* a real asterisk-bullet list item\n* another item\n' > dev/TODO/target.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/target.md
  [ "$status" -eq 0 ]
  # Accepted trade-off: the scoped safe-fix path does NOT auto-normalize a
  # genuine "*"-bullet list to "-" (it can't tell that apart from the
  # ambiguous ""+"" case without also reintroducing the corruption risk).
  run grep -c '^\* a real asterisk-bullet list item$' dev/TODO/target.md
  [ "$output" = "1" ]

  # But a plain check-only run (no --fix) still reports it — detection is
  # untouched, only the scoped auto-fix is more conservative.
  run lint_docs_run dev/TODO/target.md
  [ "$status" -eq 1 ]
  run grep -c 'MD004' <<<"$output"
  [ "$output" -ge 1 ]
}

@test "safe-fix (T20260922-383156): runs the isolated markdownlint-cli2 invocation from a temp directory with a derived --config" {
  cat > .markdownlint-cli2.jsonc <<'EOF'
{ "config": { "default": true, "MD004": { "style": "dash" } }, "globs": [ "**/*.md" ] }
EOF
  echo "# a task" > dev/TODO/some-task.md
  ORIG_CWD="$PWD"

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  PATH="$FAKEBIN:$PATH" FAKE_MDL_CALLLOG="$CALLLOG" \
    run lint_docs_run --fix dev/TODO/some-task.md
  [ "$status" -eq 0 ]

  run grep '^PWD:' "$CALLLOG"
  [ "$status" -eq 0 ]
  # The invocation ran from somewhere other than the original cwd (the
  # isolated temp directory), not in-place.
  logged_pwd="$(grep '^PWD:' "$CALLLOG" | head -1 | cut -d' ' -f2)"
  [ "$logged_pwd" != "$ORIG_CWD" ]

  run grep -c -- '--config' "$CALLLOG"
  [ "$output" -ge 1 ]
  run grep -c -- '--no-globs' "$CALLLOG"
  [ "$output" -ge 1 ]
}

@test "safe-fix (T20260922-383156): a caller that guards lint_docs_run with || survives under set -e" {
  # Sanity/contract test, not a regression test: an internal bare
  # statement was found during independent review (a bare call to
  # _lint_docs_safe_fix inside _lint_docs_run_tool, not guarded by ||)
  # and fixed for consistency with this file's own established idiom
  # (see the || rc=$? pattern used elsewhere). Verified empirically
  # (both against the fixed code AND the pre-existing T20260910-919422
  # baseline, before this task touched the file) that a *properly
  # guarded* caller — i.e. one that checks lint_docs_run's own
  # documented return value, as any caller of a function whose whole
  # contract is "returns non-zero to signal findings" should — was
  # never actually at risk either way: bash suspends errexit through
  # the entire nested call graph once the top-level call is under a
  # ||/if test, regardless of whether inner calls are separately
  # guarded. This test documents and locks in that guarantee; it isn't
  # expected to distinguish buggy-vs-fixed code (it passes on both).
  cat > .markdownlint-cli2.jsonc <<'EOF'
{ "config": { "default": true, "MD004": { "style": "dash" } }, "globs": [ "**/*.md" ] }
EOF
  printf '# target\nThis line is deliberately made way too long on purpose so that MD013 line length keeps firing as a real remaining violation after the fix pass runs.\n' > dev/TODO/target.md

  marker="$BATS_TEST_TMPDIR/reached-after-call"
  rm -f "$marker"
  bash -c "
    set -euo pipefail
    source '$REPO_ROOT/_docs/lint-docs.sh'
    rc=0
    lint_docs_run --fix dev/TODO/target.md || rc=\$?
    touch '$marker'
  "
  [ -f "$marker" ]
}

@test "safe-fix (T20260922-383156): an unrelated per-file write failure doesn't fall back to re-processing an already-fixed file" {
  # Regression test for a real bug found in independent review: when
  # the underlying tool exits with an unexpected code because ONE file
  # in a multi-file call failed to write (e.g. a permission error) —
  # not because the config/preflight was unavailable — the original
  # implementation still returned 3 (the caller's "fall back to the
  # plain unsafe path" signal). That fallback re-ran the corrupting
  # MD004/MD037 rules over ALL originally-requested files, including
  # ones the safe-fix pass had ALREADY safely fixed in this same
  # invocation — silently re-corrupting them.
  cat > .markdownlint-cli2.jsonc <<'EOF'
{ "config": { "default": true, "MD004": { "style": "dash" } }, "globs": [ "**/*.md" ] }
EOF
  printf '# a\n+ ambiguous continuation for file a\n' > dev/TODO/a.md
  printf '# b\n+ ambiguous continuation for file b\n' > dev/TODO/b.md
  # b.md read-only: cp preserves permissions into the tmpdir copy, so
  # markdownlint-cli2's own attempt to write its fix there fails with
  # EACCES for b.md specifically, while a.md (in the same invocation)
  # still gets fixed successfully.
  chmod 444 dev/TODO/b.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/a.md dev/TODO/b.md
  chmod 644 dev/TODO/b.md

  # a.md's ambiguous "+" must still be preserved — not re-corrupted by a
  # fallback re-run triggered by b.md's unrelated write failure.
  run grep -c '^+ ambiguous continuation for file a$' dev/TODO/a.md
  [ "$output" = "1" ]
}

@test "safe-fix (T20260922-383156): falls back to the plain path when no .markdownlint-cli2.jsonc is discoverable" {
  # No config file at all in cwd — the safe-fix preflight check should
  # signal rc=3 (nothing touched yet) and the caller falls through to
  # the pre-existing plain invocation, still succeeding overall.
  printf '# target\nsome plain content\n' > dev/TODO/target.md

  # shellcheck source=../_docs/lint-docs.sh
  source "$REPO_ROOT/_docs/lint-docs.sh"

  run lint_docs_run --fix dev/TODO/target.md
  [ "$status" -eq 0 ]
}
