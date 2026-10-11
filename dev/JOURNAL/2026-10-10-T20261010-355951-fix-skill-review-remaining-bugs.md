---
status: Done
scheduled: 2026-10-05
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: Fix the remaining 2026-09-28 review bugs (drive trap, slack, autopilot, top, incept, gcpr, rca, email-triage)
claimed_by:
claimed_role:
---

# T20261010-355951: Fix the remaining 2026-09-28 review bugs (drive trap, slack, autopilot, top, incept, gcpr, rca, email-triage)

## Problem

- **Type**: bug
- README §1 bugs not yet fixed (`cleanup-branch` and the frontmatter ones shipped via T20260928-101526's split-offs; the `todo` path bug is T20261010-254146):
  - `drive/SKILL.md` Phase 1.5: `trap ... EXIT` and `$TARGET` do not persist across Bash tool calls.
  - `slack/SKILL.md`: `SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_FOO"` expands empty when the var lives only in `~/.claude/.env`.
  - `autopilot`: a `WAITING` result counts as progress, so it re-dispatches `/address-pr` every 60 s.
  - `top --before`: inserts in reverse, so a blocker lands behind the task it blocks.
  - `incept`: says "lint only the touched file", then runs `lint-docs.sh --fix` repo-wide.
  - `gcpr`: hardcoded `Co-Authored-By` model trailer; Step 6.5 edits the task file after PR creation and never commits it.
  - `rca` + `labrun-rca`: a delegated RCA posts twice.
  - `email-triage`: claims "read-only" although the Gmail connector can send, trash and label.
- Done looks like: each bug fixed in its SKILL.md (or script) with a regression eval case or BATS test.

## Solution

- One PR is fine; each fix is a small prose/script edit anchored at the README §1 `file:line` ref.
- Prose-only skills get an `evals/evals.json` case (`skill-conventions` §10 format); script-backed ones get a BATS test.
- Verified: refs come from `dev/quality/skill-review-2026-09-28/README.md` §1 and `batch1.md`/`batch2.md`/`batch4.md`.

## Test plan

- [x] `bats tests/*.bats` and `skill-conventions/scripts/test_skill_quality.py` green.
- [x] Each bug has a named eval case or BATS test.

## Done criteria

- [x] All eight bugs above fixed (each mapped to its test in the Closed section).

## Closed (2026-10-10)

- Design approved in-conversation 2026-10-10 (user: `/drive all 3 of them`); design PR skipped per `/drive` Phase 2.
- Shipped in the PR titled "fix(skills): remaining 2026-09-28 review bugs (T20261010-355951)" (see its number in `git log`).
- Fixes, each with its regression test (red on the old text, green now; `tests/skill_review_regressions.bats` unless noted):
  - `drive`: no `trap ... EXIT` / `$TARGET` across Bash calls; explicit literal-path cleanup at Phase 7.
  - `slack`: `--channel` parsed inside `slack/scripts/slack-send.sh` after `.env` loads, loud failure on an unset var (`tests/slack_send.bats` 18-19); `retro`/`ccxp` callers switched to `--channel dev`.
  - `autopilot`: `WAITING` is its own Waiting bucket with exponential backoff, no longer Progress.
  - `top --before`: processes the expanded list forward, so a blocker stays ahead of its task.
  - `gcpr`: trailer is the session's attribution line, not a hardcoded model; the `Review` flip happens before the commit.
  - `rca` + `labrun-rca`: new `--no-post` flag; `labrun-rca` passes it, so one post in the thread only.
  - `email-triage`: read-only is stated as policy, with the connector's mutating tools named.
  - `incept`: already fixed on `main` (lint is check-only and path-scoped); a guard test pins it.
- Verification: `bats tests/*.bats` green except `eta.bats` #9, which fails identically on pristine `main` locally (unrelated); `test_skill_quality.py` OK; `skill_score.py --check` passes (50 skills at or above baseline).
- Not verified: no live `claude -p` eval run (the guards are textual, per the prose-only-skill rule in `skill-conventions` §6).

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — red-then-green shown for the slack script and the prose guards
- Verification (`superpowers:verification-before-completion`): yes — test runs above, before the PR
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): see PR comments
