---
status: Done
scheduled: 2026-09-28
estimation: 1
source: this conversation, 2026-09-30 — surfaced during T20260930-132964's PR #189 CI
related: T20260930-132964
claimed_by:
claimed_role:
---

# T20260930-151922: `_docs/lint-docs.sh` misreads a transient npx failure as "violations found"

## TLDR

- **Type**: bug
- **Problem**: `_lint_docs_run_tool` trusts exit code `1` from `npx --yes
  markdownlint-cli2@…` as "real violations found," but npm/npx itself also
  exits `1` on its own errors (e.g. a transient registry fetch failure) —
  the two are indistinguishable by exit code alone, so a cold-runner
  network hiccup gets reported as a lint failure instead of falling back
  to the vendored MD032 check.
- **Solution**: before trusting `rc == 1` as "violations found," require the
  tool's own `Summary: N error(s)` marker line in the captured output;
  absent that marker, treat it as "runner couldn't execute" (return `3`,
  same as today's exit-`2` config-error path) so the caller falls back to
  the vendored, network-free MD032 floor.

## Problem

- `tests/lint-docs.bats:57` ("explicit-path scoping (real markdownlint-cli2)
  ignores a violation in an unrelated file") failed twice in a row on PR
  #189's CI — attempt 1 (`_gh/gh.sh api repos/.../jobs/109928783026/logs`):
  `not ok 304 ... [ "$status" -eq 0 ]' failed` — then passed clean on
  attempt 3 (`_gh/gh.sh run view 36727715274 --json attempt,conclusion` →
  `{"attempt":3,"conclusion":"success"}`) with no code change between
  attempts (only `autopilot/SKILL.md` prose landed on the branch meanwhile).
- Ran the same test locally 4x in a row (macOS, same pinned
  `markdownlint-cli2@0.22.1` via the npx path) with zero failures.
- **Root-cause mechanism verified in isolation** (not the original
  best-guess, and not the same as confirming it's what happened on this
  specific CI attempt — bats's TAP output never dumps `$output`, so
  attempt 1's actual captured text is unrecoverable; this is a verified,
  reproducible defect that *fully explains* the observed pattern, treated
  here as the root cause on that strength, not on direct forensic proof of
  that one run): `npx --yes <bad-or-unfetchable-pkg>` exits `1` on its own
  resolution/network errors, identical to markdownlint-cli2's "violations
  found" exit code — reproduced locally:
  `npx --yes this-package-definitely-does-not-exist-xyz123@99.99.99` →
  `npm error 404 ...` → `exit=1`. `_lint_docs_run_tool`
  (`_docs/lint-docs.sh:176-195`) treats any `rc -eq 1` as authoritative
  "violations found" and returns it straight through — it never
  distinguishes "the tool ran and found issues" from "npm itself failed
  before the tool ever ran."
- Impact is bigger than test flakiness: any real CI/PR use of
  `lint-docs.sh` (not just this test) can misreport a transient npx/network
  blip as a genuine doc violation.

## Context

- **Bug** — repro is the cold-vs-warm npx cache asymmetry:
  - Local dev: `~/.npm/_npx` is warm (this same bats file makes other real
    `npx markdownlint-cli2` calls earlier in the suite, and repeat local
    runs reuse the cache) → no network fetch → nothing to fail.
  - GitHub Actions `ubuntu-latest`: fresh VM per run, no persistent npx
    cache → every invocation does a cold registry fetch → occasional
    transient failure surfaces as a false "violation."
- `.github/workflows/tests.yml:101-110` runs `bats tests/*.bats
  _docs/*.bats` with no node/npx version pin beyond the runner image's
  default — consistent with the asymmetry, though the actual defect is the
  exit-code ambiguity below, not a version-drift issue (attempts 1 and 3
  were minutes apart on the same PR; no registry publish window that
  narrow is a plausible explanation for a real dependency-version change).

## Solution

- Chosen fix: in `_lint_docs_run_tool`, when the runner exits `1`, only
  treat it as "violations found" if the captured output actually contains
  the tool's own report marker (`^Summary: [0-9]+ error`). Verified via
  local repro of both shapes:
  - Real violation: `Summary: 2 error(s)` present, `exit=1`
    (`markdownlint-cli2 --no-globs` against a forced MD004 violation).
  - npm/npx failure: no `Summary:` line, `npm error ...` lines instead,
    `exit=1` (404 repro above).
  - (Already correctly handled today: markdownlint-cli2's own internal
    errors, e.g. a bad `--config` path, exit `2` — not `1` — and already
    fall through to `return 3` / the vendored floor. This fix closes the
    one gap at `rc == 1`, it doesn't touch the `rc == 2` path.)
- Rejected — pin markdownlint-cli2's transitive deps (original task
  best-guess, e.g. via a committed lockfile npx could respect): doesn't
  address the actual defect. `npx` still has to fetch over the network
  each cold run regardless of pinning, so a transient fetch failure can
  still occur; and the exit-code collision would still misreport it as a
  violation even with pinned deps. Also cuts against the script's own
  "runner-preferring, no local install" design intent
  (`_docs/lint-docs.sh:18-22`).
- Rejected — make the test itself retry-tolerant: treats the symptom only
  in the test suite. The same ambiguity would still live in
  `_lint_docs_run_tool` for every non-test caller (any repo's real
  `/gcpr`/CI doc-lint gate), so a transient npx failure could still block
  or misreport a genuinely clean PR outside this one test.

## Test plan

- [x] Reproduce npm/npx's own exit-1, no-`Summary:` shape locally (404 on
  a nonexistent package) — done above.
- [x] Reproduce markdownlint-cli2's real exit-1, `Summary:` shape locally
  (forced MD004 violation) — done above.
- [x] New BATS regression test in `tests/lint-docs.bats:86-107` ("falls
  back to vendored when the runner exits 1 with an npm-error shape, not a
  real Summary"): a fake `markdownlint-cli2` binary
  (`tests/fixtures/lint-docs/fake-markdownlint-cli2-npm-error.sh`, same
  pattern as the existing `fake-markdownlint-cli2.sh` fixture) exits `1`
  with npm-error-shaped output and no `Summary:` line — asserts
  `lint_docs_run` falls back to the vendored check instead of trusting the
  fake's exit code.
- [x] `bats tests/lint-docs.bats` passes locally after the fix — all 4
  cases (3 existing + the new one).
- [ ] CI green on the implementation PR (this exact class of flake can't
  be forced on demand, so a clean single CI run is the practical bar —
  the local repro above is what proves the mechanism, not the CI run).

## Done criteria

- [x] Root-cause the actual mechanism — see `## Problem` / `## Root
  cause`: verified via local repro, not the original best-guess.
- [x] Fix: `_lint_docs_run_tool` (`_docs/lint-docs.sh:176-203`) requires a
  `Summary:` marker before trusting `rc == 1` as violations-found.
- [x] Regression test added per `## Test plan` above, capturing the actual
  failure mode (npm-error-shaped exit 1, not a real lint violation).

## Root cause

- Mechanism: `_lint_docs_run_tool` (`_docs/lint-docs.sh:176-195`) —

  ```bash
  out="$("${cmd[@]}" "$@" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    return "$rc"
  fi
  return 3
  ```

  `rc -eq 1` is returned as authoritative "violations found" with no check
  that the output actually came from a completed markdownlint-cli2 run.
  `npm`/`npx` itself exits `1` on its own errors (confirmed: a
  nonexistent-package `npx --yes` call exits `1` with `npm error 404 ...`
  and no `Summary:` line) — the two `rc == 1` cases are indistinguishable
  by exit code alone.
- Introduced-in: `5051a9e` ("Initial public release") — this repo was
  split from a private company repo (see `CLAUDE.md`'s own note), and that
  squash commit is the earliest history available here; the exit-0/1-
  authoritative design predates the public split, so whether the gap was a
  deliberate simplification or an oversight can't be determined from this
  repo's own git history. `4328b36` (the later `--fix`-removal commit)
  touched `_lint_docs_run_tool`'s call signature but not its exit-code
  handling — the gap is original, not a regression from that change.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_docs/lint-docs.sh` | 176–195 | `_lint_docs_run_tool` — the exit-code handling to fix |
| `_docs/lint-docs.sh` | 198–229 | `lint_docs_run` — caller that falls back to vendored on `rc > 1` |
| `tests/lint-docs.bats` | 24–36 | `setup()` — the fake-binary fixture pattern to reuse for the new regression test |
| `tests/lint-docs.bats` | 57–84 | the flaking test itself (real npx path, no fake binary) |
| `tests/fixtures/lint-docs/fake-markdownlint-cli2.sh` | — | existing fake-binary fixture; the new regression test's fake can follow this shape |
| `.github/workflows/tests.yml` | 101–110 | CI job that runs the bats suite (cold runner, no npx cache) |

## Closed (2026-09-30)

Shipped in **PR #193** (design in #192).

- Met: root-caused the mechanism (npm/npx exit-1 colliding with
  markdownlint-cli2's own exit-1), fixed `_lint_docs_run_tool`
  (`_docs/lint-docs.sh:176-203`) to require the `Summary:` marker before
  trusting `rc == 1`, added a regression test
  (`tests/lint-docs.bats:86-107` + the new
  `fake-markdownlint-cli2-npm-error.sh` fixture) that fails without the
  fix and passes with it (verified red-green locally), full local bats
  suite green (796/796).
- External/unverified: the fix is confirmed correct by local repro and
  the red-green regression test, not by reproducing the exact original
  CI flake on demand (that class of failure isn't forceable — see
  `## Problem`'s honesty note re: bats never capturing attempt 1's
  `$output`). Confirmed by: this PR's own CI running clean, and no
  recurrence of this specific `not ok 304`-style failure going forward.
- No follow-up tasks filed — the fix is self-contained to
  `_docs/lint-docs.sh` and its test.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the failing
  regression test first (confirmed `not ok`/expected failure reason),
  implemented the minimal fix, confirmed green, then did an explicit
  revert/re-apply red-green cycle to prove the test actually catches the
  bug.
- Verification (`superpowers:verification-before-completion`): yes — full
  bats suite (796/796) run fresh, plus the revert/restore red-green cycle,
  before committing.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; root cause was found via direct local reproduction (forcing
  both the npm-404 and the real-markdownlint-violation shapes) rather than
  trial-and-error.
- Receiving code review (`superpowers:receiving-code-review`): yes — the
  design PR's independent review (PR #192) found two real issues (wrong
  line-range citations, an overclaim on "verified root cause"); both
  fixed, not pushed back on.
