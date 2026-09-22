#!/usr/bin/env bash
# tests/fixtures/lint-docs/fake-markdownlint-cli2.sh — a fake `markdownlint-cli2`
# for tests/lint-docs.bats' argv-inspection tests (T20260910-919422).
#
# Put a fakebin dir containing this file (named `markdownlint-cli2`) earlier on
# $PATH than the real one, so _lint_docs_runner() picks it directly (no npx).
#
# Contract:
#
#   FAKE_MDL_CALLLOG   file this call's argv (space-joined, "$*") is appended
#                       to, one line, prefixed "ARGV: " — lets a test assert
#                       exactly what flags/paths were passed, without needing
#                       the real npm package or a network call.
#
# Always reports a clean pass (no violations, exit 0) — these tests only care
# about what argv the wrapper constructs, not markdownlint's own rule engine
# (that's covered by the real-tool end-to-end test in the same bats file).
set -uo pipefail

if [ -n "${FAKE_MDL_CALLLOG:-}" ]; then
  printf 'ARGV: %s\n' "$*" >> "$FAKE_MDL_CALLLOG"
fi

printf 'markdownlint-cli2 v0.22.1 (fake)\nSummary: 0 error(s)\n'
exit 0
