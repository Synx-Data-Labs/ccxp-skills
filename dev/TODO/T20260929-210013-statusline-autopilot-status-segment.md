---
status: Design
estimation: 1h
source: this conversation, 2026-09-29
related: T20260924-366770
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20260929-210013: Add optional autopilot status segment to the statusline

## TLDR

- **Type**: feature
- **Problem**: the statusline has no signal that `/autopilot` is running in
  this clone, how far into its window, or how it's going.
- **Solution**: a new `sl-autopilot-part()` reads `dev/.autopilot-state.json`
  when present and `status: "running"`, formats `ap: <elapsed>/<requested>hr
  <stuck_count>/<cycle_count>`, and `sl-join` puts it first.

## Problem

- **Type**: feature
- `statusline-command.sh` (`statusline-setup/scripts/statusline-command.sh:106-120`)
  builds `ctx_part`/`branch_part`/`task_part` but has no visibility into
  whether `/autopilot` is running in this clone — a user watching the
  terminal has no glanceable signal that a multi-hour unattended run is
  active, how far into its window it is, or how it's going.
- `/autopilot` already maintains `dev/.autopilot-state.json`
  (`autopilot/SKILL.md` § State file) per clone, with `started_at`,
  `end_time`, `stuck_count`, `cycle_count` — cheap to read, no extra
  git/gh calls needed.
- Requested format: an optional `ap: 1/5hr 3/10` segment, inserted
  **before** the existing `ctx:` segment, only present when
  `dev/.autopilot-state.json` exists and `status: "running"`:
  - `1/5hr` — hours elapsed / hours requested, from `started_at`/`end_time`
    (elapsed = `now - started_at`; requested = `end_time - started_at`).
  - `3/10` — `stuck_count` / `cycle_count` verbatim from the state file.
    (Confirmed with the user: `stuck_count` for the "needs attention"
    number rather than the richer, git/gh-derived "Needs your attention"
    list `autopilot/SKILL.md` Phase 0/5 compute — that list is too
    expensive to recompute on every statusline render. `cycle_count` for
    the total, matching "already gone through N tasks" directly.)
