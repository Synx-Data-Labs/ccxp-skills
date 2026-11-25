---
status: Done
estimation: 1
source: this conversation, 2026-11-24
description: Split the HUD WORK section into AUTOPILOT (autopilot-only summary) and WORK (all non-autopilot ledger rows)
claimed_by:
claimed_role:
---

# T20261124-273213: HUD: split WORK into AUTOPILOT and WORK sections

## TLDR

- **Type**: feature (HUD `/hud details`).
- Owner: "split the WORK into AUTOPILOT and WORK, where AUTOPILOT only keep the autopilot related stuff, and the WORK keep the rest".
- New `AUTOPILOT` section: status, max_dop use, holds count, next wake, 24h merged. `WORK`: jobs state, parked and 24h jobs, counting only ledger rows without the `autopilot` flag.
- No new data source; the band, limit cell, version row and colours are unchanged.

## Problem

- `detailRows` put the autopilot cells and the jobs cells in one `WORK` row (`hud/model.ts:1286` before the change).
- The jobs state (`READY`/`WORKING (N)`) counted the autopilot's own cycles as work, so the two concerns were mixed.
- Everything shown today must still appear somewhere.

## Context

- Autopilot cycles are ledger rows with `--flags autopilot` (`hud/scripts/ledger.sh`); the helper already passes `flags` per running row (`sl-ledger-json`, `hud/scripts/hud-lib.sh`).
- Holds come from the queue breakdown (`queue.apholds`, from the state file's `.holds`), already parsed.

## Root cause

- Introduced in the original details-sections change (journal `dev/JOURNAL/2026-10-27-hud-repo-and-status.md`): deliberate at the time (one WORK row), now superseded by the owner's request; `hud/model.ts` `detailRows` is the only place.

## Repo file references

| File | Change |
|---|---|
| `hud/model.ts` | `isApJob`, AUTOPILOT section, WORK filtered, label width |
| `hud/pure.test.ts` | new split tests, existing details tests moved |
| `tests/hud_model_refs.bats` | structural guard |
| `hud/README.md`, `hud/HELP.md` | details docs |

## Solution

- `AUTOPILOT` section (before `WORK`): the existing AP cell, max_dop cell, next-loop / running-cycle cell and 24h cell, plus a new `N held` cell (only above 0). Autopilot off leaves just `AP off` (plus the dim configured max_dop when a config exists).
- `WORK` section: `READY`/`WORKING (N)` over running rows WITHOUT the `autopilot` flag, `parked N`, `last 24h: jobs ...`. A non-cycle job the autopilot starts (housekeeping) has no flag and counts as WORK.
- `DETAIL_LABEL_WIDTH` 9 -> 10 so `AUTOPILOT` fits the label column.
- Alternatives rejected: a per-cycle line `AP 4/6 running, 2 held, next 17:42` replaced by the existing cells (they already carry running/max_dop, holds and next wake and keep every cell shown today); splitting the 24h jobs figure by flag (the start log keeps no flag, so it stays an all-jobs figure in WORK).

## Test plan

- [x] `hud/pure.test.ts`: sections order, AUTOPILOT cells (holds, max_dop, wake, 24h), WORK without them, the flag filter (cycles do not count, unflagged jobs do), empty AUTOPILOT with autopilot off; existing details tests moved to the new sections.
- [x] `tests/hud_model_refs.bats`: structural guard (section order, filter present).
- [x] `hud/README.md`, `hud/HELP.md` updated.

## Done criteria

- [x] AUTOPILOT section with status, max_dop use, holds, next wake, 24h merged: `hud/pure.test.ts` `hud/pure.test.ts` test "details split: AUTOPILOT carries status ...".
- [x] WORK counts only unflagged rows; housekeeping counts as WORK: `hud/pure.test.ts` test "details split: autopilot cycles (flag autopilot) do not count as WORK".
- [x] Autopilot off leaves AP off only: `hud/pure.test.ts` test "details split: autopilot off leaves AUTOPILOT as AP off only".
- [x] Everything shown today still appears: `hud/pure.test.ts` test "details sections: every cell of the old details-on output is still present".
- [x] Docs updated: `hud/README.md:295`, `hud/HELP.md:118`.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes, code-class; tests updated alongside the change
- Verification (`superpowers:verification-before-completion`): yes, pure.test.ts 201/201 through a local shim
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): see PR

## Closed (2026-11-24)

- Shipped in the PR from branch `hud-autopilot-work-split` (this task's file closes in the same PR).
- Met: all done criteria above; `hud/pure.test.ts` 201/201 through a local deno shim of the claude-code runner (the real runner is not available locally; CI runs the bats suites).
- Quality probe: 8 files, shellcheck clean, no regression.
- Not verified: the `hooks.test.tsx` suite (needs JSX in the real runner).
- Owner addendum in the same PR: the details REPO section is renamed CLONE (same content and order; the `repo` cell is unchanged).
- Follow-ups: none.
