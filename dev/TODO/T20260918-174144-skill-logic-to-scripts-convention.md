---
status: Design
estimation: 1h
source: this conversation, 2026-09-18
related: T20260914-359646
claimed_by: cc1-9a4074da:69cec4c3ae5bb8b4
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-174144: Document convention: move deterministic skill logic into bundled scripts

## TLDR

- **Type**: chore
- **Problem**: `skill-conventions/SKILL.md` has no documented rule for
  "port a deterministic SKILL.md workflow step into a bundled script" —
  `T20260914-359646` already did exactly this for `/todo`, but as a one-off,
  not a convention future skill authors know to follow.
- **Solution**: add a new numbered convention (`§9`, appended after the
  existing `§8 Cross-references` so `§1`/`§4`/`§5` citations elsewhere stay
  valid) stating the rule plus a required behavior-parity validation gate,
  citing `T20260914-359646` as the worked example.

## Problem

- `skill-conventions/SKILL.md` has no rule for this pattern (checked: no
  mention of "bundle"/"token-free"/"token-optim" in the file).
- `T20260914-359646` (`dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md`)
  already applied the exact pattern to `/todo next` and `/todo list` —
  porting deterministic queue-walk/table logic into sourceable scripts
  (`todo/scripts/{_lib,todo-list,todo-next}.sh`) so neither costs an LLM
  turn — but it's a one-off task, not a documented convention.
- Maintainer wants this codified in `skill-conventions/SKILL.md`: when a
  SKILL.md workflow step is deterministic/mechanical (no judgment calls
  involved), it belongs in a bundled script the skill invokes — not prose
  the LLM re-derives on every run — to save tokens.
- Maintainer also wants a required validation step: any such conversion must
  prove behavior parity (e.g. BATS tests comparing the script's output
  against the skill's own prior real invocations) before the SKILL.md is
  switched over to invoke the script — mirroring `T20260914-359646`'s own
  test-plan pattern.

## Context

- `skill-conventions/SKILL.md`'s `## Conventions` section is a numbered list,
  `§1`–`§8`; `§4` ("Shared libraries") and `§5` ("Testing") are already cited
  by filename+number elsewhere (`dev/JOURNAL/2026-09-22-T20260914-359646-*.md:68`,
  `dev/JOURNAL/2026-09-19-T20260917-151758-*.md:95`) — per `§6`'s own "phase
  numbers as stable anchors" rule, the new convention must not renumber
  `§1`–`§8`; it's appended as `§9`.
- `T20260914-359646`'s own `## Context` section already drew the line this
  convention needs to state generally: deterministic reads/transforms
  (`list`, `next`) port to a script; judgment calls (`sweep`'s blocker-order
  enforcement, Park recommendations) stay in prose. The new convention
  generalizes that split, it doesn't invent a new one.
- `repo-conventions/scripts/lint_tasks.py` and `design-score/scripts/score.sh`
  predate `T20260914-359646` as examples of the same shape (deterministic
  skill logic in a bundled, testable script) but were never cited as the
  convention's worked example in any SKILL.md — `T20260914-359646` is the
  better example because its own JOURNAL entry documents the parity-test
  approach explicitly (BATS cases cross-checked against a real
  `dev/TODO/queue.md`), which is the part this task most needs to point at.

## Solution

- Append a new `### 9. Deterministic logic → bundled scripts` convention to
  `skill-conventions/SKILL.md`'s `## Conventions` section (after the existing
  `§8 Cross-references`, before `## Important Notes`), stating:
  - **When to extract**: a SKILL.md workflow step that is fully
    deterministic/mechanical (a parse, a lookup, a formatted report — no
    judgment calls) belongs in a bundled, sourceable script under
    `<skill>/scripts/`, invoked by the workflow instead of re-derived in
    prose the LLM re-executes every run. Reuse `§4`'s shared-library rule
    when 2+ skills need the same helper.
  - **What stays in prose**: logic that makes a real judgment call (a Park
    recommendation, a blocker-order decision) — porting a *decision* isn't
    this convention's scope, only a deterministic read/transform is.
  - **Required validation gate before switchover**: add tests (BATS/unit,
    per `§5`) that prove behavior parity — the script's output matches the
    skill's own prior real invocations (or a hand-verified fixture) — before
    the SKILL.md workflow section is rewritten to invoke the script instead
    of the prose it replaces. This is `§5`'s existing test requirement made
    explicit as a *port-safety* gate, not just "has tests."
  - **Worked example**: `T20260914-359646` — cites
    `dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md`
    for the before/after and the parity-test approach.
- **Alternatives considered and rejected**:
  - *Insert the new convention between `§5` and `§6`* (thematically closer to
    Testing) — rejected: would renumber `§6`/`§7`/`§8`, and while only `§4`/
    `§5`/`§1` have *confirmed* external citations today, appending avoids the
    risk entirely at zero cost (this is a reference doc, not a linear
    narrative — position doesn't carry meaning beyond the number itself).
  - *Fold this into `§4` (Shared libraries) as a sub-bullet instead of a new
    numbered convention* — rejected: `§4` is about *where* shared code lives
    (extract when 2+ skills need it); this convention is about *whether*
    workflow logic should be code at all (even for a single skill, per
    `T20260914-359646`'s single-skill `todo/scripts/`) — a distinct question
    that deserves its own anchor for future citation.

## Test plan

- [ ] Manual: re-read the new `§9` section standalone — confirm it states
      the rule, the prose/script boundary, the validation gate, and the
      worked-example citation, matching this Solution section exactly.
- [ ] `repo-conventions/scripts/lint_paragraphs.py --changed` (bullets, not
      paragraphs, per the design-doc template's Format discipline) — non-blocking
      nudge, run and address any hit.
- [ ] CI (`Markdown Lint`, `lint-tasks`) green on the implementation PR.

## Done criteria

- [ ] New `§9` convention (rule + prose-stays boundary + validation gate) inserted at `skill-conventions/SKILL.md:67`, before `## Important Notes` — manual re-read test-plan item above.
- [ ] `§9` cites the worked example at `dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md:1` — grep check in the implementation PR diff.
- [ ] `§1`–`§8` numbering unchanged (`skill-conventions/SKILL.md:18` through `:61` untouched) — diff review test-plan item above.
