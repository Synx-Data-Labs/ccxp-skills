---
status: Design
estimation: 1h
source: PR #53 review comments (ccxp-skills), 2026-09-22 — surfaced by independent review during /address-pr's loop on autopilot's dispatch-redesign PR
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260922-195629: Clarify whether `/autopilot`'s `WAITING` outcome is ever reachable from a bare `/drive` dispatch

## Problem

- **Type**: research
- `autopilot/SKILL.md` Phase 4's Progress bullet (and, after [PR #53](https://github.com/Synx-Data-Labs/ccxp-skills/pull/53), Phase 3's
  dispatch-prompt format too) both describe a `WAITING` outcome — "the cycle
  ended in a wait state that resolves without further `/drive` action (CI
  still running, a review genuinely still pending)".
- `drive/SKILL.md` explicitly documents the opposite policy: `/drive` waits
  out CI *internally* rather than returning mid-wait — "Wait, don't switch...
  just wait" (`drive/SKILL.md:652`) and "idle until the background signal
  arrives" (`drive/SKILL.md:431`).
- Given that, it's unclear whether a bare `/drive` call (as `/autopilot`
  Phase 3 now dispatches it, per [PR #53](https://github.com/Synx-Data-Labs/ccxp-skills/pull/53)) can ever legitimately terminate in a
  genuine `WAITING` state, or whether `WAITING`'s only real-world referent is
  `/address-pr`'s wait-for-approval merge tier (a maintainer-approval gate
  `/drive` can't resolve by waiting further, since only a human can clear
  it) — a case that's about test-plan/merge-tier state, not CI.
- This ambiguity predates [PR #53](https://github.com/Synx-Data-Labs/ccxp-skills/pull/53): the exact same `WAITING`/wait-state wording
  already existed in `autopilot/SKILL.md` Phase 4's Progress bullet before
  that PR's dispatch redesign touched anything. The redesign only changed
  *who observes and reports* the cycle's outcome (a dispatched sub-agent vs.
  the main session witnessing it directly) — not *when* `WAITING` legitimately
  applies.
- "Done" looks like: either (a) confirm `WAITING` maps only to the
  wait-for-approval case and tighten `autopilot/SKILL.md`'s wording/examples
  accordingly (the current "CI still running on PR #<n>" example may be
  actively misleading), or (b) find a real path where a bare `/drive` call
  does return mid-CI-wait and document that instead.

## Context

- Full review exchange: <https://github.com/Synx-Data-Labs/ccxp-skills/pull/53>
  (PR comments) — see the "deeper question" pushback in the second review
  round's response.
- Related: `address-pr/SKILL.md` §3's "Follow the merge policy... tiered
  merge... or notify for wait-for-approval tier" — the likely actual source
  of a legitimate `WAITING` outcome, worth tracing precisely.
