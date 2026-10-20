---
status: Done
estimation: 1
source: synxdb-support#30 triage, 2026-10-19 — triaged/accepted with no comment linking it to its tracking task, maintainer had to ask for and manually trigger that comment afterward
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261019-181127: `triage` has no tracking-link comment requirement, unlike `block`/`needs-upstream`

## TLDR

- **Type**: feature
- **Problem**: `customer-support`'s `triage` subcommand leaves no trace
  linking a `synxdb-support` issue back to the internal tracking task filed
  for it — unlike `block`/`needs-upstream`, which at least *document* a
  required comment (`customer-support/SKILL.md:37-38`).
- **Solution**: mirror the `block`/`needs-upstream` convention — add a
  `triage` note to `SKILL.md`, plus an opt-in `--task <ref>` flag on
  `transition.sh triage` that posts the tracking-link comment itself so it
  isn't left purely to the caller's memory. Stay at convention level; do
  **not** promote any of the three to a hard gate (separate, bigger
  decision — see Solution's alternatives-rejected).

## Problem

- `customer-support/SKILL.md:30` documents `triage` -> `accepted` with no
  comment note, while `block` (`SKILL.md:37`) and `needs-upstream`
  (`SKILL.md:38`) explicitly document a required comment.
- `customer-support/scripts/transition.sh:55-60` — `triage` falls into the
  generic `triage|start|request-confirm` case: resolve current label, ask
  `state_machine.sh` for next, `cs-labels-apply`. No comment argument, no
  gate call, nothing issue-comment-shaped.
- **Correction to the assumed mechanism** (this write-up was commissioned
  expecting `block`/`needs-upstream` to be code-gated for their comment;
  they are not). `transition.sh:130-139` shows `block`/`unblock`/
  `needs-upstream` all call `cs-labels-toggle` directly — the same shape as
  `triage`/`start`/`request-confirm`. No `comment_gate.sh`, no `--comment`
  argument exists anywhere in this skill. The "requirement" for
  `block`/`needs-upstream` is a documented convention the calling agent is
  trusted to follow (`SKILL.md:66`'s inline note: "post the explanatory
  comment yourself, via gh issue comment — never skip it"), not a
  structurally-enforced gate like `deliver`'s evidence gate or `accept`'s
  identity gate.
- **Impact — real instance**: `synxdb-support#30` was triaged/accepted with
  no comment linking it to its tracking task `T20261016-412473` (filed in
  `synxdb-build-pipeline`'s `dev/TODO/`) — the maintainer had to separately
  ask for, and manually trigger, that comment after the fact.
- `triage`'s gap is therefore a **documentation omission** (no equivalent
  instruction exists for it), not a divergent code path from an
  already-enforced sibling.

## Context

- Sibling skill design: `T20261012-373882` (`customer-support/SKILL.md`'s
  own header) defines the full `triage -> accepted -> in-progress ->
  delivered -> (closed)` lifecycle plus the `blocked`/`needs-upstream`
  stackable modifiers.
- `transition.sh` (`customer-support/scripts/transition.sh:1-150`) is the
  single enforced entrypoint for every subcommand; `deliver` and `accept`
  are the only two with a *real* code gate (`deliver_gate.sh`,
  `accept_gate.sh`), wired in before the label write.
- `tests/customer_support_transition.bats` already covers every subcommand
  with the `CS_GH` dependency-injection stub pattern (`_stub_gh`,
  `gh-calls.log` call-order assertions) — the pattern this task's new tests
  reuse.

## Solution

- **SKILL.md note** (mirrors `block`'s wording pattern,
  `customer-support/SKILL.md:37-38`): add a `triage` row/note — "if this
  triage is prompted by filing an internal tracking task, post a
  tracking-link comment (`Tracked internally as <repo>#T<id>`)
  before/alongside calling `transition.sh triage` — never skip it."
- **Opt-in `--task <ref>` flag on `transition.sh triage`**: when given,
  posts a standardized `gh issue comment` tracking-link message via
  `cs-gh` (the existing DI seam in `labels.sh`) immediately before the
  existing `cs-labels-apply` call, so the comment and the `accepted` label
  land together. Plain `transition.sh triage <repo> <issue>` (no `--task`)
  is byte-for-byte unchanged — additive, not a new gate.
- **Alternatives rejected**:
  - *Hard-gate `triage` on a tracking comment* (reject the transition
    without one, like `deliver`/`accept`'s real gates) — rejected as
    out-of-scope scope-creep: hard-gating only `triage` while its two
    documented siblings (`block`/`needs-upstream`) stay soft would be an
    inconsistent asymmetry introduced as a side effect of a small UX fix.
    A real hard gate needs its own `comment_gate.sh` (mirroring
    `deliver_gate.sh`/`accept_gate.sh`) applied consistently across
    `triage`/`block`/`needs-upstream` at once — a separate, bigger design
    decision, not bundled here.
  - *Mandatory (non-optional) `--task`* — rejected: `triage` is also used
    for issues that don't need an internal tracking task (triaged-and-fixed
    directly, no cross-repo task filed), so making the flag required would
    break that path for no corresponding benefit.

## Test plan

- [x] Bats test: `transition.sh triage <repo> <issue> --task <ref>` posts
  a `gh issue comment` containing `<ref>` **before** the label moves from
  `triage` to `accepted` — `tests/customer_support_transition.bats`
  (`"triage --task: posts a tracking-link comment before the label moves
  (T20261019-181127)"`), verified RED then GREEN per
  `superpowers:test-driven-development`.
- [x] Bats test: `transition.sh triage <repo> <issue>` with no `--task` is
  byte-for-byte unchanged from current behavior (no comment posted, label
  still moves) — pre-existing test `"triage: accepted label applied via
  the single entrypoint"` still passes verbatim, confirming the fix is
  additive, not a new hard gate.
- [x] Full existing `tests/customer_support_*.bats` suite still green — 70/70
  passing locally (no regression on `start`/`deliver`/`accept`/`reject`/
  `block`/`unblock`/`needs-upstream`).
- [ ] CI's `bats` GitHub Actions job passes on the implementation PR
  (post-merge/CI item).
- [x] Doc lint on the updated `SKILL.md`: `_docs/lint-docs.sh
  customer-support/SKILL.md` and `repo-conventions/scripts/lint_paragraphs.py
  --changed customer-support/SKILL.md` both pass locally.
- [x] `skill-conventions/scripts/skill_score.py --check
  dev/quality/skill-scores.json` stays at/above baseline (98) after the
  `SKILL.md` edit — verified locally (had to trim the added prose once to
  stay under the size-score byte threshold).

## Done criteria

- [x] `customer-support/SKILL.md` documents the `triage` tracking-link
  convention, same pattern as `block`/`needs-upstream` —
  `customer-support/SKILL.md:30` (workflow table row) + `:60` (usage
  example).
- [x] `transition.sh triage ... --task <ref>` posts the tracking-link
  comment before the label write — `customer-support/scripts/transition.sh`
  (the `triage|start|request-confirm` case) + new bats test in
  `tests/customer_support_transition.bats` (`"triage --task: posts a
  tracking-link comment before the label moves (T20261019-181127)"`).
- [x] `transition.sh triage <repo> <issue>` (no `--task`) is unchanged —
  existing bats test `"triage: accepted label applied via the single
  entrypoint"` in `tests/customer_support_transition.bats` still passes
  verbatim.
- [x] `bats tests/customer_support_transition.bats` green locally (11/11);
  CI confirmation is the one remaining post-merge/CI test-plan item above.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `customer-support/SKILL.md` | `28-39`, `58-69` | workflow table + per-subcommand notes — add the `triage` tracking-link convention |
| `customer-support/scripts/transition.sh` | `54-60` | `triage` case — add optional `--task <ref>` parsing + comment post before `cs-labels-apply` |
| `customer-support/scripts/labels.sh` | `14-21` | `cs-gh` DI seam — reused to post the comment, no change needed |
| `tests/customer_support_transition.bats` | `36-43` | existing `triage` test (must stay green unchanged) + new `--task` test |

## Root cause

- Not a bug — a documentation/feature gap. The asymmetry exists because
  `block`/`needs-upstream` had their comment convention written down when
  `customer-support/SKILL.md` was authored (`T20261012-373882`) but
  `triage` never got the equivalent note — an oversight at design time, not
  a deliberate decision (no comment or commit explains omitting it).

## Closed (2026-10-19)

- Shipped in **PR #TBD-filled-below** (`customer-support/SKILL.md`,
  `customer-support/scripts/transition.sh`, `tests/customer_support_transition.bats`).
- All Done criteria met: `SKILL.md` documents the `triage` tracking-link
  convention, `transition.sh triage --task <ref>` posts the comment before
  the label write, the no-`--task` path is byte-for-byte unchanged, and
  `tests/customer_support_*.bats` is 70/70 green locally.
- One remaining external item: CI's `bats` job green on the PR (the
  authoritative full-suite confirmation) — ticked once CI passes.
