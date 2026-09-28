---
status: Done
scheduled: 2026-09-21
estimation: 30m
source: independent code-review agent on PR #115 (T20260922-453135), 2026-09-22
related: T20260922-453135
claimed_by:
claimed_role:
---

# T20260922-270158: `eta.sh` rejects the canonical `2w` estimation bucket and doesn't validate `T<id>` before globbing

Design approved in-conversation 2026-09-22 — self-evident bug fix, design
PR skipped per `/drive` Phase 2's skip condition.

## TLDR

- **Type**: bug
- **Problem**: `eta/scripts/eta.sh` (shipped in PR #115) is missing the `2w`
  bucket that `lifecycle.md`'s canonical `estimation:` enum documents, and
  splices an unvalidated `T<id>` CLI argument straight into a filesystem
  glob.
- **Solution**: add the `2w` case to `eta_bucket_seconds`; validate
  `eta_task_id` against the canonical `T<8digits>-<6digits>` shape before
  it ever reaches `eta_find_file`'s glob.

## Problem

- Post-merge independent review of PR #115 (`eta/scripts/eta.sh`) found two
  real, reachable bugs:
  1. `eta_bucket_seconds()` (`eta/scripts/eta.sh:112-124`) handles
     `15m 30m 1h 2h 4h 1d 2d 1w` but not `2w` — and `lifecycle.md:37`'s
     canonical `estimation: {30m|1h|2h|4h|1d|2d|1w|2w}` enum lists `2w` as a
     first-class bucket. Any task filed with `estimation: 2w` makes `/eta`
     fail every time with "unrecognized estimation bucket".
  2. `eta_task_id` (any arg matching bare `T*`, `eta/scripts/eta.sh:39-40`)
     has no format check before `eta_find_file()` splices it directly into
     a glob (`"$eta_todo_dir/$id"*.md`, line 53). A crafted id like
     `T../../PARKING/T<real-id>` escapes the intended `dev/TODO/` scope via
     pathname expansion — the same bug class already found and fixed once
     in this repo (`migrate-task/scripts/migrate.sh`, per the review).

## Context

- `lifecycle.md:139` gives the canonical task-id shape:
  `^T[0-9]{8}-[0-9]{6}$`.
- `eta/scripts/eta.sh` and `tests/eta.bats` landed in PR #115 (this repo,
  2026-09-22) implementing T20260922-453135.

## Solution

- Add `2w) printf '1209600' ;;` to `eta_bucket_seconds()`
  (`eta/scripts/eta.sh`); update the error message and `eta/SKILL.md`'s
  bucket list to include `2w`.
- Validate `eta_task_id` against `^T[0-9]{8}-[0-9]{6}$` immediately after
  argument parsing, before any glob — reject with a clear error (exit 2)
  otherwise.
- **Alternative rejected**: relying on `dev/TODO/` containing only
  legitimately-named files as an implicit guard — rejected because the
  glob still walks outside `dev/TODO/` given `../` in the input regardless
  of what's actually in that directory; the fix has to be input validation,
  not directory hygiene.

## Test plan

- [x] BATS: `estimation: 2w` resolves to 1209600s (assert on `remaining:`
  text for a pinned commit date, per review finding #5's follow-on)
- [x] BATS: a malformed `T<id>` (e.g. containing `/` or `..`) is rejected
  with a clear error before any glob runs
- [x] `bats tests/eta.bats` green locally and in CI

## Done criteria

- [x] `2w` bucket resolves correctly — `tests/eta.bats`
- [x] malformed `T<id>` rejected — `tests/eta.bats`
- [x] `bats tests/eta.bats` green in CI (PR checks)

## Root cause

- Introduced in PR #115 (2026-09-22, `eta/scripts/eta.sh:112-124` and
  `:39-53`) — an oversight in the initial bucket enum (copied from the
  design doc's 8-bucket list, which itself omitted `2w` despite
  `lifecycle.md` documenting it) and a missing input-validation step on the
  optional `T<id>` argument. Not deliberate.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `eta/scripts/eta.sh` | `39-53`, `112-124` | The two bugs |
| `eta/SKILL.md` | bucket list | Needs the `2w` addition too |
| `tests/eta.bats` | new cases | Regression coverage |
| `lifecycle.md` | `37`, `139` | Canonical bucket enum + task-id shape this fix conforms to |

## Closed (2026-09-22)

- Shipped in **PR #117** (claim in **PR #116**), fixing what PR #115
  (T20260922-453135) shipped.
- Added `2w) printf '1209600' ;;` to `eta_bucket_seconds`
  (`eta/scripts/eta.sh`); updated the error message and `eta/SKILL.md`'s
  bucket list.
- Added a `^T[0-9]{8}-[0-9]{6}$` regex check on the `T<id>` CLI argument
  immediately after parsing, before it reaches `eta_find_file`'s glob;
  rejects with exit 2 and a clear message otherwise.
- Also picked up the review's should-fix #3 (`--tz` validation accepting
  zoneinfo *directories* via `-e` — changed to `-f`/`-L`) and hardened the
  `--tz` override test (previously indistinguishable from "override
  ignored" in a UTC-default sandbox) while in the file — both flagged by
  the same review pass, cheap to fix alongside the two must-fixes.
- 2 new BATS regression cases + 1 hardened case; `bats tests/eta.bats`
  11/11 green locally and in CI (PR #117). shellcheck clean.
- Not fixed: review nice-to-have #4 (duration-mapping test only checks the
  `estimation:` echo, not the seconds value) and #5 (`eta_esc_id` escaping
  narrower than legacy `claimed_by` shapes could need) — both flagged as
  no-action-required/no live bug by the reviewer; left as-is rather than
  padding this fix.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the two
  regression BATS cases from the review's exact repro before touching
  `eta.sh`, confirmed both failed (2w: "unrecognized estimation bucket";
  malformed id: no rejection), then implemented the fixes to green.
- Verification (`superpowers:verification-before-completion`): yes — ran
  `bats tests/eta.bats` (11/11), shellcheck, markdownlint, manual checks of
  all three fixes (2w bucket, malformed id rejection, `--tz America` now
  correctly rejected) before opening the PR.
- Systematic debugging (`superpowers:systematic-debugging`): no — both
  bugs were already root-caused by the independent review; no debugging
  needed, just implementation.
- Receiving code review (`superpowers:receiving-code-review`): yes — this
  entire task exists because of a code-review agent's findings on PR #115;
  implemented all must-fix and should-fix items, explicitly declined the
  two nice-to-haves with rationale recorded above rather than silently
  ignoring them.
