---
status: Coding
estimation: 1d
source: 2026-08-09 conversation — surfaced while /address-pr-ing T20260529-651055, whose
  `task_claim.sh acquire` flow unconditionally flipped its status to `Coding` even though
  the task is IRS paperwork, not code
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260809-355059: Rename the `Coding` lifecycle status to something domain-generic

## Decisions (2026-09-25 conversation — design approved in-conversation)

- **Replacement term: `In Progress`.** Evaluated and rejected during this conversation, each for a
  concrete collision found by grep: `Active` (~20 existing "active claim"/"active iteration"/
  "active backlog" prose uses), `Build` (collides with the literal `build-pipeline-repo` name and
  `/drive`'s "Build/CI failure" escalation trigger — same code-flavored flaw the task already
  rules "Implementing" out for), `Action` (collides with `/drive`'s own "Trigger | Action" table
  column and "GitHub Actions" workflow terminology), `Current` (collides with the literal
  `_ipm/current.sh` file and the "current status"/"current iteration" phrasing used throughout),
  `Focus` (collides with `/ccxp`'s own "focused-work loops" terminology in `glossary.md`).
  `In Progress` and `Working` were the only two candidates with zero collisions; `In Progress`
  chosen for matching the Jira/Linear/GitHub Projects/Trello convention this task already cites.
- **Scope for this pass: `ccxp-skills` only.** `private-skills-repo`, `hub-repo`,
  `build-pipeline-repo`, `example-website.com` are not accessible from this clone. Per the
  2026-09-14 migration note below, the shared script logic, `lifecycle.md`, `glossary.md`, the
  templates, and all listed `SKILL.md` files now live in `ccxp-skills` itself — so this pass
  covers effectively all of "What to do" steps 1-3 and the script-logic/doc half of the "Done
  when" criteria. The remaining external piece (migrating the 10 known active TODO task files
  already at literal `status: Coding` in hub-repo/build-pipeline-repo) is out of reach from this
  clone and handled via the rollout-safety decision below instead of a direct edit.
- **Rollout safety: dual-accept, then deprecate — not a hard cutover.** `ccxp-skills` is a shared
  sibling repo other repos invoke directly via `../_session/*.sh`, so this merge changes behavior
  for every repo that shares these scripts immediately, not after their own PRs land. A hard
  cutover (case-statements only recognizing `In Progress`) would make every task file anywhere
  still sitting at the literal `Coding` — including the 10 known ones — silently invisible to
  `reclaim_sweep.sh`'s "actively-claimed" check, risking a claim being released out from under a
  live session and the same task being re-claimed and re-driven concurrently by a peer (duplicate
  work, the same failure class as the cross-repo duplicate-PR incident T20260629-332546
  describes). Instead: `task_claim.sh`, `status.sh`, `attribution.sh`, `reclaim_sweep.sh`,
  `_lib.sh`, and `ipm-iteration-drain-check.sh` all **match `Coding` as a legacy-equivalent alias
  of `In Progress`** in every case-statement/pattern-match currently keyed on the literal, while
  **writing** `In Progress` going forward (`acquire`, etc.). A follow-up task (filed at close,
  staged into the next iteration) tracks removing the alias once the known external task files
  are confirmed migrated.

## Problem