- No follow-up tasks filed — the explicit out-of-scope item (promoting
  `triage`/`block`/`needs-upstream` to a real hard gate) is intentionally
  left as a future, separate, bigger decision per this doc's own
  alternatives-rejected, not a tracked task.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the
  `"triage --task"` bats test first, watched it fail for the right reason
  (missing `--task` handling), then implemented the minimal `transition.sh`
  change to turn it green, then ran the full `customer_support_*.bats`
  suite (70/70) as the refactor-safety check.
- Verification (`superpowers:verification-before-completion`): yes — ran
  `design-score`, `_docs/lint-docs.sh`, `lint_paragraphs.py`,
  `test_skill_quality.py`, and the `skill_score.py --check` ratchet before
  calling the implementation complete; the ratchet check caught a real
  regression (see Systematic debugging below).
- Systematic debugging (`superpowers:systematic-debugging`): yes — the
  `SKILL.md` edit tripped the `skill_score.py` size-score ratchet (98 ->
  97). Root-caused by computing the exact byte threshold
  (`SIZE_FULL_BYTES`/`SIZE_ZERO_BYTES` in `skill-conventions/scripts/skill_score.py`)
  rather than guessing, then trimming prose iteratively until back at
  98/100.
- Receiving code review (`superpowers:receiving-code-review`): yes — the
  design PR's independent review (`/address-pr` #366) found 3 test-plan
  checkboxes falsely marked `[x]` for not-yet-implemented behavior; fixed
  in a follow-up commit rather than arguing the finding away.
