---
status: Coding
estimation: 1d
source: 2026-08-09 conversation — surfaced while /address-pr-ing T20260529-651055, whose
  `task_claim.sh acquire` flow unconditionally flipped its status to `Coding` even though
  the task is IRS paperwork, not code
related: T20260529-651055, T20260827-280088, T20260827-420045
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260809-355059: Rename the `Coding` lifecycle status to a domain-generic term

## TLDR

- **Type**: chore
- **Problem**: the lifecycle `status: Coding` value is a code-flavored misnomer for the many
  non-code tasks this system tracks (legal filings, marketing audits, research write-ups), and
  the literal string is hardcoded across ~7 shared scripts, ~9 bats suites, and 13+ docs — a
  naive rename would also corrupt unrelated proper nouns ("Copilot Coding Agent").
- **Solution**: rename to `In Progress` (zero collisions found; matches the Jira/Linear/GitHub
  Projects/Trello convention). Land as a **dual-accept transition**, not a hard cutover — every
  script that pattern-matches the literal keeps recognizing `Coding` as a legacy-equivalent alias
  while writing `In Progress` going forward — because `ccxp-skills` is a shared sibling repo other
  repos invoke live via `../_session/*.sh`, so a hard cutover would silently break claim tracking
  for any task file anywhere still at the old value the instant this merges.
- **Phasing**: Phase A (this PR) — the coupled script-logic set (`_session`, `_ipm`) that must
  move atomically to keep the claim/reclaim/carry-over invariants consistent, plus its bats
  coverage. Phase B (follow-up PR, same task) — the 13+ prose/docs references, decoupled from
  each other and safe to land separately.

## Problem

- The task-lifecycle `status: Coding` value (`Open → Design → Coding → Review → Done`,
  `lifecycle.md:70`) is a misnomer for the many tasks in this system that aren't code at all —
  legal filings, marketing audits, research write-ups. Concretely: `task_claim.sh acquire` on
  T20260529-651055 (file IRS Form 8822-B) forced `status: Coding` even though the only remaining
  step was printing and mailing a signed form; had to hand-correct it back to `Review` in a
  follow-up PR.
- Not a one-string find/replace — **freshly re-enumerated at pickup (2026-09-25)**, superseding
  the 2026-08-09 inventory below (the task's own note warned it would drift, and it has — the
  real count is larger):
  - **Script logic** (`_session/`, `_ipm/` — now canonical in `ccxp-skills` post-split, see
    Context) hardcodes the literal in case-statements/pattern-matches that must all move
    together or the claim/reclaim/carry-over state machine breaks silently for *either* an
    old-value *or* a new-value task, depending on which script lags:
    - `_session/task_claim.sh:14,235,268,544,584,602` — accepted-status doc comment,
      reclaimable check, `acquire`'s write, `release-others`' revert-to-Open logic
    - `_session/reclaim_sweep.sh:8,80` — the "actively-claimed" check that decides whether a
      stale claim gets released
    - `_session/status.sh:3` — accepted-value doc comment (Project board mirror)
    - `_session/attribution.sh:209,220` — in-flight-by-status detection
    - `_session/_lib.sh:5,144,243` — shared status-categorization comments
    - `_session/claim_gap.sh:2,6,20,54` — claim-gap detector, `Coding`-status enumeration
    - `_ipm/ipm-iteration-drain-check.sh:11,28` — carry-over detection
  - **Bats coverage** asserting the literal (must track the script changes so tests still mean
    what they claim to mean): `tests/task_claim.bats`, `tests/claim_gap.bats`,
    `tests/reclaim_sweep.bats`, `tests/attribution.bats`, `tests/epic-status.bats`,
    `tests/todo-next.bats`, `tests/ipm_iteration_drain_check.bats`, `tests/eta.bats`,
    `tests/task-state.bats` (9 files — verified via `grep -rl Coding tests/*.bats`).
  - **Docs** (Phase B, deferred — see Solution): `lifecycle.md` (canonical definition, line 70,
    82, 88, 148-149), `glossary.md:19,25`, `repo-conventions/templates/{guidelines,task,
    design-doc}.md`, `_session/README.md:17,25,109,122,125`, and 8 `SKILL.md` files
    (`repo-conventions`, `todo`, `ccxp` [13 hits], `drive` [10 hits], `address-pr`, `gcpr`,
    `claim`, `retro`) — verified via `grep -rln Coding --include=SKILL.md .`.
  - **False-positive risk** (must NOT be touched): GitHub's "Copilot Coding Agent"
    (`address-pr/SKILL.md:180`, `address-pr/scripts/pre-merge-check.sh:88,120,144,158`) and an
    unrelated Cloudflare reference-architecture title
    (`cloudflare/references/workers-for-platforms/{README,patterns}.md`).
  - **Existing task files already at the old value in other repos** — the 2026-08-09 snapshot
    (hub-repo: 2, build-pipeline-repo: 8) is **not re-verified this pass**; those repos aren't
    accessible from this clone. *Assumed stale, not re-confirmed* — this is exactly why Phase A
    is dual-accept rather than a hard cutover: correctness here doesn't depend on that count
    being current.

