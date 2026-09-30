---
status: In Progress
estimation: 30m
source: this conversation, 2026-09-30
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20260929-733657: Add a one-letter autopilot status indicator to the statusline's `ap:` segment

Design approved in-conversation 2026-09-30 — the `[r]`/`[b]`/`[s]` design was
agreed live, skipping the separate design PR; this file was grown into the
full design-doc structure afterward, before implementation, per the
design-score gate.

## TLDR

- **Type**: feature
- **Problem**: the `ap:` statusline segment gives no at-a-glance signal for
  *which* state an autopilot run is in — running normally, backing off after
  a stuck `/drive` cycle, or already stopped (`statusline-command.sh:107`
  currently prints nothing at all once `status != "running"`).
- **Solution**: prefix the segment with `[r]`/`[b]` while running (derived
  from `last_outcome`) and `[s]` once stopped — the stopped segment lingers
  (no dismiss/expiry) since `dev/.autopilot-state.json` itself already
  persists past a stop by design.

## Problem

- Today the statusline's optional `ap: <elapsed>/<requested>hr
  <stuck>/<cycle>` segment (`sl-autopilot-part`,
  `statusline-setup/scripts/statusline-command.sh:95-130`) only renders when
  `status == "running"` (line 107) — a stuck/backing-off run looks identical
  to a healthy one, and a stopped run shows nothing at all.
- `autopilot/SKILL.md`'s own State file section documents that
  `dev/.autopilot-state.json` is never deleted: Phase 5 flips `status` to
  `"stopped"` and fills `stop_reason`, but leaves `stuck_count`/`cycle_count`/
  `last_*` as Phase 4 last set them, specifically so `/autopilot status` can
  still report on a finished run. The statusline currently throws that
  persisted state away instead of surfacing it.

## Context

- **Feature** — this plugs into the existing `sl-autopilot-part` helper and
  the `dev/.autopilot-state.json` schema `autopilot/SKILL.md`'s § State file
  already defines; no new state, just reading fields that already exist
  (`status`, `last_outcome`, `last_cycle_at`).
- Design agreed in conversation (2026-09-30):
  - `ap:[r] ...` — running normally: `status == "running"` and
    `last_outcome != "stuck"`.
  - `ap:[b] ...` — backing off/stuck while still running: `status ==
    "running"` and `last_outcome == "stuck"`.
  - `ap:[s] ...` — stopped: `status == "stopped"`. **Lingers** — no
    dismiss/expiry; it only goes away when the next `/autopilot` invocation
    overwrites the state file (Phase 1 first-invocation in
    `autopilot/SKILL.md`).
  - Rejected: clearing/hiding `[s]` on some timeout — the user explicitly
    asked for it to persist ("if there is no status, i would know ap is not
    running" was the alternative considered, then reversed once we confirmed
    the state file itself already persists after a stop — see conversation).

## Solution

- **`sl-autopilot-part`** (`statusline-setup/scripts/statusline-command.sh`):
  - Fetch two more fields in the existing single `jq` call (still one call —
    keeps the TOCTOU-avoidance comment on line 100-101 true): `last_outcome`,
    `last_cycle_at`.
  - Replace the `[ "$ap_status" = "running" ] || return 0` gate (line 107)
    with `[ "$ap_status" = "running" ] || [ "$ap_status" = "stopped" ] ||
    return 0` — accept both, reject anything else (unset/malformed `status`
    still degrades to nothing, same convention as every other guard in this
    function).
  - **Elapsed** differs by state, mirroring `autopilot/SKILL.md` Phase 0's
    own status-report elapsed rule:
    - `running`: `now_epoch - started_epoch` (unchanged — today's behavior).
    - `stopped`: `last_cycle_at_epoch - started_epoch` when `last_cycle_at`
      is set, else `0` (a run that elapsed before any cycle ran) — same rule
      `autopilot/SKILL.md`'s Phase 0 status header uses, so the statusline
      and `/autopilot status` never disagree about what "elapsed" means for
      a stopped run.
  - **Prefix**: `[r]` by default; `[b]` when `status == "running" &&
    last_outcome == "stuck"`; `[s]` when `status == "stopped"`.
  - Output shape unchanged otherwise: `ap:[r] 2/5hr 3/10` — the prefix
    replaces the literal `ap:` + space with `ap:[x] ` (bracket immediately
    after the colon, one space before the numbers), keeping the rest of the
    segment (and its `sl-join`/`ctx:` wiring downstream) untouched.
- **Alternatives considered and rejected**:
  - *A separate `sl-autopilot-status-tag` helper, composed by the caller* —
    rejected: the prefix is intrinsic to this one segment's own semantics
    (it reads the same state file, same call), splitting it into two
    functions would just duplicate the `jq` read (reintroducing the TOCTOU
    gap the single-call comment exists to avoid) for no separation-of-concerns
    win.
  - *Show `[s]` only for N minutes after `last_cycle_at`, then blank* —
    rejected per the Context section above: the user explicitly wants no
    expiry, matching the state file's own no-delete design.
  - *Treat any `status` other than `"running"`/`"stopped"` as `[s]`-worthy
    too* — rejected: the schema (`autopilot/SKILL.md` § State file) only
    ever writes `"running"` or `"stopped"`; anything else is a malformed/
    hand-edited file and should degrade to nothing, same as today's
    malformed-JSON handling.

## Test plan

- [x] `tests/statusline_setup.bats`: replaced `"sl-autopilot-part prints
  nothing when status is stopped"` with `"...prints ap:[s] with elapsed
  from last_cycle_at when stopped"`.
