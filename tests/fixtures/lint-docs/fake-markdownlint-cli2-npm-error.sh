#!/usr/bin/env bash
# tests/fixtures/lint-docs/fake-markdownlint-cli2-npm-error.sh — a fake
# `markdownlint-cli2` that reproduces npm/npx's own exit-1 failure shape
# (T20260930-151922): no `Summary:` line, npm-style error text instead.
#
# Put a fakebin dir containing this file (named `markdownlint-cli2`) earlier
# on $PATH than the real one, so _lint_docs_runner() picks it directly (no
# npx) while still exercising the same rc==1 handling in
# _lint_docs_run_tool() that a real `npx --yes markdownlint-cli2@…` failure
# would hit.
#
# Real-world equivalent, reproduced locally: `npx --yes
# this-package-definitely-does-not-exist-xyz123@99.99.99` exits 1 with `npm
# error 404 ...` on stderr and no `Summary:` line anywhere in its output —
# this fake mimics that shape (exit 1, npm-error-looking text, no
# `Summary:`), not a real lint violation.
set -uo pipefail

cat <<'EOF'
npm error code E404
npm error 404 Not Found - GET https://registry.npmjs.org/markdownlint-cli2 - Not found
npm error 404
npm error 404  'markdownlint-cli2@0.22.1' could not be found
EOF
exit 1
