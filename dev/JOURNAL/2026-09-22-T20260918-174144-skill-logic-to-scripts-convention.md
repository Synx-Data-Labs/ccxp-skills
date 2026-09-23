---
status: Done
estimation: 1h
source: this conversation, 2026-09-18
related: T20260914-359646
claimed_by:
claimed_role:
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

- [x] Manual: re-read the new `§9` section standalone — confirms it states
      the rule, the prose/script boundary, the validation gate, and the
      worked-example citation, matching this Solution section exactly
      (`skill-conventions/SKILL.md:68-76`).
- [x] `repo-conventions/scripts/lint_paragraphs.py --changed` — "no long
      paragraphs found".
- [x] CI (`Markdown Lint`, `lint-tasks`, `bats`, `sync-tasks`) green on PR #96.

## Done criteria

- [x] New `§9` convention (rule + prose-stays boundary + validation gate) inserted at `skill-conventions/SKILL.md:68` (heading), before `## Important Notes` — manual re-read test-plan item above.
- [x] `§9` cites the worked example at `dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md:12` (the task's own H1 title) — grep check in the implementation PR diff.
- [x] `§1`–`§8` numbering unchanged (`skill-conventions/SKILL.md:18` through `:66` untouched, i.e. §8's heading *and* body bullets) — diff review test-plan item above.

## Closed (2026-09-22)

- Shipped in **PR #96** (`t20260918-174144-impl`) — design PR #95 merged
  first, this PR carried the `skill-conventions/SKILL.md` §9 addition plus
  this journal move.
- All three Done criteria met (see checked boxes above, each with a
  `file:line` anchor); design-score gate passed at 88/100 (threshold 70)
  on the merged design (`dev/TODO/` copy, prior to this move).
- An independent review of PR #96 caught one real gap before merge: the
  task file had `status: Done` and all criteria ticked but was still
  sitting in `dev/TODO/` with no journal move — a stale assumption on
  this session's part, since `/drive`'s "always journal-move immediately"
  convention (T20260914-422854) superseded the old deferred-to-Friday
  default sometime during this same session, after this session had
  already loaded the older skill text at conversation start. Fixed by
  this `git mv` + this section, following the order-of-operations guard
  (move first, then edit at the new path).
- Also worth recording: this session hit a genuine clone-locality
  collision mid-task. This session's *first* claim attempt on this task
  (PR #92's original commit, since superseded) ran from the shared
  primary clone `/home/rocky/ccxp-skills` and so carried that clone's
  identity, `cc1-9a4074da:94a83ff0e786a885`. A concurrent session was
  *also* running from that same `/home/rocky/ccxp-skills` directory (same
  machine, same path — hence the identical identity string; confirmed
  independently as the real claimant-id on `T20260918-404944`'s own task
  file), and its `release-others` (while claiming T20260918-404944) wiped
  this session's claim on this task once its PR #93 merged, before this
  task's own claim PR (#92) could land. Recovered by cloning to an
  isolated path, `/tmp/ccxp-skills-t20260918-174144-fix` — a *different*
  path hash, `69cec4c3ae5bb8b4`, which is why this file's own
  `claimed_by` history (now cleared) no longer matches the identity
  that was actually involved in the collision — and driving the rest of
  this task from there. No data was lost, but the two-live-sessions-in-
  one-directory condition itself is a process anomaly worth a human
  look, not something this task's scope covers fixing.
- No follow-up tasks filed for this task's own scope — it shipped exactly
  what was asked. (The clone-collision anomaly above is flagged for the
  human/orchestrator, not filed as a new `dev/TODO/` task, since it's an
  environment/orchestration condition, not a bug in this repo's code.)

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class change (a
  single prose section added to `skill-conventions/SKILL.md`, no
  executable code).
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate run twice (pre- and post- line-citation fix, 88/100
  both times), `lint_paragraphs.py --changed` clean, `doc-impact.sh`
  clean, manual re-read of the merged §9 section against the design's
  Solution section, and this close's own order-of-operations guard
  self-verified via `git show --stat` (see Test plan / this section).
- Systematic debugging (`superpowers:systematic-debugging`): no — no
  stuck-for-2-attempts test failure; the clone-collision recovery was a
  git/process issue resolved by isolating into a fresh clone, not a
  hypothesis-driven debugging case.
- Receiving code review (`superpowers:receiving-code-review`): yes —
  independent review agent dispatched on both the design PR (#95, 2 real
  line-citation findings, both fixed, 0 pushback) and the implementation
  PR (#96, 1 real finding — the missing journal-move, fixed as this
  section — 0 pushback).
