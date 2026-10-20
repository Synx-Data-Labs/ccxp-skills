---
status: Open
estimation: 1
source: synxdb-support#30 triage, 2026-10-19 — triaged/accepted with no comment linking it to its tracking task, maintainer had to ask for and manually trigger that comment afterward
---

# T20261019-181127: `triage` has no tracking-link comment requirement, unlike `block`/`needs-upstream`

## Problem

- **Type**: feature
- The `customer-support` skill's `triage` subcommand (`triage` -> `accepted`)
  has no comment step at all, so a triage-and-accept leaves no trace linking
  the issue back to whatever internal tracking task was filed for it.
  - `customer-support/SKILL.md:30` documents `triage` -> `accepted` with no
    comment note, while `block` (`SKILL.md:37`) and `needs-upstream`
    (`SKILL.md:38`) explicitly document a required comment.
  - `customer-support/scripts/transition.sh:55-60` — `triage` falls into the
    generic `triage|start|request-confirm` case: resolve current label, ask
    `state_machine.sh` for next, `cs-labels-apply`. No comment argument, no
    gate call, nothing issue-comment-shaped.
- **Correction to the assumed mechanism** (flagging this since the task that
  asked for this write-up guessed differently): `block`/`unblock`/
  `needs-upstream` are **not** code-gated for their comment either.
  `transition.sh:130-139` shows all three call `cs-labels-toggle` directly,
  same shape as `triage`/`start`/`request-confirm` — no `comment_gate.sh`,
  no `--comment` argument exists anywhere in this skill. The "requirement"
  for `block`/`needs-upstream` is a documented convention the calling agent
  is trusted to follow (`SKILL.md:66`'s inline note: "post the explanatory
  comment yourself, via gh issue comment — never skip it"), not a
  structurally-enforced gate like `deliver`'s evidence gate or `accept`'s
  identity gate. `triage`'s gap is therefore a **documentation omission**
  (no equivalent instruction exists for it), not a divergent code path from
  an already-enforced sibling.
- **Real instance**: `synxdb-support#30` was triaged/accepted with no
  comment linking it to its tracking task `T20261016-412473` (filed in
  `synxdb-build-pipeline`'s `dev/TODO/`) — the maintainer had to separately
  ask for, and manually trigger, that comment after the fact.

## Proposed fix

- Mirror the existing `block`/`needs-upstream` convention level (not a new
  hard gate — see the ambiguity flag below): add a `triage` note to
  `customer-support/SKILL.md`'s workflow table/notes, same wording pattern
  as `block`'s, e.g.: "if this triage is prompted by filing an internal
  tracking task, post a tracking-link comment (`Tracked internally as
  <repo>#T<id>`) before/alongside calling `transition.sh triage` — never
  skip it."
- Optionally, extend `transition.sh triage` with an opt-in `--task <ref>`
  argument that posts a standardized `gh issue comment` tracking-link
  message immediately before the existing `cs-labels-apply` call, so the
  comment and the `accepted` label land together instead of relying purely
  on the caller's memory. Keep it optional/backward-compatible — plain
  `transition.sh triage <repo> <issue>` with no `--task` continues to work
  exactly as today.
- **Ambiguity flag**: it's unclear whether the maintainer wants this
  promoted to a real hard gate (reject the transition without a tracking
  ref, like `deliver`/`accept`'s actual gates) or left at the same
  convention-level as `block`/`needs-upstream`. Best guess here is the
  latter — hard-gating only `triage` while its two documented siblings stay
  soft would be an inconsistent asymmetry introduced as a side effect of
  this task, which is out of scope for a small UX fix. If a hard gate is
  wanted, that's a separate, larger design decision (would need a real
  `comment_gate.sh`, mirroring `deliver_gate.sh`/`accept_gate.sh`, applied
  consistently across `triage`/`block`/`needs-upstream` at once).

## Test plan

- Bats test (DI via `CS_GH`, same stub pattern as the existing
  `transition.sh` tests): `transition.sh triage <repo> <issue> --task <ref>`
  posts a `gh issue comment` containing `<ref>` before the label moves from
  `triage` to `accepted`.
- Bats test: `transition.sh triage <repo> <issue>` with no `--task` is
  unchanged from current behavior (no comment posted, label still moves) —
  confirms the fix is additive, not a new hard gate.
- Doc lint on the updated `SKILL.md` (`lint_tasks.py` equivalent —
  `_docs/lint-docs.sh customer-support/SKILL.md` and
  `repo-conventions/scripts/lint_paragraphs.py --changed
  customer-support/SKILL.md`) passes.
- Manual check against the real scenario: triage a fresh test issue with
  `--task T<id>` and confirm the tracking-link comment appears alongside
  the `accepted` label, with no separate manual step required.
