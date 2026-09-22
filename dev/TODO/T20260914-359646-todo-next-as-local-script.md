---
status: Coding
estimation: 4h
source: this conversation, 2026-09-14 — maintainer asked to speed up `/todo next`; scope broadened 2026-09-16 — maintainer asked why `/todo list`'s table costs an LLM turn too, when it's just as deterministic a read of already-persisted `queue.md`/frontmatter
related: T20260911-347027
description: Port /todo list's table + /todo next's queue-walk logic into sourceable bash scripts so neither needs an LLM turn
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260914-359646: Convert `/todo list`'s table and `/todo next`'s queue-walk into token-free local scripts

## TLDR

- **Type**: feature
- **Problem**: `/todo list` and `/todo next` each spend an LLM turn on a fully deterministic read of `dev/TODO/queue.md` + task frontmatter + claim state — no judgment involved.
- **Solution**: two sourceable bash scripts (`todo/scripts/todo-list.sh`, `todo/scripts/todo-next.sh`) sharing a common parsing lib, invoked directly by a human/CI with zero model calls; `todo/SKILL.md`'s `list`/`next` workflows shell out to them instead of re-deriving the walk inline.

## Problem

- **Type**: feature
- `/todo next` (`todo/SKILL.md`) is a slash-command skill: every invocation spends an LLM turn re-reading `dev/TODO/queue.md`, each candidate task's frontmatter, and `_session/task_claim.sh read`/`reclaimable` output to walk the queue and skip `Done`/`Parked`/peer-claimed entries — even though that walk is fully deterministic and already spelled out step-by-step in the skill doc.
- **Same problem, same root cause, in `/todo list`** (broadened 2026-09-16): it re-reads `queue.md` + every task's frontmatter to render a plain table (`#`/ID/Title/Status/Est/Deadline/Scheduled/Claimed) plus counts and a parking-lot count — all of it a mechanical transform of data already sitting in `queue.md`/task frontmatter, no judgment involved. `list`'s drift-detection (untracked files, stale queue entries, stale `Blocked by T{id}` references) is likewise a plain set/existence check, not a decision — it belongs in the same script, unlike `sweep`'s Phase 2/3 (blocker-order enforcement, Park recommendations), which really does make judgment calls and stays LLM-driven. (Phase 3's auto-close step — Done/Superseded — is itself a mechanical read, same as `list`/`next`; it just hasn't been extracted here because it's bundled with the judgment-call Park path in the same phase.)
- Maintainer ask (2026-09-14, `next`; reaffirmed 2026-09-16 for `list`): make both runnable as plain scripts so "what's open" / "what's next" don't cost tokens at all.
- Done looks like: `todo/scripts/todo-next.sh` and `todo/scripts/todo-list.sh` (or one script, two subcommands) that read `queue.md` + task frontmatter + claim state directly and print the same reports `/todo next`/`/todo list` currently produce — runnable standalone with no model call.

## Context

- **In scope — `next`**: skip `Done`/legacy `Revisit`/`Parked`; peer-mode
  claim filtering via `task_claim.sh read`/`claimant-id`/`reclaimable`,
  disable via `CCXP_PEER_MODE=0`; a plain `/todo sweep` callout when a
  top-3 survivor is still `Blocked by T{id}` and `{id}`'s file still
  exists in `dev/TODO/` (`todo/SKILL.md`'s `next` step 5).
- **In scope — `list`**: the table (all 8 columns per `todo/SKILL.md`'s
  `list` workflow), the summary counts (total, by status,
  committed-to-iteration, claimed mine/peers), the parking-lot count, and
  drift-detection (untracked `dev/TODO/*.md` not in `queue.md`; stale
  `queue.md` lines with no file; stale `Blocked by T{id}` references) —
  all report-only, no mutation.
- **Not in scope**: `/todo sweep`'s mutating logic (Phase 2 blocker-order
  enforcement, Phase 3 auto-close + Park judgment calls) — those stay in
  the skill, they make real decisions, not just a deterministic read.
- The skill (`todo/SKILL.md`) should still document the underlying logic
  (for `sweep` reuse and for a human reading the skill), but `list`'s and
  `next`'s own workflow sections should shell out to the script(s)
  instead of re-deriving the walk/table inline.
- `todo/SKILL.md`'s `list` workflow (steps 1-7) and `next` workflow (steps
  1-5) already spell out the exact algorithm step-by-step — this task is a
  port, not a redesign; the script's behavior must match what's documented
  there today.
