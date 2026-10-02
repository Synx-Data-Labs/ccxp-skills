---
status: Open
scheduled: 2026-10-12
estimation: 2
source: T20260923-292618 survey
related: T20260923-292618
---

# T20261001-995405: Scope a native replacement for the `superpowers:verification-before-completion` hard gate (no ready mattpocock equivalent)

## TLDR

- **Type**: research
- **Problem**: `superpowers:verification-before-completion` is `ccxp-skills`'
  single most heavily-used `superpowers` call site (3 hard-gate sites: `drive`
  Phase 3.6, `drive` Phase 7.0, `address-pr`'s pre-merge pre-gate) — and,
  unlike TDD/systematic-debugging, `mattpocock/skills` has **no** matching
  skill to port.
- **Solution**: this task is scoping only — decide whether to (a) vendor a
  native checklist, (b) keep `superpowers` for this one call site while
  retiring the others, or (c) lean harder on the existing `design-score` /
  `quality-probe` native gates and accept their narrower coverage.

## Problem

- Call sites (confirmed 2026-10-01, current line numbers — drifted from the
  2026-09-23 filing since other edits landed in between):
  - `drive/SKILL.md:365` — Phase 3.6, before opening the PR
  - `drive/SKILL.md:502` — Phase 7.0, final post-merge verification
  - `address-pr/SKILL.md:161` — pre-gate, every `/address-pr` loop iteration,
    before trusting `pre-merge-check.sh`'s verdict
- `mattpocock/skills`' inventory (18 engineering + 7 productivity + 4 misc + 9
  in-progress skills, per T20260914-412750's prior survey) has no skill whose
  description matches "challenge unstated completion assumptions before
  declaring done" — the maintainer's suggested `tdd`/`diagnosing-bugs`/
  `code-review` trio (2026-09-23 conversation) does not cover this call site.
  Confirmed by reading `mattpocock/skills`' `code-review/SKILL.md` directly
  (2026-10-01): it is a **reviewer-side** two-axis (Standards/Spec) diff
  review tool, not a self-verification checklist — it does not substitute
  for `verification-before-completion`'s function despite surface-level
  "review" naming overlap.
- `design-score` (a deterministic Phase 2→3 structural gate on the design
  *doc*) and `quality-probe` (a trailing code-quality scoreboard, record+warn
  not a gate) are both `ccxp-skills`-native already, but neither challenges
  "did I actually verify this is done" the way `verification-before-completion`
  does — they measure different things (doc structure; code-metric drift),
  not completion-assumption gaps.

## Context

- This is the highest-risk remaining `superpowers` dependency precisely
  because it's the most load-bearing and has no drop-in replacement — rushing
  a swap here without a vetted alternative risks silently weakening the
  pre-PR/pre-merge safety net across every task in the suite.
- T20261001-289904 and T20261001-334141 (filed alongside this task, same
  survey) cover the two call sites that DO have ready mattpocock equivalents
  (`tdd`, `diagnosing-bugs`) — this task is deliberately scoped narrower:
  decide the path for the one gate that doesn't.

## Solution

- Survey candidate approaches (do not implement yet):
  1. Vendor a native checklist — the generic "surface untested assumptions,
     missed edge cases, 'it compiles, ships' thinking" content is itself not
     complex; a short native prose checklist inlined into `drive`/`address-pr`
     may be sufficient without needing a dependency at all.
  2. Keep `superpowers:verification-before-completion` specifically for this
     gate while the TDD/debugging swaps proceed independently — partial
     retirement is a legitimate outcome, not a failure of the overall
     retirement effort.
  3. Extend `design-score` or `quality-probe` to cover more of this gate's
     intent — likely the weakest option; both are measurement tools, not
     interactive assumption-challengers, and stretching their scope risks
     muddying what each one is for.
- Recommend (a) or (b) over (c) pending a prototype; write the actual
  decision + rationale into this task's `## Research findings` when picked
  up, then either file an implementation follow-up (if (a)) or close as
  "decided to keep" (if (b)).
- **Alternatives rejected**: none yet — that's this task's job once worked.

## Test plan

- [ ] Candidate approaches (a)/(b)/(c) each evaluated against the 3 call
      sites' actual current wording
- [ ] A decision recorded with rationale

## Done criteria

- [ ] Decision recorded in this task's `## Research findings` /
      `## Closed` section
- [ ] If (a) is chosen: an implementation follow-up task filed
- [ ] If (b) is chosen: no further action needed — `superpowers` dependency
      retained for this one gate, documented as a deliberate choice