- [x] New unit case: `[r]` prefix when running with no `last_outcome` field
  (the common case — most cycles aren't stuck).
- [x] New unit case: `[b]` prefix when running and `last_outcome ==
  "stuck"`.
- [x] New unit case: `[s]` prefix when stopped, `last_cycle_at` set —
  elapsed computed from `last_cycle_at`, not `now`.
- [x] New unit case: `[s]` prefix when stopped, `last_cycle_at` null —
  elapsed is `0`.
- [x] Existing malformed/clock-skew/missing-field cases still return
  nothing for both `running` and `stopped` — extended the negative
  `stuck_count` case with a `status: stopped` variant.
- [x] `statusline-command` end-to-end case updated: the "prepends ap:
  before ctx:" test's expected string now carries the `[r]` prefix.
- [x] `bats tests/statusline_setup.bats` green locally (36/36) — full
  `bats tests/` suite also green.
- [ ] CI `tests` check green on the implementation PR (post-PR item).

## Done criteria

- [x] `sl-autopilot-part` (`statusline-command.sh:95-130`) prefixes `ap:`
  with `[r]`/`[b]`/`[s]` per the Solution rules — verified by
  `tests/statusline_setup.bats`'s 4 new `[r]`/`[b]`/`[s]` unit cases.
- [x] Statusline shows nothing when the state file doesn't exist (unchanged)
  — verified by `tests/statusline_setup.bats:288` (untouched by this
  change).
- [x] Stopped-state elapsed uses `last_cycle_at` (or `0`), not live `now` —
  verified by the two `[s]`-prefix cases in `tests/statusline_setup.bats`.
- [x] All existing malformed/clock-skew/negative-count guards still return
  nothing — verified by `tests/statusline_setup.bats:325-429`'s existing
  cases plus the one extended to also cover `status: stopped`.

## Root cause

- `statusline-setup/scripts/statusline-command.sh:107` — `[ "$ap_status" =
  "running" ] || return 0`, introduced in `acfaf10` ("feat(statusline): add
  optional autopilot status segment", 2026-09-29). **Deliberate at the
  time**: the segment's only job then was "is autopilot actively running
  right now" — there was no design yet for what a stopped run's segment
  should show, so the simplest-correct choice was "nothing once stopped."
- The gap this task closes isn't a bug in that original design — it's that
  `autopilot/SKILL.md`'s own Phase 5 (same repo, same day) was written to
  deliberately keep the state file around post-stop specifically so
  `/autopilot status` could report on it (`autopilot/SKILL.md` § State
  file). The statusline segment just never got updated to make use of that
  once it existed — an omission of follow-through, not a design flaw in
  either piece taken alone.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `statusline-setup/scripts/statusline-command.sh` | 95-130 (`sl-autopilot-part`) | add `[r]`/`[b]`/`[s]` prefix + stopped-state elapsed calc |
| `tests/statusline_setup.bats` | 288-429 (existing `sl-autopilot-part`/e2e cases) | update the now-invalid "stopped → nothing" case; add 4 new cases |
| `autopilot/SKILL.md` | § State file | source of truth for the `status`/`last_outcome`/`last_cycle_at` schema this reads |
