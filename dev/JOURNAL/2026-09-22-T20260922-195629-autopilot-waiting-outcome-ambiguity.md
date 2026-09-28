---
status: Done
estimation: 1h
source: PR #53 review comments (ccxp-skills), 2026-09-22 — surfaced by independent review during /address-pr's loop on autopilot's dispatch-redesign PR
related: PR #53 (autopilot dispatch redesign), T20260719-204917 (--dispatch-blockers precedent this PR's dispatch pattern mirrors)
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260922-195629: Clarify whether `/autopilot`'s `WAITING` outcome is ever reachable from a bare `/drive` dispatch

## TLDR

- **Type**: research
- **Problem**: `autopilot/SKILL.md` describes a `WAITING` outcome with two examples — "CI still running on PR #\<n\>" and "a review genuinely still pending" — but `drive/SKILL.md` explicitly waits out CI *internally* and never returns mid-CI-wait, so one of those two examples cannot actually occur.
- **Solution**: option (a) — `WAITING`'s only real referent is `/address-pr`'s wait-for-approval merge tier (a formal GitHub review-approval gate that only a human can clear); the "CI still running" example is wrong and gets removed. Tighten `autopilot/SKILL.md`'s wording/examples accordingly; no change needed to `drive/SKILL.md` or `address-pr/SKILL.md` — their behavior is already correct, only `autopilot/SKILL.md`'s description of it was imprecise.

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

## Solution

