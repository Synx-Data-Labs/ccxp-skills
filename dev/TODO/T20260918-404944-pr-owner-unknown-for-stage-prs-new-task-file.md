---
status: Design
estimation: 1h
source: this conversation, 2026-09-18
related: T20260718-160579, T20260922-324422
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-404944: `task_claim.sh pr-owner` always returns `unknown` for `/stage` PRs that introduce a brand-new task file

## TLDR

- **Type**: bug (tooling gap in `_session/task_claim.sh`)
- **Problem**: `pr-owner` resolves a PR's task file only via the GitHub contents
  API on `ref=main`; a `/stage` PR that introduces the task file for the first
  time (same PR carries `queue.md` + the new file) has no file on `main` yet,
  so resolution fails closed to `unknown`, and `/address-pr` §1.6 refuses to
  ever merge such a PR.
- **Solution**: when the `main`-ref lookup fails, fall back to resolving the
  file on the PR's own head ref (same `dev/TODO`/`dev/PARKING` search); if
  found there, fetch `claimed_by` from that ref (not `main`) and feed it
  through the normal `mine`/`free`/`owned:` decision instead of a bare
  `unknown`.

## Problem

- Discovered while running `/address-pr` on PR #39, a `/stage` PR staging
  task `T20260918-214522` (its task file was net-new in that same PR).
- `_tc_pr_owner` (`_session/task_claim.sh:739`) calls
  `_tc_resolve_task_location` (`_session/task_claim.sh:623`), which resolves
  the same-repo case by listing `dev/TODO` **on `main`** via
  `_session_gh api "/repos/$repo/contents/$dir?ref=main"`
  (`_session/task_claim.sh:673`) and matching a filename that starts with the
  task id.
- `/stage`'s own documented design (`stage/SKILL.md` step 3) commits the
  `queue.md` append **plus the new task file itself** in the *same* PR the
  first time a task is staged — the task file legitimately does not exist on
  `main` yet at the moment `/address-pr` is asked to drive that very PR.
- Result: the same-repo loop finds nothing in either `dev/TODO` or
  `dev/PARKING` on `main` → `_tc_resolve_task_location` returns 1 →
  `_tc_pr_owner` prints `unknown` (`_session/task_claim.sh:750`) →
  `/address-pr` §1.6's fail-safe says defer, never merge. Taken literally,
  `/address-pr` can never merge a `/stage` PR for a task that didn't already
  exist on `main` — contradicting `/stage`'s own instruction to hand such PRs
  to `/address-pr`.
- Distinct from T20260718-160579 (a stale branch-name-vs-body `Task:` link
  mismatch on a *rescoped* PR): here the file is simply not on `main` yet, by
  design — not mislinked.
- Manual workaround used on PR #39 (not repeatable at scale): confirmed the PR
  body's staged task id matched the one new file in the diff exactly,
  confirmed the new file carried no `claimed_by` (freshly authored, nothing to
  race), and proceeded since `/stage` PRs are pure lifecycle bookkeeping with
  no implementation to steal.

## Context

- **Bug** — the repro is any `/stage` PR (or `/new-task` immediately followed
  by `/stage`) whose diff is the *first* commit of a task file: `git diff
  main...HEAD --name-status` shows the file as `A` (added), never `M`.
- `_tc_resolve_task_location`'s two call sites both key off the same
  `main`-only assumption:
  - the cross-repo branch (`_session/task_claim.sh:637-661`) parses a `Task:`
    body link and is unaffected — that link always names an *existing* hub
    file — so this bug is same-repo only.
  - the same-repo branch (`_session/task_claim.sh:662-680`) is the one that
    fails.
- `_tc_fetch_fm_field` (`_session/task_claim.sh:682-693`) also hardcodes
  `?ref=main` — even if location resolution were fixed, fetching
  `claimed_by` would still need a ref override to read a not-yet-merged file.

## Solution

- **`_tc_resolve_task_location`**: on same-repo failure (file absent from
  both `dev/TODO` and `dev/PARKING` on `main`), do **not** return 1
  immediately. Fall back to the same directory search against the PR's own
  head ref (`gh pr view <pr> --json headRefOid`) instead of `main`. If found
  there, return the path exactly as before — the caller can't yet tell "found
  on main" from "found on head-only", so:
- **`_tc_pr_owner`**: track *which* ref the location resolved against
  (`main` vs. the PR's head SHA) and pass that ref through to
  `_tc_fetch_fm_field` when reading `claimed_by`, instead of assuming `main`.
  A head-only resolution then flows through the *existing* `mine`/`free`/
  `owned:` decision logic unchanged — a fresh file with empty `claimed_by`
  naturally decides `free`, matching the "Done looks like" ask, without a
  bespoke new state.
- **`_tc_fetch_fm_field`**: add an optional 4th arg (ref, default `main`) so
  the existing `main`-reading call sites are unaffected.

**Alternatives considered and rejected**:

- *Return a hardcoded `free` whenever the PR's diff adds a task file matching
  the id, without reading its `claimed_by`.* Rejected: skips the "confirm no
  claimed_by" check the manual workaround did on PR #39 — a raced re-stage
  where the new file already carries a stamped `claimed_by` (unlikely, but
  possible if two agents raced `/new-task` + `/stage`) would then be silently
  treated as free instead of correctly deferring via `owned:`.
- *Add a brand-new `pr-owner` verdict (e.g. `new`) instead of routing through
  the existing `free`/`mine`/`owned:` decision.* Rejected: `/address-pr` §1.6
  already has full, tested handling for `free` (claim-then-proceed) — a new
  verdict would need its own caller-side branch for no behavioral gain over
  reusing `free`.
- *Have `/address-pr` special-case "PR adds the task file" instead of fixing
  `task_claim.sh`.* Rejected: `pr-owner` is the single source of truth other
  callers (the reclaim sweep, tests) also rely on; fixing it there fixes every
  caller at once instead of duplicating the diff-vs-main check in each one.

## Test plan

- [x] `bats tests/task_claim.bats` — full suite passes locally after the change.
- [ ] New unit test: `resolve_task_location: task file present on the PR's own
      HEAD ref but absent from main -> resolves via head-ref fallback`
      (`tests/task_claim.bats`, alongside the existing `resolve_task_location:
      same-repo, task file present in NEITHER dir -> fails closed (unknown)`
      case).
- [ ] New unit test: `pr-owner: task file new in this PR (absent on main,
      present on head, no claimed_by) -> free`.
- [ ] New unit test: `pr-owner: task file new in this PR but already carries a
      claimed_by on head -> owned:<by>` (the raced-restage edge case named in
      Solution's rejected-alternative above).
- [ ] Manual smoke: re-run `bash _session/task_claim.sh pr-owner 39` against
      the real PR #39 (already merged) is not repeatable as a live repro since
      the file is on `main` now — instead verify against **this task's own
      claim PR** while it is still open (a same-repo PR whose diff adds no new
      task file, so it must still resolve exactly as before — regression
      check, not a new-file repro).

## Done criteria

- [ ] `_tc_pr_owner` returns `free` (not `unknown`) for a same-repo PR whose
      diff introduces the task file and that file carries no `claimed_by` —
      `tests/task_claim.bats` test `pr-owner: task file new in this PR
      (absent on main, present on head, no claimed_by) -> free`.
- [ ] `_tc_pr_owner` returns `owned:<by>` (not `free`) for the same shape but
      with a `claimed_by` already stamped on the head-ref copy —
      `tests/task_claim.bats` test `pr-owner: task file new in this PR but
      already carries a claimed_by on head -> owned:<by>`.
- [ ] `_tc_resolve_task_location` falls back to the PR's head ref only after
      the `main`-ref lookup fails — `tests/task_claim.bats` test
      `resolve_task_location: task file present on the PR's own HEAD ref but
      absent from main -> resolves via head-ref fallback`.
- [ ] All pre-existing `_tc_resolve_task_location` / `_tc_pr_owner` bats cases
      at `tests/task_claim.bats:585-880` still pass unchanged — no regression
      to the `main`-resolved path (full-suite run: `bats tests/task_claim.bats`).
- [ ] `_tc_fetch_fm_field` (`_session/task_claim.sh:682`) accepts an optional
      ref argument, default `main` — existing callers that omit it are
      unaffected (same bats full-suite run as above covers this).

## Root cause

- `_tc_resolve_task_location`'s same-repo branch was written assuming the
  task file it's asked to locate always already exists on `main` — true for
  every caller *except* `/stage`'s own documented "commit the new file in the
  same PR" pattern (`stage/SKILL.md` step 3, itself pre-existing).
- Git archaeology: this repo's history starts at a single squashed `Initial
  public release` commit (`890c1ce`) after the split from a private
  predecessor — `_tc_resolve_task_location` and the same-repo fallback
  (`git log -S _tc_resolve_task_location`) both predate that split, so the
  original introduction date/rationale isn't recoverable from this clone's
  git log. The oversight is structural (a `main`-only assumption baked into
  the original design), not a recent regression — `/stage`'s "commit the new
  file in the same PR" convention and `pr-owner`'s `main`-only resolution were
  never reconciled against each other until this task surfaced the gap on a
  real PR (#39).
- Deliberate-vs-oversight: oversight — `/address-pr` §1.6's own "unknown"
  case comment (`address-pr/SKILL.md`) explicitly frames unresolvable-as-fail-safe
  for network/not-found reasons, not for "resolvable, just not merged yet";
  the `/stage`-introduces-the-file case was never enumerated as a scenario
  when that fail-safe was designed.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | 623-680 | `_tc_resolve_task_location` — same-repo `main`-only lookup; add head-ref fallback here |
| `_session/task_claim.sh` | 682-693 | `_tc_fetch_fm_field` — hardcoded `?ref=main`; add optional ref arg |
| `_session/task_claim.sh` | 739-764 | `_tc_pr_owner` — thread the resolved ref through to the `claimed_by` fetch |
| `tests/task_claim.bats` | 581-880 | Existing `pr-owner`/`resolve_task_location` bats coverage; add new cases alongside |
| `stage/SKILL.md` | step 3 | Documents the "commit the new file in the same PR" convention this bug is triggered by (no change needed — cited for context) |
| `address-pr/SKILL.md` | §1.6 | Caller of `pr-owner`; its `free` handling (claim-then-proceed) already covers the new outcome without change |

## Dependencies

- Related to T20260718-160579 (a different `pr-owner` misresolution — stale
  branch/body-link mismatch on a rescoped PR) and T20260922-324422 (another
  `pr-owner` misresolution class) — same function family, different root
  causes; no blocking relationship.