- Done looks like: `sl-join` (`statusline-setup/scripts/statusline-command.sh:84-91`)
  emits `ap: ... | ctx: ... | branch: ... | TASK: ...` when autopilot is
  running in this clone, and omits the `ap:` segment entirely (falling
  back to today's output) when `dev/.autopilot-state.json` is absent or
  `status: "stopped"`.

## Context

- `tests/statusline_setup.bats` already covers `statusline-command.sh`'s
  existing segments — extend it with cases for autopilot running /
  stopped / absent-state-file.
- `dev/.autopilot-state.json` is gitignored and per-clone, same as the
  claim/session state this script already reads (`sl-claimed-task-label`,
  `statusline-setup/scripts/statusline-command.sh:60-80`) — no new
  cross-clone concerns.
- `jq` is already a hard dependency of this script (`statusline-command()`
  itself uses it to parse the hook-input JSON, lines 96-97) — no new
  dependency introduced by also using it to parse the state file.
- ISO-8601 → epoch conversion needs a portable helper (GNU `date -d` vs
  BSD `date -j -f`) — `ccxp/scripts/epic-status.sh`'s `_epic_iso_to_epoch`
  (lines 110-116) already solves exactly this; port the same two-line
  fallback shape rather than inventing a new one.

## Solution

1. **New `sl-iso-to-epoch(iso)`** — ported from `_epic_iso_to_epoch`
   (GNU `date -u -d "$iso" +%s`, then BSD
   `date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s`; empty on both failing).
2. **New `sl-autopilot-part(repo_root)`**:
   - `state_file="$repo_root/dev/.autopilot-state.json"`; `[ -f
     "$state_file" ] || return 0` (no file → silently nothing, matching
     every other helper's "never fail the prompt" convention already
     documented in this file's header comment).
   - Read all five fields (`status`, `started_at`, `end_time`,
     `stuck_count`, `cycle_count`) in **one** `jq` call producing a
     single tab-separated line (`jq -r '[.status, .started_at,
     .end_time, .stuck_count, .cycle_count] | map(. // "") | @tsv'
     "$state_file" 2>/dev/null`), then `IFS=$'\t' read -r status
     started_at end_time stuck_count cycle_count <<<"$line"` — a single
     read instead of five separate `jq` invocations against the same
     file closes a TOCTOU gap (`/autopilot` could rewrite the file
     between two separate reads, mixing an old field with a new one)
     and is cheaper per statusline render (caught by independent design
     review, 2026-09-29).
   - `status` anything other than exactly `running` → return 0 (covers
     `stopped`, malformed JSON where `jq` errors and prints nothing, and
     a missing field).
   - Convert `started_at`/`end_time` via `sl-iso-to-epoch`; if either is
     empty (unparsable), return 0 — a malformed timestamp shouldn't
     render a garbled segment.
   - **Guard `end_epoch > started_epoch`** — if not (a corrupted state
     file with a backwards timestamp pair), return 0 rather than render
     a negative `requested_hr` like `ap: 1/-2hr` (caught by independent
     design review, 2026-09-29).
   - `elapsed_secs=$(( $(date +%s) - started_epoch ))`,
     `requested_secs=$(( end_epoch - started_epoch ))` — each converted
     to hours and rounded with `awk` (`awk -v s="$elapsed_secs"
     'BEGIN{printf "%.0f", s/3600}'`, same for `requested_secs`), not
     bash integer division, matching the rounding-not-truncating
     precedent `ctx_part` already sets at line 108 (fixed a variable-
     naming inconsistency in an earlier draft that assigned seconds to a
     var named `elapsed_hr` then referenced an undefined `$secs` in the
     `awk` call — caught by independent design review, 2026-09-29). One
     `awk` invocation per value, so e.g. 90 minutes rounds to `2`, not
     truncated to `1`.
   - `printf 'ap: %s/%shr %s/%s' "$elapsed_hr" "$requested_hr"
     "$stuck_count" "$cycle_count"`.
3. **Wire into `statusline-command()`** (line ~106): add `local
   ap_part=""` alongside the existing part locals, `ap_part=$(sl-autopilot-part
   "$repo_root")` right after `repo_root` is resolved, then change the
   final `sl-join` call (line 120) to `sl-join "$ap_part" "$ctx_part"
   "$branch_part" "$task_part"` — `ap_part` first, matching the requested
   `ap: ... | ctx: ...` order; `sl-join` already skips empty parts, so
   this is a no-op change in shape when autopilot isn't running.

**Alternatives rejected**:

- *Compute elapsed/requested with bash-only integer arithmetic
  (`$(( (now - started) / 3600 ))`)* — rejected: truncates instead of
  rounds (89 minutes would show `1hr` requested-side but `0hr`
  elapsed-side inconsistently depending on which side of the hour
  boundary each falls on) — `awk`'s `%.0f` rounds both consistently, and
  `ctx_part` already sets the "round, don't truncate" precedent at
  line 108.
- *Recompute the richer `autopilot/SKILL.md` Phase 0/5 "Needs your
  attention" list for the second number* — rejected per the Problem
  section: that list needs `git log`/`gh pr view` calls, too expensive to
  run on every prompt render (a statusline re-renders on every
  keystroke-adjacent event) — `stuck_count` is already in the state file,
  free to read.

## Test plan

- [ ] `bats tests/statusline_setup.bats` — new cases:
  - [ ] `sl-iso-to-epoch` round-trips a known ISO-8601 timestamp to the
        correct epoch value.
  - [ ] `sl-autopilot-part` prints nothing when
        `dev/.autopilot-state.json` doesn't exist.
  - [ ] `sl-autopilot-part` prints nothing when `status` is `"stopped"`.
  - [ ] `sl-autopilot-part` prints `ap: <N>/<M>hr <stuck>/<cycle>` for a
        fixture `status: "running"` file. No time-mocking seam — existing
        `statusline_setup.bats` cases are all clock-independent, and this
        adds none: write `started_at`/`end_time` as offsets from the real
        wall-clock `date` at test-run time (e.g. `started_at` = now minus
        90 real minutes via `date -u -v-90M` / `date -u -d '90 minutes
        ago'`, `end_time` = now plus a known delta), then assert the
        rounded hour values the design's own rounding rule predicts for
        those offsets (clarified after independent design review flagged
        this as unspecified, 2026-09-29).
  - [ ] `sl-autopilot-part` prints nothing when the JSON is malformed.
  - [ ] `sl-autopilot-part` prints nothing when `end_time` is before
        `started_at` (corrupted state file) — added after independent
        design review, 2026-09-29.
  - [ ] `statusline-command` end-to-end: with a running-state fixture,
        output starts with `ap: ...` before `ctx: ...`; without one,
        output is unchanged from today (regression guard against the
        existing `statusline-command` tests already in this file).
- [ ] Full `bats tests/*.bats` passes.

## Done criteria

- [ ] `sl-iso-to-epoch` round-trips a known timestamp — `tests/statusline_setup.bats`.
- [ ] `sl-autopilot-part` covers all five cases (absent file / stopped /
      running / malformed / backwards timestamps) — `tests/statusline_setup.bats`.
- [ ] `statusline-command()` (`statusline-setup/scripts/statusline-command.sh:120`)
      wires `ap_part` first into `sl-join` — end-to-end case in
      `tests/statusline_setup.bats`.
- [ ] No behavior change when autopilot isn't running — pre-existing
      `tests/statusline_setup.bats` cases pass unmodified.
