---
status: Done
estimation: 1h
source: 2026-09-28 conversation — /drive T20260408-359583 session worked from an existing sibling clone (build-pipeline-repo) instead of a fresh ephemeral one, on the clone-locality guard's own advice
related: T20260513-403409 (Phase 1.5 ephemeral-clone design), T20260513-422869 (removed claims machinery on the "own clone" premise), T20260626-298293 (added the clone-locality guard)
owner: Shine
---

# T20260928-324939: Clone-locality guard tells you to `cd` into a sibling's existing clone — contradicts the 2026-05-13 "always your own clone" decision

## TLDR

- **Type**: bug (skill/process)
- **Problem**: `/drive`'s clone-locality guard tells you to `cd` into an existing sibling
  clone for a cross-hub task, contradicting the documented "own clone" policy and risking
  collision with a live concurrent session (cron or otherwise) in that clone.
- **Solution**: make the guard's cross-repo case spin up a fresh ephemeral clone (mirroring
  Phase 1.5's existing pattern) instead of pointing at the shared local one.

## Problem

- **Type**: bug (skill/process)
- `hub-repo`'s `/drive T20260408-359583` picked a task whose file lives natively in
  `build-pipeline-repo`'s own `dev/TODO/` (not a `Target repo:`-declared cross-repo task —
  just a different hub). `/drive`'s clone-locality guard
  (`_taskid/in-this-repo.sh`) fired, printed `Found it in: <local sibling clone path>`, and its
  banner literally said *"Switch to that clone before working it"* — i.e. reuse the existing
  local clone.
- The session did exactly that: claimed, prototyped, and opened two PRs from
  `/Users/<user>/workspace/synx-data-labs/build-pipeline-repo` — the maintainer's own working
  clone, which the `build-pipeline-repo` ccxp cron *also* uses. Mid-session, uncommitted WIP
  from a live concurrent cron run (a SynxDB4 4.8.0 release task, including a real external
  action — 9 GitHub tags deleted) was sitting in that same working tree at the same time.
