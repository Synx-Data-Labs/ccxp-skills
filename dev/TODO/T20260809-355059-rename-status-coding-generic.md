---
status: Open
estimation: 1d
source: 2026-08-09 conversation — surfaced while /address-pr-ing T20260529-651055, whose
  `task_claim.sh acquire` flow unconditionally flipped its status to `Coding` even though
  the task is IRS paperwork, not code
---

# T20260809-355059: Rename the `Coding` lifecycle status to something domain-generic

## Problem

- The TODO lifecycle's `status: Coding` value (`Open → Design → Coding → Review → Done`,
  `synx-skills/lifecycle.md:70`) is a misnomer for the many tasks in this system that aren't
  code at all — legal filings, marketing audits, research write-ups. Concretely:
  `task_claim.sh acquire` on [T20260529-651055](https://github.com/Synx-Data-Labs/synxdb-team/issues/187) (file IRS Form 8822-B) forced
  `status: Coding` even though the only remaining step was printing and mailing a signed
  form; had to hand-correct it back to `Review` in a follow-up PR (synxdb-team PR #471).
- Leading replacement candidate discussed: **"In Progress"** — matches the term nearly every
  task tool (Jira, Linear, GitHub Projects, Trello) already uses for "someone's actively on
  this," reads correctly regardless of task domain. Runner-up if a single word matching the
  `Open`/`Design`/`Review`/`Done` style is preferred: **"Working"**. Ruled out: "Implementing"
  — still code-flavored, doesn't fix the actual problem.
- Not a one-string find/replace — evidence from grepping all 4 repos that share these skills
  (`synx-skills`, `synxdata.com`, `synxdb-team`, `synxdb-build-pipeline`):
  - **Script logic** hardcodes the literal `Coding` string in multiple places that must stay
    consistent with each other or the state machine breaks silently:
    - `_session/task_claim.sh:237,371,428` (case-statement branches: what counts as
      actively-claimed, what `acquire` writes, what a stale-release reverts to)
    - `_session/status.sh:3` (accepted value list)
    - `_session/attribution.sh:182`, `_session/reclaim_sweep.sh:8,80`,
      `_session/_lib.sh:105,204` (all pattern-match on the literal status string)
    - `_ipm/ipm-iteration-drain-check.sh:11,28` (carry-over detection)
  - **Docs** define/repeat the flow and must move together: `synx-skills/lifecycle.md` (the
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
    - `synxdb-team/dev/TODO/`: 2 (`T20260806-240910`, `T20260609-543188`)
    - `synxdb-build-pipeline/dev/TODO/`: 8 (`T20260806-179397`, `T20260508-415907`,
      `T20260419-238879`, `T20260608-240817`, `T20260629-416270`, `T20260622-007566`,
      `T20260428-679767`, `T20260604-530187`)
    - `synx-skills/dev/TODO/`, `synxdata.com/dev/TODO/`: 0
  - **Note as of migration (2026-09-14)**: the script paths above (`_session/`, `_ipm/`) now
    live in `ccxp-skills` (post T20260827-280088 split) — re-verify the exact line numbers at
    pickup, they will have drifted since 2026-08-09.

## What to do

1. Confirm the replacement term (default to "In Progress" absent objection).
2. Enumerate every true status-enum reference across the repos that share these skills
   (`ccxp-skills`, `synx-skills`, `synxdb-team`, `synxdb-build-pipeline`, `synxdata.com`) —
   explicitly exclude the "Copilot Coding Agent" / Cloudflare false positives above.
3. Update `ccxp-skills` first (source of truth for the shared script logic and skill docs
   post-split), plus `_session/tests/task_claim.bats` (and any other bats coverage asserting
   the literal string).
4. Migrate the active TODO tasks currently at the old value (bulk edit vs. leaving them to
   flip naturally on their next status transition — pick one and say why).
5. Land as separate PRs per repo (the `ccxp-skills` change gates the consumer-repo task-file
   migrations, since the latter reference the renamed value).

## Done when

- Canonical name is decided and documented in `synx-skills/lifecycle.md` + the 3 templates
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

- Migrated from `synxdb-team/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: Synx-Data-Labs/synx-skills` field (set 2026-08-09, before
  the ccxp-skills split shipped) is stale: `_session/`/`_ipm/` are now
  ccxp-skills' own shared libs, so this is "work about ccxp-skills itself"
  per that repo's CLAUDE.md — landing here directly instead of `synx-skills`.