- **Traced every path that could plausibly end a bare `/drive` dispatch mid-wait** (verified against the live files, not recollection — see file:line citations):
  - **CI / pipeline wait**: `drive/SKILL.md:426` ("wait in the background... idle until the background signal arrives") and `drive/SKILL.md:636` ("Wait, don't switch... just wait") are both unconditional — `/drive` never returns control while CI/a build is running, dispatched or not. **This path cannot produce a `WAITING` report.** The "CI still running on PR #\<n\>" example in `autopilot/SKILL.md:69` is therefore wrong — it names something `/drive` structurally never does.
  - **§2.e unverifiable manual test-plan item** (`address-pr/SKILL.md`): this happens *before* the hard gate passes, so `/address-pr` never reaches its own §3 merge/notify step. `autopilot/SKILL.md:81` already classifies this as **Stuck**, not `WAITING` (it's one of the three named `stopped-and-reported without merging` sub-cases, and is explicitly silent — no Slack of its own).
  - **§3 wait-for-approval merge tier** (`address-pr/SKILL.md:309`): reached only *after* the hard gate has passed (CI green, Claude Code review addressed, test plan verified). For a repo whose `dev/guidelines.md` declares the wait-for-approval tier (`repo-conventions/SKILL.md:163-165` — `mode.sh team` with `required_approving_review_count` raised above 0), `/address-pr` posts a "ready to merge" Slack notification (§3 step 1) and stops without merging — there is no loop in `address-pr/SKILL.md` that waits for the approval and then completes the merge within the same invocation. This is **not** silent (it does Slack, unlike the §2.e case above) and is **not** one of the three named Stuck sub-cases. It resolves *without further `/drive` action* in exactly the sense `autopilot/SKILL.md:79` describes: either the human merges directly on GitHub, or the *next* `/drive` cycle's Phase 0 (`/address-pr` auto-pick, which drains open PRs before picking new work) re-checks and completes the merge once approved — no design decision, fix, or escalation is needed from `/drive` itself. **This is the one real, structural path to a genuine `WAITING` outcome.**
- **Verified this repo (ccxp-skills) is on the auto-merge tier today** — PR #107 and #108 both merged this cycle with `reviewDecision: ""` and no human approval step, confirming the wait-for-approval tier is a *per-repo policy choice* (via `repo-conventions/SKILL.md`'s `mode.sh`), not something every consumer repo exercises. The ambiguity is about the general skill docs, not this repo's current settings.
- **Chosen resolution: option (a)** from the task's own framing — confirm `WAITING` maps only to the wait-for-approval case, and correct `autopilot/SKILL.md`'s wording:
  1. `autopilot/SKILL.md:69` (dispatch-prompt `WAITING:` example line) — drop "CI still running on PR #\<n\>"; keep only the wait-for-approval-shaped example, and make explicit that it means a *formal GitHub review approval*, not the Claude Code review comment (which is already addressed inside the CI/review loop before the hard gate even passes).
  2. `autopilot/SKILL.md:79` (Progress bucket's wait-state parenthetical) — same fix: replace "(CI still running, a review genuinely still pending)" with a single, precise reference to the wait-for-approval merge tier, citing `address-pr/SKILL.md` §3 so a future reader can trace it instead of re-litigating this ambiguity.
  3. No change needed to `drive/SKILL.md` or `address-pr/SKILL.md` — both already behave correctly; only `autopilot/SKILL.md`'s *description* of the reachable outcomes was imprecise.
- **Alternative considered and rejected — option (b)** ("find a real path where a bare `/drive` call does return mid-CI-wait and document that instead"): rejected because `drive/SKILL.md`'s CI-wait instruction is unconditional and appears twice (Phase 5 and Important Notes), with no carve-out for a dispatched context. Inventing a new mid-CI-wait return path would be a behavior *change* to `/drive`, not a documentation fix, and nothing in this task's scope (or the PR #53 review thread that raised it) asked for that — the ambiguity is in the docs, not a missing capability.

## Test plan

- [x] Read `drive/SKILL.md` (Phase 5, Important Notes), `address-pr/SKILL.md` (§2.e, §3), `autopilot/SKILL.md` (Phase 3 dispatch template, Phase 4 Progress/Stuck bullets), and `repo-conventions/SKILL.md` (`mode.sh` tier semantics) directly from disk to confirm every citation above (not from a cached/recollected copy — see T20260922-201976).
- [x] Cross-checked against this cycle's own live behavior: PR #107 and PR #108 both cleared CI, got an independent review comment, and merged with `reviewDecision: ""` — confirming this repo runs the auto-merge tier and that `/drive`'s CI-wait (via `Monitor`) never itself ended a turn without a resolved check.
- [x] Post-edit: re-read the two corrected `autopilot/SKILL.md` lines and confirm they no longer mention "CI still running" as a `WAITING` example, and do name the wait-for-approval tier explicitly with a citation to `address-pr/SKILL.md` §3.
- [x] `bash design-score/scripts/score.sh dev/TODO/T20260922-195629-autopilot-waiting-outcome-ambiguity.md --kind docs` cleared the threshold (84/100) before Phase 3 implementation.
- [x] `bash _docs/lint-docs.sh` clean on the edited file(s) (`autopilot/SKILL.md`, this task file).

## Done criteria

- [x] `autopilot/SKILL.md:69` (dispatch-prompt `WAITING:` example) no longer names CI as an example — verified by reading the merged file at that line.
- [x] `autopilot/SKILL.md:79` (Phase 4 Progress-bucket parenthetical) names only the wait-for-approval tier, with a citation to `address-pr/SKILL.md` §3 — verified by reading the merged file at that line.
- [x] No behavior change to `drive/SKILL.md` or `address-pr/SKILL.md` — this task is documentation-only, confirmed by `git diff main...HEAD --stat` showing only `autopilot/SKILL.md` touched (plus this task file's own status bookkeeping).

## Closed (2026-09-22)

- Shipped in **PR #109** (design, design-score 84/100 `--kind docs`, independently
  re-reviewed clean) and the implementation PR that follows it in this same journal
  entry's commit history (`t20260922-195629-impl`).
- All three Done criteria met (checked above): `autopilot/SKILL.md:69` and `:79`
  corrected, no behavior change to `drive/SKILL.md`/`address-pr/SKILL.md`.
- Resolution: option (a) from the task's own framing. `WAITING`'s only real,
  structural referent is `/address-pr`'s wait-for-approval merge tier
  (`address-pr/SKILL.md` §3) — reached only after the hard gate (CI, review,
  test plan) already passed, gated on a human's formal GitHub review approval.
  "CI still running" was never reachable as a `WAITING` example: `drive/SKILL.md`
  waits out CI unconditionally and internally (`drive/SKILL.md:426,636`), and an
  unverifiable manual test-plan item is already classified Stuck
  (`autopilot/SKILL.md:81`), not `WAITING`.
- Independently re-verified twice (design PR #109's review round, and again
  during this close) against the live files — no wrong citation or missed case
  found either time.
- No follow-up tasks filed — the fix is complete and self-contained.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class change (a
  `SKILL.md` wording fix), no code/tests involved.
- Verification (`superpowers:verification-before-completion`): yes — design-score
  gate (84/100) before implementation, `_docs/lint-docs.sh` clean, `git diff
  main...HEAD --stat` scope check, and a full re-read of both edited lines against
  their Done-criteria citations before closing.
- Systematic debugging (`superpowers:systematic-debugging`): no — no stuck-for-
  2-attempts situation; this was a research/tracing task, not a bug.
- Receiving code review (`superpowers:receiving-code-review`): no pushback needed
  — both independent review rounds (design PR #109, claim PR #108) returned a
  clean bill of health with no findings to steelman or contest.