- This directly contradicts a decision from 2026-05-13
  (`build-pipeline-repo/dev/JOURNAL/2026-05-13-T20260513-403409-focus-phase-1.5-ephemeral-clone.md:6`),
  quoting the maintainer: *"we work on our own clones, and if we need to across repo, we create
  a new clone."* That principle is what `/drive` Phase 1.5's `Target repo:` cross-repo mode
  correctly implements (always clones fresh to `/tmp/T<id>-<slug>-target`, "never reuse another
  session's clone or the maintainer's working clone"). The clone-locality guard
  (`T20260626-298293`, added *after* Phase 1.5 existed) was never reconciled against it — it
  solves a real problem (claim/journal ending up in the wrong repo) with the wrong mechanism
  (pointing at a shared clone instead of making a fresh one).
- No data was lost this time (commits used explicit `git add <path>`, not `-A`), but the
  near-miss is real: an interleaved `git checkout`/`git pull` from a second live session in the
  same working tree is exactly the class of failure the 2026-05-13 decision and Phase 1.5 both
  exist to rule out.

## Solution

Make the cross-repo case of the clone-locality guard **always spin up a fresh ephemeral clone**,
mirroring Phase 1.5's existing pattern, instead of pointing at (or implicitly inviting reuse of)
an existing local clone.

1. **`_taskid/in-this-repo.sh`**: add `in-this-repo--sibling-slug <id>` — resolve `owner/repo`
   from the sibling clone's `origin` remote (same parsing `taskid-repo-slug` already does, just
   run via `git -C "$sib"`), so the caller gets a clonable slug, not just a local path to `cd`
   into. Reword the warn-only banner: drop "Switch to that clone before working it" (an
   instruction to reuse); replace with guidance to clone the reported repo fresh and never `cd`
   into the sibling path (still printed, but relabeled as diagnostic-only — "a local clone
   exists at: `<path>` — do not work from it directly").
2. **`drive/SKILL.md`** Clone-locality guard section: on the warn-only cross-repo exit code,
   direct the caller to clone the reported slug fresh into `/tmp/T<id>-<slug>-hub` (same
   `trap 'rm -rf' EXIT` pattern as Phase 1.5's `$TARGET`), and treat that ephemeral clone as
   `$HUB` for the remainder of the run (claim PR, design PR, journal-move). When the task has no
   separately declared `Target repo:` (the common case — implementation lands in the same repo
   as the task file), `$TARGET` = `$HUB`; Phase 1.5's own dispatch is then a no-op (already
   cloned). This unifies the two "task isn't in the repo I started in" cases (declared
   `Target repo:` vs. bare cross-hub task) under one ephemeral-clone rule instead of two
   diverging behaviors.
3. Leave `DRIVE_STRICT_CLONE=1` (hard-refuse) behavior unchanged — an unattended loop that
   refuses cross-repo entirely doesn't need the ephemeral-clone path at all.

### Alternatives considered and rejected

- **Leave the guard as warn-only advisory text, rely on the human to know not to `cd`** —
  rejected: this is exactly what just failed. The banner's own wording pointed at the reuse
  path; advisory phrasing isn't enough when the literal instruction says the wrong thing.
- **Hard-refuse (`DRIVE_STRICT_CLONE=1` always) instead of ephemeral-clone** — rejected: that
  just blocks the explicit-id path entirely for any cross-hub task, which is a real and common
  shape (this session's own trigger case). An ephemeral clone lets the work proceed safely
  instead of refusing it.

## Test plan

- [x] New `tests/taskid_in_this_repo.bats` (6 cases): present-here, closed-here, cross-repo
      warn-only banner text, strict-refuse, `in-this-repo--sibling-slug` resolution, and its
      ambiguity no-op — all green (`bats tests/taskid_in_this_repo.bats`)
- [x] Existing `in-this-repo`-adjacent coverage (`tests/taskid_url.bats`,
      `tests/taskid_check_orphaned_refs.bats`, 30 cases) still passes unchanged
- [x] `shellcheck _taskid/in-this-repo.sh` clean
- [x] `drive/SKILL.md`'s clone-locality guard section reads correctly end-to-end (manual review
      — this is a docs/process change, no executable path to test beyond the shell script)

## Done criteria

- [x] `_taskid/in-this-repo.sh` prints a clonable slug for the cross-repo case and no longer
      instructs `cd`-ing into the sibling clone — `in-this-repo--sibling-slug()` added
      (`_taskid/in-this-repo.sh`), banner reworded — `tests/taskid_in_this_repo.bats` test 3
- [x] `drive/SKILL.md`'s Clone-locality guard section documents the ephemeral-clone flow
      (mirroring Phase 1.5), reconciling it with the 2026-05-13 "own clone" decision —
      `drive/SKILL.md` Clone-locality guard section, manual review

## Root cause

- `_taskid/in-this-repo.sh` was added under `T20260626-298293` (per its own header comment) to
  fix a real bug: working a cross-hub task from the wrong clone takes the claim against the
  wrong `dev/` tree (`_taskid/in-this-repo.sh:5-9`). Its fix was a **detector + warning**, not a
  clone strategy — `taskid-in-this-repo()` (`_taskid/in-this-repo.sh:66-101`) prints "Switch to
  that clone before working it" (line ~93) and `in-this-repo--sibling-path()`
  (`_taskid/in-this-repo.sh:46-63`) resolves the sibling's **local filesystem path**, which is
  only useful for `cd`-ing into it.
- This was an oversight, not a deliberate re-decision: `T20260626-298293` shipped over a month
  after `T20260513-403409`/`T20260513-422869` (2026-05-13/14) established "own clone, always" as
  the reason the `_claims` machinery could be deleted entirely
  (`build-pipeline-repo/dev/JOURNAL/2026-05-14-T20260513-422869-remove-claims-machinery.md:6,20,83`).
  Nothing in `T20260626-298293`'s own design discusses or overrides that decision — the guard
  just didn't route through the "own clone" lens Phase 1.5 (`drive/SKILL.md` §Phase 1.5) already
  encoded for the *declared* cross-repo case.
- Net effect: two competing conventions ship side by side today — Phase 1.5 (ephemeral clone,
  correct) and the clone-locality guard (existing clone, wrong) — depending only on whether the
  task happens to carry a `Target repo:` marker.

## Repo file references

| File | Change |
|---|---|
| `_taskid/in-this-repo.sh` | Add `in-this-repo--sibling-slug()`; reword the warn-only banner off "switch to that clone" |
| `drive/SKILL.md` | Clone-locality guard section: document the ephemeral-clone flow on the warn-only cross-repo exit code |

## Closed (2026-09-28)

Shipped in this PR (docs+script, no separate implementation PR needed — the design was written
directly into this file and approved in-conversation before coding, per Phase 2 "when to skip
the design PR").

- `_taskid/in-this-repo.sh`: added `in-this-repo--sibling-slug()`, reworded the cross-repo banner
  off "switch to that clone before working it," and relabeled `in-this-repo--sibling-path()`'s
  output as diagnostic-only.
- `drive/SKILL.md`'s Clone-locality guard section rewritten to route the warn-only cross-repo
  case through an ephemeral clone (mirroring Phase 1.5), instead of pointing at an existing
  sibling clone.
- New `tests/taskid_in_this_repo.bats` (8 cases after an independent-review round added two —
  the empty-slug fallback banner and a true `>1`-sibling ambiguity case — all green); existing
  adjacent bats suites unaffected; `shellcheck` clean.
- Independent review (PR #159) flagged: the banner said "clone it fresh" even when no slug
  resolved (fixed — now prints a manual-lookup fallback line instead of a bare "clone it fresh"
  with nothing to clone); a test asserting ambiguity only covered the 0-match case, not the
  `>1`-match case its name claimed (fixed — added the missing fixture); a tautological OR
  assertion in one test (fixed — direct string match). All addressed on the same branch before
  merge.
- **Not done in this task**: retrofitting `/claim`, `/stage`, or any other pick-by-id skill that
  also calls `in-this-repo.sh` — they inherit the reworded banner text automatically (same
  script), but none were audited for their own prose guidance repeating the old "cd" framing.
  Worth a follow-up grep if this pattern shows up elsewhere.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote `tests/taskid_in_this_repo.bats`
  first (confirmed red: 3 failures against the unmodified script), then implemented
  `in-this-repo--sibling-slug()` + the banner rewording until green.
- Verification (`superpowers:verification-before-completion`): yes — full bats run (this file's
  6 cases + the 30 adjacent `taskid_url.bats`/`taskid_check_orphaned_refs.bats` cases) and
  `shellcheck` before treating the change as complete.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck, first
  implementation attempt went green.
- Receiving code review (`superpowers:receiving-code-review`): yes — `/address-pr`'s independent
  review (PR #159) surfaced 3 real findings (see Closed section above); steelmanned each, agreed
  all three, fixed all three on the same branch (no pushback needed — the findings were correct).