- `_session/task_claim.sh` already exposes the primitives both scripts need
  as a stable CLI: `read <id>` (prints `status\tclaimed_by`), `reclaimable
  <id>` (prints `reclaimable`/`live`), `claimant-id` (prints this clone's
  id) — no new claim-state logic needs writing, just shelling out to these.
- `repo-conventions/scripts/lint_tasks.py` and `design-score/scripts/score.sh`
  are this repo's existing precedent for a "skill logic ported to a bundled
  script" shape (frontmatter parsing in bash/python, sourceable, BATS/CLI
  testable) — same pattern, applied to `todo/`.

## Solution

- **Two scripts, not one with subcommands** (task's own scoping already
  picked this — noted here for the record, not re-litigated): `todo/scripts/todo-list.sh`
  and `todo/scripts/todo-next.sh`, both sourcing a shared
  `todo/scripts/_lib.sh` for the parts they have in common (queue.md
  line parsing, frontmatter field extraction, claim-state lookup) — same
  "extract when 2+ things need it" rule `skill-conventions/SKILL.md` §4
  already applies to cross-skill libs, scoped down to intra-skill reuse.
- `_lib.sh` functions:
  - `todo_parse_queue_line <line>` → `id<TAB>relpath<TAB>title`
  - `todo_read_frontmatter <task-file>` → the fields both scripts need
    (`status`, `estimation`, `deadline`, `scheduled`, `claimed_by`,
    `blocks`) as tab-separated fields (mirrors `_tc_fm_get`'s existing
    single-field getter, called once per field instead of re-parsing)
  - `todo_claim_state <id>` → wraps `task_claim.sh read`/`reclaimable`/
    `claimant-id` into one `mine|peer:<id>|reclaimable:<id>|unclaimed`
    verdict, honoring `CCXP_PEER_MODE=0` (skip claim filtering entirely)
- `todo-list.sh`: renders the 8-column table (`#`/ID/Title/Status/Est/
  Deadline/Scheduled/Claimed) in queue order, the summary counts (total,
  by status, committed-to-iteration, claimed mine/peers), the
  parking-lot count (`dev/PARKING/*.md` count), and drift detection
  (untracked `dev/TODO/*.md` not in `queue.md`; stale `queue.md` lines;
  stale `Blocked by T{id}` references) — a straight port of `list`'s
  existing steps 1-7, report-only, no file mutation.