## Context

- **Repo-split context**: `ccxp-skills` split from a private company repo (T20260827-280088);
  this task itself was migrated into `ccxp-skills/dev/TODO/` by T20260827-420045 on 2026-09-14,
  because `_session/`/`_ipm/` — where nearly all of the script-logic work lives — are now
  `ccxp-skills`' own shared libs, not `private-skills-repo`'s. `lifecycle.md`, `glossary.md`, the
  3 templates, and all 8 listed `SKILL.md` files are likewise canonical here now (confirmed:
  `ls lifecycle.md` succeeds at repo root).
- **Live shared-script architecture** (why dual-accept, not a hard cutover): other repos in this
  suite invoke `../_session/*.sh` and `../_ipm/*.sh` **directly, by relative path**, not via a
  vendored copy. A merge to `ccxp-skills` `main` changes every consumer repo's behavior the
  moment it lands — there is no separate rollout window per consumer repo for script logic (only
  for the docs each consumer repo owns describing the flow).

## Root cause

- The `Coding` status value is a deliberate initial design choice, not an oversight — it fit a
  repo that was originally code-only. This repo's own git history is squashed at
  `890c1ce` ("Initial public release", 2026-09-13) since `ccxp-skills` was split from a private
  predecessor repo (per this repo's own `CLAUDE.md`); the literal's true origin predates that
  squash and isn't reconstructable from this clone's history — **assumed**, not verified beyond
  the squash point.
- It became a misnomer once the task system started tracking non-code work (legal filings,
  marketing audits, research) — first surfaced as a concrete bug on 2026-08-09
  (T20260529-651055: `task_claim.sh acquire` forced `status: Coding` on an IRS-paperwork task).

## Repo file references

| File | Lines | Purpose | Phase |
|---|---|---|---|
| `_session/task_claim.sh` | 14, 235, 268, 544, 584, 602 | Claim/acquire/release-others — the core state machine | A |
| `_session/reclaim_sweep.sh` | 8, 80 | Stale-claim release — "actively-claimed" check | A |
| `_session/status.sh` | 3 | Accepted-value doc comment (Project board mirror) | A |
| `_session/attribution.sh` | 209, 220 | In-flight-by-status detection | A |
| `_session/_lib.sh` | 5, 144, 243 | Shared status-categorization comments | A |
| `_session/claim_gap.sh` | 2, 6, 20, 54 | Claim-gap detector | A |
| `_ipm/ipm-iteration-drain-check.sh` | 11, 28 | IPM carry-over detection | A |
| `ccxp/scripts/epic-status.sh` | 299, 315 | `_epic_status_bucket`/`_epic_status_rank` — epic summary/Slack-line bucketing. **Missed in the initial pass** — caught by `/address-pr`'s independent review on PR #156 (its own bats file was listed below all along, but the script under test wasn't; the review found the case-statement gap directly) | A |
| `tests/task_claim.bats`, `claim_gap.bats`, `reclaim_sweep.bats`, `attribution.bats`, `epic-status.bats`, `todo-next.bats`, `ipm_iteration_drain_check.bats`, `eta.bats`, `task-state.bats` | — | Bats coverage tracking the above | A |
| `lifecycle.md` | 38, 70, 82, 88, 148-149 | Canonical status-flow definition | B |
| `glossary.md` | 19, 25 | Term definitions | B |
| `_session/README.md` | 17, 25, 109, 122, 125 | Shared-lib doc | B |
| `repo-conventions/templates/{guidelines,task,design-doc}.md` | various | Scaffolds new task files copy from | B |
| `repo-conventions/SKILL.md`, `todo/SKILL.md`, `retro/SKILL.md`, `ccxp/SKILL.md`, `address-pr/SKILL.md`, `drive/SKILL.md`, `gcpr/SKILL.md`, `claim/SKILL.md` | various (`ccxp/SKILL.md` 13, `drive/SKILL.md` 10) | Skill instructions referencing the flow | B |

## Solution

**Phase A — shared script logic + bats (this PR).** Dual-accept, not a hard cutover:

- Every script in the Repo file references table above starts **writing** `In Progress` in the
  one or two places it currently writes `Coding` (`task_claim.sh acquire`,
  `release-others`'s Coding/Design → Open revert stays keyed the same way).
- Every case-statement / pattern-match currently keyed on the literal `Coding` (reclaimable
  check, actively-claimed check, in-flight detection, carry-over detection, claim-gap detection)
  is extended to **also** match `Coding` as a legacy-equivalent alias of `In Progress` — so a
  task file anywhere, at either value, is treated identically by every consumer script. This is
  the property a hard cutover would have broken (see Context).
- Bats coverage updated in lockstep: existing "Coding" assertions keep passing (legacy alias
  still works) **and** new cases assert the new value is written and recognized identically.
- A follow-up task (filed at Phase A close, staged into the *next* iteration) tracks removing the
  legacy alias once the known external task files (hub-repo, build-pipeline-repo — see Problem)
  are confirmed migrated. Until then, the alias is intentional, not tech debt to "clean up
  eventually" — removing it early is what would break peer sessions.

**Phase B — docs (follow-up PR, same task).** Decoupled from Phase A's atomicity requirement —
each doc is independently correct or incorrect, so this can land as its own PR without a
consistency window: update `lifecycle.md`'s canonical definition + status table + transition
prose, `glossary.md`'s two definitions, `_session/README.md`'s three mentions, the 3 templates,
and all 8 `SKILL.md` files, preserving every non-status-enum use of the word "coding" (e.g.
prose about "how to code a fix") untouched. Explicitly **exclude** the Copilot Coding
Agent / Cloudflare false positives (see Problem) — grep for the literal, read each hit in
context, don't blind-regex.

**Alternatives considered and rejected** (all evaluated live, each for a concrete collision —
full detail in PR #154's commit): **Active** — collides with ~20 existing "active claim"/"active
iteration"/"active backlog" prose uses. **Build** — still code/construction-flavored (the same
flaw the task already rules "Implementing" out for) and collides with the literal
`build-pipeline-repo` name plus `/drive`'s "Build/CI failure" escalation trigger. **Action** —
collides with `/drive`'s own "Trigger | Action" table column and "GitHub Actions" terminology.
**Current** — collides with the literal `_ipm/current.sh` file and "current status"/"current
iteration" phrasing. **Focus** — collides with `/ccxp`'s own "focused-work loops" terminology in
`glossary.md`. **In Progress** and **Working** were the only zero-collision candidates; **In
Progress** chosen for matching the industry convention this task already cites.

**Out of scope**: renaming any other lifecycle status (`Open`, `Design`, `Review`, `Blocked`,
`Parked`, `Done`) — this task is scoped to `Coding` only.

## Test plan

- [x] `bats tests/task_claim.bats` — legacy `Coding` still accepted everywhere it was before;
  `acquire` now writes `In Progress` (101 tests, 0 failures)
- [x] `bats tests/reclaim_sweep.bats` — a task at either `Coding` or `In Progress` with a stale
  claim is still correctly identified as reclaimable (10 tests, 0 failures)
- [x] `bats tests/attribution.bats`, `tests/claim_gap.bats`, `tests/ipm_iteration_drain_check.bats`,
  `tests/epic-status.bats`, `tests/todo-next.bats`, `tests/eta.bats`, `tests/task-state.bats` —
  full suite green after the dual-accept change (verified individually + full `bats tests/`:
  750 tests, 0 failures)
- [x] Manual: `bash _session/task_claim.sh acquire <fresh-task-id>` on a scratch task file writes
  `status: In Progress` (verified against a scratch `T99999999-999999` file)
- [x] Manual: a scratch task file hand-set to `status: Coding` is still recognized as
  actively-claimed by `bash _session/reclaim_sweep.sh` (dual-accept proof — verified: freed a
  scratch `T99999999-888888` file with a dead `deadbeef@cdw` claimant, `was Coding`)
- [x] `grep -rn "Coding" _session _ipm` after Phase A returns only comment/doc-string mentions of
  the legacy alias itself (plus the case-statement pattern in `attribution.sh:220`), not a script
  that fails to recognize it — `_session/README.md` is the one remaining non-alias hit, and it's
  explicitly Phase B (deferred, not in scope for this PR)

## Done criteria

- [x] Phase A: all script logic in the Repo file references table (A rows) writes `In Progress`
  and dual-accepts legacy `Coding` — verified by the bats suites listed in Test plan
- [x] Phase A: `bats tests/` full suite green (all 9 touched suites + no regressions elsewhere;
  750 tests, 0 failures)
- [ ] Phase B: canonical name documented in `lifecycle.md:70,82,88,148-149` + the 3 templates
- [ ] Phase B: all 8 listed `SKILL.md` files updated (`repo-conventions/SKILL.md`,
  `todo/SKILL.md`, `retro/SKILL.md`, `ccxp/SKILL.md`, `address-pr/SKILL.md`, `drive/SKILL.md`,
  `gcpr/SKILL.md`, `claim/SKILL.md`)
- [ ] A repo-wide grep for the literal `Coding` (scripts, `SKILL.md`s, `lifecycle.md`,
  `glossary.md`) after Phase A+B returns only Copilot Coding Agent / Cloudflare hits and the
  intentional legacy-alias mentions, not a stray unconverted status-enum use
- [ ] Follow-up task filed (staged into next iteration) to remove the legacy `Coding` alias once
  hub-repo/build-pipeline-repo's active `dev/TODO/` tasks are confirmed migrated — external migration of
  those 10 (unverified-stale-count) task files is explicitly **left to flip naturally** /
  out of reach from this clone, per the dual-accept design; this is the "left to flip naturally"
  decision the original Done-when criteria asked to have recorded
- [ ] `dev/JOURNAL/` entries are untouched (verified: no edits under `dev/JOURNAL/` in the diff)

## Closed

_(filled at Phase 7 close)_

## Skills invoked

_(filled at Phase 7 close)_
