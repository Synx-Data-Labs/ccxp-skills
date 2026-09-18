---
estimation: 2h
status: Review
source: conversation 2026-09-18
description: Add cross-session status persistence + `/autopilot status` to the autopilot skill
---

# T20260918-174226 — Add `/autopilot status` and cross-session state to `/autopilot`

## TLDR

- **Type**: feature
- **Problem**: `/autopilot`'s only state is the `ScheduleWakeup` resume prompt text — after a `/clear`, there's no way to see what it did or where it's stuck.
- **Solution**: write a small gitignored state file (`dev/.autopilot-state.json`) at each existing phase transition (purely additive, no change to loop control-flow), and add a read-only `status` argument branch that reports it plus live-derived Done/Needs-attention lists.

## Problem

- `autopilot/SKILL.md` carries loop state (`end_time`, `stuck_count`) only in the `ScheduleWakeup` resume prompt (`/autopilot until <ts> stuck=<n>`), and the running summary tally only in conversation history (SKILL.md Phase 1 note: *"The running summary tally does not survive a resume in the prompt text... don't block the loop on it"*).
- After `/clear` (a new session), both are gone — there is no file on disk today a fresh session could read to answer "is autopilot running, what did it finish, what needs me."

## Context

- `autopilot/SKILL.md` Phase 1/3/4/5 already fully define the loop; this task extends it, doesn't replace it.
- This repo treats task files as the single source of truth for task status (`lifecycle.md`: *"no external mirror"*) — `dev/TODO/*.md` frontmatter (`status:`, PR ref in title) and `gh pr view` already answer "in progress" / "PR open" for any task, autopilot-driven or not.

## Solution

- **State file** — `dev/.autopilot-state.json` (gitignored, new `.gitignore` entry): `{status, started_at, end_time, stuck_count, cycle_count, last_cycle_at, last_outcome, last_task: {id, slug}, last_stuck_reason, stop_reason}`. Only fields the loop itself produces and nothing else can reconstruct.
- **Purely additive** — the existing resume-prompt contract (`/autopilot until <end_time> stuck=<n>`) is unchanged and stays authoritative for loop control; Phases 1/3/4/5 just also write this file at each transition, so it stays in sync for observability even across a `/clear`.
- **New `status` argument branch** (new Phase 0, checked before Phase 1's duration parsing): argument is exactly `status` (case-insensitive) → read the state file (missing → "autopilot has never run in this repo"); report running/stopped + end_time/remaining + backoff state from the file; derive **Done** via `git log --since=<started_at> --diff-filter=A --name-only -- dev/JOURNAL/`; derive **Needs your attention** by scanning `dev/TODO/*.md` for `status: Review` + PR ref (query via `gh pr view`) and `status: Blocked by T{id}`, plus `stuck_count`/`last_stuck_reason` from the file. Same bullet template as the existing Phase 5 report. Read-only — no `ScheduleWakeup`, terminal for the turn.
- **Alternatives rejected**: a cached tally of merged tasks / open PRs in the state file (drifts from the task files, which are already the source of truth — rejected in favor of deriving live); restructuring the resume-prompt contract to read `end_time`/`stuck_count` from the file instead of the prompt (more invasive than needed for this fix, no behavior benefit).

## Test plan

- [x] Verified `dev/.autopilot-state.json` is untracked: `git check-ignore -v dev/.autopilot-state.json` matches the new `.gitignore` line.
- [x] Verified the Phase 0 "Done" derivation command (`git log --since=<ts> --diff-filter=A --name-only -- dev/JOURNAL/`) runs correctly against this repo's real history.
- [ ] Live end-to-end (post-merge, real run): start a short `/autopilot` run, let one cycle complete, then in a fresh session (simulating `/clear`) run `/autopilot status` → reports running, correct end_time/cycle_count, and any merged task shows under Done.
- [ ] Live end-to-end: force a Stuck cycle → `status` shows `stuck_count` and `last_stuck_reason`.
- [ ] Live end-to-end: after the window elapses → `status` shows `stopped`, `stop_reason: elapsed`.

## Done criteria

- [x] `autopilot/SKILL.md` Phases 1/4/5 write `dev/.autopilot-state.json` at each transition.
- [x] `autopilot/SKILL.md` has a new Phase 0 `status` branch producing the bullet-template report (`autopilot/SKILL.md:32-40`).
- [x] `.gitignore` has an entry for `dev/.autopilot-state.json`.
- [x] `argument-hint` updated to `"<duration> | status"`.

## Appendix

- Loop control-flow (`ScheduleWakeup` resume-prompt contract) is unchanged — state-file writes and Phase 0 are purely additive on top of it.
- "Live end-to-end" test-plan items are genuinely external (need a real multi-cycle run) and stay unchecked until exercised for real.
- Moves to `Review` once a PR is open, and to `dev/JOURNAL/` once those live checks pass or are explicitly waived.