- `todo-next.sh`: walks `queue.md` top to bottom, skips `Done`/legacy
  `Revisit`/`Parked` and (unless `CCXP_PEER_MODE=0`) tasks claimed by
  another live session per `todo_claim_state`, collects the first 3
  survivors, and prints each one's queue position, verbatim status,
  deadline/scheduled, claim state, and `Unblocks:` list if the frontmatter
  has one. **In scope — `next` step 5** (a real gap an independent
  design review caught 2026-09-22, added here before implementation): if
  a survivor's status contains `Blocked by T{id}`, check whether `{id}`
  still has a file in `dev/TODO/` — if so, print a plain callout pointing
  at `/todo sweep` (same existence check `list`'s stale-blocker detection
  already does; the script does **not** try to interpret the block
  further, matching `todo/SKILL.md`'s own "don't try to interpret it
  further" instruction). **Deliberately out of scope**: `next`'s "the next concrete
  action to move it forward, if evident from the file" line — that
  requires reading and interpreting a task's free-form body prose, which
  is exactly the judgment call a token-free script can't make. The
  script's report is the structural facts only; a human or an LLM session
  reading the top pick's file can still add that interpretation on top,
  same as today.
- `todo/SKILL.md`'s `list` and `next` workflow sections are rewritten to
  say "run `todo/scripts/todo-list.sh`" / "run `todo/scripts/todo-next.sh`"
  and print the result, instead of re-deriving the walk inline — but the
  underlying algorithm description stays in the skill doc (for `sweep`'s
  Phase 2/3 reuse, and for a human reader), per this task's own scoping
  note above.
- **Alternatives rejected**:
  - *One script with `list`/`next` subcommands* — the task's own "Done
    looks like" line offers this as an option; rejected in favor of two
    files because `todo/SKILL.md`'s two workflows already read as
    independent (different callers, different output shapes), and two
    small sourceable scripts are each individually easier to BATS-test
    and to invoke standalone (`bash todo/scripts/todo-next.sh`) without
    an argument-dispatch layer to reason about.
  - *Reimplement claim-state logic instead of shelling out to
    `task_claim.sh`* — rejected: `task_claim.sh` is the single source of
    truth for the claim format (`cc1-<host>:<path-hash>`), the
    staleness-window reclaim decision, and `CCXP_PEER_MODE`; duplicating
    that logic risks drift the moment either copy changes.
  - *A Python rewrite instead of bash* — rejected: no other `todo/`
    tooling uses Python, `_session/task_claim.sh` (the script's main
    dependency) is bash, and `dev/guidelines.md`'s Script Standards
    section is bash-first; introducing a second language for one skill's
    scripts adds a dependency (a Python interpreter + no existing
    venv/requirements convention) for no clear benefit here.

## Root cause

- `todo/SKILL.md`'s `list` and `next` workflows were authored as pure
  prose instructions for an LLM to execute step-by-step (`todo/SKILL.md`'s
  `## Workflow: list` and `## Workflow: next` sections) — a deliberate
  choice at the time the skill was written, matching every other
  slash-command skill in this repo, not an oversight. The cost only
  became visible once `/todo next`/`/todo list` started being invoked
  routinely by `/drive` Phase 1 and interactive sessions (maintainer ask,
  2026-09-14/16) — a purely mechanical read (parse `queue.md`, look up
  frontmatter, format a table) was paying the same LLM-turn cost as a
  workflow that has to make real judgment calls (`sweep`'s Park
  recommendation).
- Introduced: the `list`/`next` workflows have looked like this since
  `todo/SKILL.md` was first written; this task is the first time the
  no-model-call alternative was scoped, not a regression fix.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `todo/SKILL.md` | `list`/`next` workflow sections | Current prose-driven algorithm this task ports; stays as the documented reference for `sweep` reuse and human readers |
| `_session/task_claim.sh` | `_tc_read`/`_tc_reclaimable`/`_tc_claimant_id` (CLI: `read`/`reclaimable`/`claimant-id`) | Claim-state primitives both new scripts shell out to, not reimplement |
| `dev/TODO/queue.md` | whole file | The ordered priority list both scripts parse |
| `repo-conventions/scripts/lint_tasks.py` | whole file | Existing precedent for a skill's deterministic logic living in a bundled, testable script |

## Test plan

- [x] BATS coverage (`next`): queue with a mix of Open/Done/Parked/live-peer-claimed/reclaimable-stale entries → script picks the correct top 3, in queue order (`tests/todo-next.bats` — note: tests live in the repo's top-level `tests/`, not `todo/tests/`, per `.github/workflows/tests.yml`'s `bats tests/*.bats _docs/*.bats`; corrected from this design's original path during implementation)
- [x] BATS coverage (`next`, step 5): a top-3 survivor with `status: Blocked by T{id}` where `{id}` still has a `dev/TODO/` file → script prints the `/todo sweep` callout; where `{id}`'s file is gone → no callout (stale-blocker resolution is `sweep`'s job, not `next`'s) (`tests/todo-next.bats`)
- [x] BATS coverage (`list`): renders the full table + counts correctly; detects an untracked task file, a stale queue line, and a stale `Blocked by T{id}` reference (`tests/todo-list.bats`)
- [x] `CCXP_PEER_MODE=0` → no claim filtering (both scripts, where applicable) (`tests/todo-next.bats`)
- [x] Empty queue / all-skipped queue → both scripts report that plainly instead of erroring (`tests/todo-next.bats`, `tests/todo-list.bats`)
- [x] Manual: script output matches `/todo list`'s and `/todo next`'s own current output structure, from a real ccxp-skills checkout — run against this repo's live `dev/TODO/queue.md`, confirmed correct output for both scripts

## Done criteria

- [x] `todo/scripts/todo-next.sh` and `todo/scripts/todo-list.sh` exist, sourceable, BATS-covered — `todo/scripts/todo-next.sh`, `todo/scripts/todo-list.sh`, `todo/scripts/_lib.sh`, `tests/todo-next.bats`, `tests/todo-list.bats`, `tests/todo-lib.bats`
- [x] `todo/SKILL.md`'s `list` and `next` workflow sections invoke the scripts instead of re-deriving the walk/table — `todo/SKILL.md`'s `list`/`next` workflow sections
- [x] No behavior change to `/todo sweep` — `todo/SKILL.md`'s `sweep` workflow section is untouched by this task's diff