- The TODO lifecycle's `status: Coding` value (`Open → Design → Coding → Review → Done`,
  `private-skills-repo/lifecycle.md:70`) is a misnomer for the many tasks in this system that aren't
  code at all — legal filings, marketing audits, research write-ups. Concretely:
  `task_claim.sh acquire` on [T20260529-651055](https://github.com/your-org/hub-repo/issues/187) (file IRS Form 8822-B) forced
  `status: Coding` even though the only remaining step was printing and mailing a signed
  form; had to hand-correct it back to `Review` in a follow-up PR (hub-repo PR #471).
- Leading replacement candidate discussed: **"In Progress"** — matches the term nearly every
  task tool (Jira, Linear, GitHub Projects, Trello) already uses for "someone's actively on
  this," reads correctly regardless of task domain. Runner-up if a single word matching the
  `Open`/`Design`/`Review`/`Done` style is preferred: **"Working"**. Ruled out: "Implementing"
  — still code-flavored, doesn't fix the actual problem.
- Not a one-string find/replace — evidence from grepping all 4 repos that share these skills
  (`private-skills-repo`, `example-website.com`, `hub-repo`, `build-pipeline-repo`):
  - **Script logic** hardcodes the literal `Coding` string in multiple places that must stay
    consistent with each other or the state machine breaks silently:
    - `_session/task_claim.sh:237,371,428` (case-statement branches: what counts as
      actively-claimed, what `acquire` writes, what a stale-release reverts to)
    - `_session/status.sh:3` (accepted value list)
    - `_session/attribution.sh:182`, `_session/reclaim_sweep.sh:8,80`,
      `_session/_lib.sh:105,204` (all pattern-match on the literal status string)
    - `_ipm/ipm-iteration-drain-check.sh:11,28` (carry-over detection)
  - **Docs** define/repeat the flow and must move together: `private-skills-repo/lifecycle.md` (the
    canonical definition), `glossary.md`, `repo-conventions/templates/{guidelines,task,
    design-doc}.md`, `_session/README.md`, and the `SKILL.md` for `repo-conventions`, `todo`,
    `ccxp`, `drive`, `address-pr`, `gcpr`, `claim`, `retro` (each references the flow or the
    literal value at least once).
  - **False-positive risk**: "Coding" also appears as part of unrelated proper nouns —
    GitHub's **"Copilot Coding Agent"** (`address-pr/SKILL.md:180`,
    `address-pr/scripts/pre-merge-check.sh:78,82,114,138,152,164`) and an unrelated Cloudflare
    reference-architecture title (`cloudflare/references/.../patterns.md:160`). A naive
    regex rename would corrupt these — the rename must target the status-enum usages only.
  - **Existing task files already at the old value** (as of 2026-08-09; `dev/JOURNAL/` is
    archival/exempt per `repo-conventions/SKILL.md:57` — leave those untouched, they're a
    point-in-time record):
    - `hub-repo/dev/TODO/`: 2 (`T20260806-240910`, `T20260609-543188`)
    - `build-pipeline-repo/dev/TODO/`: 8 (`T20260806-179397`, `T20260508-415907`,
      `T20260419-238879`, `T20260608-240817`, `T20260629-416270`, `T20260622-007566`,
      `T20260428-679767`, `T20260604-530187`)
    - `private-skills-repo/dev/TODO/`, `example-website.com/dev/TODO/`: 0
  - **Note as of migration (2026-09-14)**: the script paths above (`_session/`, `_ipm/`) now
    live in `ccxp-skills` (post T20260827-280088 split) — re-verify the exact line numbers at
    pickup, they will have drifted since 2026-08-09.

## What to do

1. Confirm the replacement term (default to "In Progress" absent objection).
2. Enumerate every true status-enum reference across the repos that share these skills
   (`ccxp-skills`, `private-skills-repo`, `hub-repo`, `build-pipeline-repo`, `example-website.com`) —
   explicitly exclude the "Copilot Coding Agent" / Cloudflare false positives above.
3. Update `ccxp-skills` first (source of truth for the shared script logic and skill docs
   post-split), plus `_session/tests/task_claim.bats` (and any other bats coverage asserting
   the literal string).
4. Migrate the active TODO tasks currently at the old value (bulk edit vs. leaving them to
   flip naturally on their next status transition — pick one and say why).
5. Land as separate PRs per repo (the `ccxp-skills` change gates the consumer-repo task-file
   migrations, since the latter reference the renamed value).

## Done when

- Canonical name is decided and documented in `private-skills-repo/lifecycle.md` + the 3 templates
  (now in `ccxp-skills/repo-conventions/templates/`).
- All script logic listed above uses the new value consistently — a `grep -rn "Coding"` over
  `ccxp-skills/_session` and `_ipm` after the change returns only unrelated hits (Copilot
  Agent, Cloudflare), not status-enum ones.
- All listed `SKILL.md` files updated.
- The active TODO tasks are migrated (or an explicit "left to flip naturally" decision is
  recorded here).
- `dev/JOURNAL/` entries are untouched.

## Out of scope

- Renaming any other lifecycle status (`Open`, `Design`, `Review`, `Blocked`, `Parked`,
  `Done`) — this task is scoped to `Coding` only.

## Migrated (2026-09-14)

- Migrated from `hub-repo/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: your-org/private-skills-repo` field (set 2026-08-09, before
  the ccxp-skills split shipped) is stale: `_session/`/`_ipm/` are now
  ccxp-skills' own shared libs, so this is "work about ccxp-skills itself"
  per that repo's CLAUDE.md — landing here directly instead of `private-skills-repo`.
