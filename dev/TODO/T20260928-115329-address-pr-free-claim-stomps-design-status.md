---
status: Design
estimation: 1
source: this conversation, 2026-09-28 — independent review finding on PR #164
related: T20260610-248248
claimed_by: cc1-50ac6891:da7297ceb68effbb
claimed_role: interactive
---

# T20260928-115329: `address-pr`'s "free" claim procedure stomps `status: Design` back to `In Progress`

## TLDR

- **Type**: bug
- **Problem**: `address-pr` §1.6's `free` claim runs `task_claim.sh acquire`, which hard-sets `status: In Progress`; a task sitting at `Design` is silently demoted.
- **Solution**: capture the pre-acquire status, then restore it in the claim-branch frontmatter (same commit, same claim PR) when it was not `Open`; apply to `free` and `new`.

## Problem

- Repro (verified, `_session/task_claim.sh:566-569`): acquire's `none` branch writes `claimed_by`, `claimed_role`, then unconditionally `status "In Progress"`.
- `address-pr/SKILL.md:127` (`free` step 1) calls `acquire` with no correction; `:134` (`new` step 2) likewise.
- Impact: a `Design` task (just `/incept`-ed, no code yet) lands on `main` as `In Progress` via the claim PR, so the board and every peer read it as actively coded.
- Surfaced by the independent review of PR #164.

## Context

- `/ipm` step 3.4 (`ipm/SKILL.md:143-150`) already documents `acquire` then `status.sh <id> Design`.
- Verified gap in that precedent: `_session/status.sh` only mutates the Project board (`_session/status.sh:1-9`), never the task frontmatter. On `/address-pr`'s claim PR the frontmatter is what merges to `main`, so `status.sh` alone would leave `main` at `In Progress`.
- So the fix must edit the frontmatter on the claim branch; `status.sh` is an optional board mirror on top.

## Solution

- Add one shared sub-step to `address-pr/SKILL.md` §1.6, referenced by both `free` and `new`:
  - Before `acquire`: `PRE=$(bash ../_session/task_claim.sh read <id> | cut -f1)`.
  - After `acquire`: if `PRE` is non-empty and not `Open`/`In Progress`, restore it with the script's own writer, then mirror with `status.sh <id> "$PRE"` (best-effort).
  - The restore lands in the same commit as the claim, so the claim PR stays a pure frontmatter change.
- Alternatives rejected:
  - Change `_tc_acquire` to preserve status: out of scope (caller-side fix per `ccxp/SKILL.md` precedent; `/drive` relies on the primitive setting `In Progress`).
  - `status.sh` only (the `/ipm` pattern): board-only, so frontmatter on `main` stays wrong (see Context).
  - Hand-edit the `status:` line with `sed`: BSD vs GNU `sed -i` differ; `_tc_fm_set` is atomic and already used by the script.

## Root cause

- `_tc_acquire` assumes the pre-state is `Open` (`_session/task_claim.sh:569`); an oversight, not a deliberate overwrite. T20260610-248248 patched only the `/ipm` caller, not this one.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | `550-573` | `_tc_acquire`, the unconditional status write |
| `address-pr/SKILL.md` | `125-137` | `free` and `new` claim procedures to patch |
| `ipm/SKILL.md` | `138-150` | existing correction precedent to cross-reference |

## Test plan

- [ ] Local: scratch clone, task at `status: Design`, run the new snippet, confirm frontmatter reads `Design` with `claimed_by` set.
- [ ] Local: same with `status: Open`, confirm `In Progress` (unchanged path).
- [ ] CI: Markdown Lint, lint-tasks, skill-quality, bats green on the implementation PR.

## Done criteria

- [ ] `free` procedure preserves pre-existing `Design` (`address-pr/SKILL.md` §1.6 `free` step 1; scratch test above).
- [ ] `new` procedure does the same (`address-pr/SKILL.md` §1.6 `new` step 2).
- [ ] Cross-referenced against `/ipm` step 3.4 (`address-pr/SKILL.md` §1.6 note naming `ipm/SKILL.md`).
