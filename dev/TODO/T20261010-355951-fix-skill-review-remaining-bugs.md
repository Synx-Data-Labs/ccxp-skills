---
status: In Progress
scheduled: 2026-10-05
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: Fix the remaining 2026-09-28 review bugs (drive trap, slack, autopilot, top, incept, gcpr, rca, email-triage)
claimed_by: cc1-50ac6891:e75f7e24dbd4bb3f
claimed_role: interactive
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

- [ ] `bats tests/*.bats` and `skill-conventions/scripts/test_skill_quality.py` green.
- [ ] Each bug has a named eval case or BATS test.

## Done criteria

- [ ] All eight bugs above fixed (each mapped to its test in the Closed section).
