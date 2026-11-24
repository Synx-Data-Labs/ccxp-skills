---
status: Done
estimation: 1
source: Job 1393/1394, 2026-11-23 (release 6.5.0 blocked)
type: bug
related: T20261122-212315
description: claude plugin validate rejects the dynamic $.env.get(name) in hud/register.tsx; blocks the 6.5.0 release gate
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261123-137260: Fix `claude plugin validate` error: $.env.get needs a literal name (hud/register.tsx:380)

## TLDR

- `$.env.get(name)` in a loop made `claude plugin validate .` fail; the validator wants literal names.
- Fix: 17 literal `$.env.get('NAME')` calls in `hud/register.tsx`, one per `ENV_NAMES` entry, behind a small `read` helper that keeps the try/catch and `|| undefined` behaviour.
- Also cleared 31 strict-null type warnings (`hud/model.ts`, `config.ts`, `help.ts`) so validate prints zero warnings, as `dev/guidelines.md` requires.
- A bats test now fails if any `$.env.get` takes a non-literal name or an `ENV_NAMES` entry has no literal call.

## Problem

- **Type**: bug
- `claude plugin validate .` (CLI 2.1.330) fails on main with 1 error at `hud/register.tsx:380`: `vars[name] = (await $.env.get(name)) || undefined` - the validator requires a literal variable name.
- Introduced by commit 088b055 (/hud help and read-only /hud config, T20261122-212315); the 6.4.0 tag uses only literal names.
- `dev/guidelines.md` requires zero validation warnings before the bump PR and before tagging, so the 6.5.0 release is blocked.
- Done: validate reports zero errors/warnings; /hud config output unchanged; HUD tests green, with a regression test if feasible.

## Context

- Introduced in 088b055 (T20261122-212315); the 6.4.0 tag (015be89) used only literal names but already carried 30 type warnings, so the warning cleanup is part of reaching the guideline's zero-warning gate.
- `ENV_NAMES` (`hud/show.ts:9`) stays the single list for the report; the test keeps the literal calls in sync with it.

## Solution

- `hud/register.tsx` configshow branch: `read(() => $.env.get('X'))` per name, typed as `Record<(typeof ENV_NAMES)[number], string | undefined>`.
- Type-only `!` / default-value edits for the warnings (no runtime change except `isNewer` defaulting a missing version part to an empty string, which `VERSION_RE` already rules out).
- Alternatives rejected: a `// @ts-ignore` or validator-skip (hides the rule, waives the gate); dropping the env section from `/hud config` (behaviour change).

## Test plan

- [x] `claude plugin validate .` prints `Validation passed` with no warnings (run on this branch).
- [x] `claude plugin test .`: 242 pass; the 2 failures (queue-source wording, no-ci row count) also fail on main and are unrelated.
- [x] `bats tests/hud_config.bats tests/hud_help.bats` pass, including the new literal-name test.

## Done criteria

- Validate shows zero errors and warnings: `claude plugin validate .` output.
- `/hud config` output unchanged: `hud/hooks.test.tsx` "bare /hud config prints the effective configuration" passes.
- Regression test exists: `tests/hud_config.bats` last test.

## Root cause

- 088b055 added the loop `for (const name of ENV_NAMES) ... $.env.get(name)` at `hud/register.tsx:380`; the validator statically lists env reads and rejects non-literal names.

## Closed (2026-11-23)

- Shipped in the fix PR (see the commit "fix(hud): literal $.env.get names ... (T20261123-137260)"); claim PR #706, staging PR #705.
- Met: all done criteria above. Unrelated pre-existing hud test failures (2) are not fixed here.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, regression test added alongside a mechanical fix
- Verification (`superpowers:verification-before-completion`): yes, validate, plugin test and bats run before the PR
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): see PR review comments
