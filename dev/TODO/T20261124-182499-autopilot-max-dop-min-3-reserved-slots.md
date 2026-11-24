---
status: In Progress
estimation: 2
source: owner request, this conversation, 2026-11-24 (decisions d154, d157)
description: Autopilot max_dop minimum 3 plus a reserved_slots setting (default 2) for urgent tier 1 and 2 work
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-182499: Autopilot: max_dop at least 3, add reserved_slots (default 2)

## TLDR

- **Type**: feature
- **Problem**: `max_dop` allows 1-2 although 2 slots are always reserved for urgent tier 1 and 2 work (d154, d157); no `reserved_slots` setting exists.
- **Solution**: `max_dop` becomes 3-16 (default 3), new `reserved_slots` (0-8, default 2, at most `max_dop` minus 1); routine fill limit = `max_dop` minus `reserved_slots`, exposed by `routine-free`, `slots --summary` and `report`.

## Problem

- Owner's words: "for the AP slots, the configurable number has to be 3 and above, since we always reserve 2 slots for the tier1 and tier2 tasks. see if you can create a task and put it inside the /autopilot configuration"
- d154: reserve 2 slots (of `max_dop`) for urgent tier 1 or tier 2 tasks; routine picks fill at most `max_dop` minus 2; the reserved slots serve only urgent work (a new or `/top`'d task, CI-failure response).
- d157: `max_dop` must be 3 or more because 2 slots are always reserved; the reserved count is the config setting `reserved_slots`, default 2.
- Evidence (verified): `_ap_config_spec` gives `max_dop 1 1 16` (`autopilot/scripts/autopilot-state.sh:988`); `ap-max-dop` defaults to 1 (`:122`); no reserved-slot code exists (`grep reserved` finds nothing).

## Context

- Docs to update: `autopilot/SKILL.md`, `autopilot/parallel.md`, top-level `README.md` line 111 ("1-16, default 1"), `hud/README.md` reviewed (no slot-count display, no change).
- Existing tests that assume default 1 are rewritten: "max_dop: default 1, range 1-16", "start/resume ... max_dop=1 unchanged", "report: slots line only when max_dop > 1" (`tests/autopilot_state.bats`).
- Parser: `busy on` accepts `--urgent` anywhere among its arguments and stores it on the slot object; `_ap_slots` keeps its three columns (a `routine` filter argument leaves urgent slots out).
- Doc comments to refresh in `autopilot-state.sh`: the header lines naming "all five settings" and `max_dop` "1-16, default 1".
- Dispatch verdicts compare busy slots with `ap-max-dop`: `start` (`:255`), `resume` (`:289`), `report` slots line (`:737`), overdue hint (`:743`).
- `/autopilot` Phase 3 (SKILL.md) and `autopilot/parallel.md` fill every free slot with routine picks; nothing keeps slots back.
- `config-show` marks a value `override` only when the raw file value equals the effective one (`:1004`), so a clamped value reads `default`.
- `status` prints one word (`on|paused|off`) that callers compare (`:136`): it stays a single word.

## Solution

- `max_dop`: range 3-16, default 3. `ap-max-dop` clamps a smaller file value up to 3 (never rewrites the file). `config set max_dop <n>` with n below 3 exits 2, writes nothing, and says 2 slots are reserved for urgent work.
- `reserved_slots`: integer 0-8, default 2, effective value capped at `max_dop` minus 1 (at least one routine slot). `config set` refuses a value above the cap; `config set max_dop` refuses a value that would leave the stored `reserved_slots` above `max_dop` minus 1.
- Routine limit = `max_dop` minus effective `reserved_slots`. New `routine-free` prints the routine slots still free (limit minus busy, never below 0); `slots --summary` prints `routine <limit> of <max_dop>, reserved <n>, busy <b>, routine-free <f>, free <n>`; `report` always shows that line (the slots line now always applies since the default is 3).
- `start` and `resume` (the routine wake) answer `dispatch` only while a routine slot is free; urgent work claims a reserved slot with `busy on <id> --slot <N>` and is not limited by the routine limit.
- Clamp-on-read notice: `config-show` (text and `--json` `notices`) and `report` print a one-line notice when the file holds `max_dop` below 3 or `reserved_slots` above the cap.
- Validation lives in `ap-config-set`, after the generic range check:
  - `reserved_slots` uses a non-negative reader and validator (0 is valid; `ap-config` and the `^[1-9]` regex stay for the other keys) and `config-show` marks it `override` when the stored value is what is in effect
  - cross-key refusals (exit 2, nothing written): `reserved_slots` above effective `max_dop` minus 1; `max_dop` that would leave the stored `reserved_slots` above `max_dop` minus 1
  - `config-reset` is never refused: a stored value that no longer fits is capped on read, with the notice
- Default 1 to 3, side effects handled:
  - default stays one routine cycle (3 minus 2), so nothing new runs by default; an existing `max_dop` 2 user drops to 1 routine slot (clamped to 3, notice shown)
  - the parallel path (clone per slot, `parallel.md`) applies when the routine limit is above 1; the merge cap can be exceeded by at most `max_dop` minus 1 merges (up to 2 at the default)
- Urgent dispatch: deciding that work is urgent (a new or `/top`'d task, CI-failure response) stays the dispatcher's judgment per d154. An urgent cycle takes the lowest free slot number up to `max_dop` with `busy on <id> --slot <N> --urgent`; the flag is stored on the slot (`urgent: true`), so an urgent cycle never uses up `routine-free` (routine busy = running cycles not marked urgent). `slots --summary` also prints `free <n>` (slots free overall) so the dispatcher can see room for it. `start`/`resume` answer `dispatch` only when a routine slot and an overall slot are both free.
- Existing parallel users (`max_dop` 3 or more today): the routine limit becomes `max_dop` minus 2 (3 gives 1, 4 gives 2): accepted, it is d154 itself; the owner can set `reserved_slots 0` to restore the old fill.
- Alternatives rejected:
  - Default `max_dop` 2 or leaving 1-16: contradicts d157.
  - Rewrite a low value in the file on read: silent mutation of owner config.
  - Add a line to `status`: breaks callers that compare its one-word output.
  - A separate routine counter in state: derivable from busy slots and config, so no new state to drift.

## Test plan

- [ ] `tests/autopilot_state.bats`: `max_dop` 1 and 2 refused (exit 2, file untouched, message names the reserved slots); 3 and 16 accepted; 17 refused; default 3 and range `3-16` in `config-show`.
- [ ] `reserved_slots`: default 2, 0 and 8 accepted when `max_dop` allows, 9 refused, cap at `max_dop` minus 1 refused, `max_dop` lowered under the stored reserved count refused, `config-reset` drops it.
- [ ] `reserved_slots` 0 accepted and `config-show` marks it `override`; urgent-marked slots do not reduce `routine-free`.
- [ ] Clamp-on-read: file with `max_dop` 1 reads 3, notice shown in `config-show` and `report`, file unchanged.
- [ ] Routine limit: `routine-free`, `slots --summary` (with `free`) and `report` output; `start`/`resume` use the routine limit; `config-set` cross-key refusals.
- [ ] Doc pins: SKILL.md and `autopilot/parallel.md` mention `reserved_slots`; skill-quality stays at its baseline.

## Done criteria

- [ ] `config set max_dop` below 3 refused: test "max_dop: range 3-16" in `tests/autopilot_state.bats`.
- [ ] `reserved_slots` key with range and cap: test "reserved_slots" in `tests/autopilot_state.bats`.
- [ ] Clamp notice, no rewrite: test "clamp-on-read" in `tests/autopilot_state.bats`.
- [ ] Routine limit exposed: tests "routine-free" and "report: routine line" in `tests/autopilot_state.bats`.
- [ ] `autopilot/SKILL.md`, `autopilot/parallel.md`, `hud/README.md` (no slot display: reviewed, no change) updated: doc-pin test in `tests/autopilot_state.bats`.
- [ ] CI `skill-quality` check stays green on the PR (external: confirmed by the PR checks).

## Closed

Filled at close.
