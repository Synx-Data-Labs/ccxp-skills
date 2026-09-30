---
status: Design
scheduled: 2026-09-28
estimation: 1h
source: this conversation, 2026-09-30 — surfaced during T20260930-132964's PR #189 CI
related: T20260930-132964
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20260930-151922: `tests/lint-docs.bats`'s real-markdownlint-cli2 test flaked twice on CI

## Problem

- **Type**: bug
- `tests/lint-docs.bats:57` ("explicit-path scoping (real markdownlint-cli2)
  ignores a violation in an unrelated file") failed twice in a row on PR
  #189's CI (`bash _gh/gh.sh run view 36727715274`, `not ok 304`,
  `[ "$status" -eq 0 ]` failed — `lint_docs_run` returned nonzero when it
  should have stayed scoped to the given path), then passed clean on a
  third rerun with an unrelated diff (only `autopilot/SKILL.md` prose
  changed between attempts).
- Ran the same test locally 4x in a row (macOS, same pinned
  `markdownlint-cli2@0.22.1` via the npx path — no local binary on `PATH`)
  with zero failures, and confirmed the PR's actual diff touches nothing
  in `_docs/lint-docs.sh`, `tests/lint-docs.bats`, or any markdownlint
  config — ruling out the PR's own content as the cause.
- Best guess (unverified): the test invokes `npx --yes
  markdownlint-cli2@0.22.1` (`_docs/lint-docs.sh:183`) — only the
  top-level package is version-pinned, not its own transitive
  dependencies, so a fresh `npx` resolution on a GitHub-hosted
  `ubuntu-latest` runner could occasionally pick up a different
  transitive-dependency version than a warm local install, producing a
  scoping-behavior difference for exactly one run.

## Done criteria

- [ ] Root-cause the actual mechanism (not just the best-guess above) —
  compare the resolved dependency tree between a failing and a passing CI
  run if reproducible again, or add temporary diagnostic output.
- [ ] Either pin markdownlint-cli2's transitive deps too (e.g. a
  `package-lock.json`/`npm shrinkwrap` npx can respect), or make the test
  itself retry-tolerant if this turns out to be genuine upstream
  flakiness rather than a real scoping bug.
- [ ] If reproducible, add a regression test capturing whatever the actual
  failure mode was.
