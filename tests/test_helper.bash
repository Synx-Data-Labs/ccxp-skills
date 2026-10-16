#!/usr/bin/env bash
# tests/test_helper.bash — shared BATS setup, `load`ed by test files across
# tests/, _docs/, and _slack/ (T20261016-316464).
#
# Before this file existed, the suite had zero shared helper: every file
# recomputed its own REPO_ROOT, many hand-rolled the same throwaway
# git-fixture-repo bootstrap, a few shadowed `gh`/`git` with a fixture binary
# via an identical PATH-shim ceremony, and a few isolated CLAIMANT_STATE_DIR
# the same way. This file centralizes those shapes so a future change to any
# of them touches one file instead of N. Pure DRY extraction — no assertion
# or behavior change for any caller.
#
# Not every file with a superficially similar pattern was converted to use
# these helpers — see the task file (dev/JOURNAL or dev/TODO,
# T20261016-316464) for the two deliberate exclusions and why forcing them
# through a shared helper would have been a correctness risk, not a cleanup.

# REPO_ROOT — every test file needs the repo root. $BATS_TEST_DIRNAME is set
# by bats before `load` runs the body of this file, and every .bats file in
# this repo lives exactly one directory below the repo root (tests/, _docs/,
# _slack/), so this resolves correctly regardless of which of those a given
# test file lives in.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO_ROOT

# git_identity <dir> [email] [name]
# Sets a deterministic git identity on an already-`git init`'d repo at <dir>,
# and disables commit signing so a host's global `commit.gpgsign=true`
# can never make a test's commit hang or fail. Replaces the
# `git config user.email` + `git config user.name` (+, where present,
# `git config commit.gpgsign false`) pair/triple duplicated across the
# suite's git-fixture setups. Deliberately does NOT run `git init` itself —
# callers vary on init flags (bare vs normal, `-b <branch>`, trailing `.`)
# and keep that line inline.
git_identity() {
  local dir="$1" email="${2:-t@example.com}" name="${3:-tester}"
  git -C "$dir" config user.email "$email"
  git -C "$dir" config user.name "$name"
  git -C "$dir" config commit.gpgsign false
}

# use_fake_bin <fixture-script> <binary-name>
# Copies <fixture-script> onto a fresh, PATH-prepended directory as
# <binary-name>, so it shadows the real binary for the rest of the test.
# Safe to call more than once per test (each call reuses the same
# $BATS_TEST_TMPDIR/fakebin directory and just adds another binary to it) —
# exactly what git.bats needs for both a fake `gh` and a fake `git`.
use_fake_bin() {
  local fixture="$1" name="$2"
  FAKEBIN="${FAKEBIN:-$BATS_TEST_TMPDIR/fakebin}"
  mkdir -p "$FAKEBIN"
  cp "$fixture" "$FAKEBIN/$name"
  chmod +x "$FAKEBIN/$name"
  export FAKEBIN
  case ":$PATH:" in
    *":$FAKEBIN:"*) ;;  # already on PATH from an earlier call this test
    *) export PATH="$FAKEBIN:$PATH" ;;
  esac
}

# isolate_claimant_state [subdir]
# Points CLAIMANT_STATE_DIR at a throwaway directory under
# $BATS_TEST_TMPDIR so claim-identity tests never read the developer's real
# state or write outside the sandbox. [subdir] defaults to "claimant-state";
# pass a different name only when a test also needs a second, distinct
# state dir in the same file.
isolate_claimant_state() {
  export CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/${1:-claimant-state}"
}
