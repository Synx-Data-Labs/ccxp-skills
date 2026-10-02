---
status: Done
scheduled: 2026-09-28
estimation: 2
source: this /autopilot run, discovered when a dispatched /drive sub-agent
  closed T20260919-231319 without the always-immediate journal-move
  (T20260914-422854), then fixed via a follow-up housekeeping PR (#105)
related: T20260914-422854
claimed_by:
claimed_role:
---

# T20260922-201976: `Skill` tool invocations can serve stale cached skill content that disagrees with the live repo checkout

## TLDR

- **Type**: bug (platform caching) + chore (this repo's mitigation)
- **Problem**: the harness can display stale `Skill`-tool content that
  disagrees with the live `drive/SKILL.md` checkout, and once (this session)
  that caused a dispatched `/drive` sub-agent to close a task without the
  mandatory immediate journal-move — a `status: Done` file left sitting in
  `dev/TODO/`.
- **Solution**: implement Candidate 1 only — a new `lint_tasks.py` check
  (`check_not_done_in_todo`) that fails whenever a `dev/TODO/*.md` file's
  `status:` leading token is `done`. Cheap, mechanical, catches this exact
  failure mode regardless of its root cause (stale skill cache, a rushed
  manual close, anything). Candidates 2 and 3 are explicitly rejected below.

## Problem

- **Type**: bug (tooling/platform, not this repo's own scripts)
- Earlier in this same session, an `/ccxp-skills:drive` re-invocation's
  displayed "Re-invocation of /ccxp-skills:drive" text showed the OLD
  default close behavior (in-place `status: Done` flip, deferred journal
  move to Friday's retro sweep, with an `--immediate` override flag) —
  even though `drive/SKILL.md` on disk, at that exact moment, already had
  the newer "always-immediate journal-move" convention (T20260914-422854)
  committed and merged to `main`. Directly confirmed via `grep -n
  "immediate\|journal-move" drive/SKILL.md` against the live file, which
  showed the correct, current text — the *displayed* skill content was
  simply stale relative to what `git show HEAD:drive/SKILL.md` actually
  contained.
- **Concrete downstream cost, this run**: a dispatched `/drive` sub-agent
  (fresh session, no memory of the discovery above) closed
  T20260919-231319 — flipped `status: Done`, wrote the close sections, but
  never journal-moved the file from `dev/TODO/` to `dev/JOURNAL/`.
  Caught only because the coordinating `/autopilot` loop
  happened to notice the sub-agent's own final report still listed the
  task file at its `dev/TODO/` path and manually diffed. Fixed via a
  small follow-up PR (#105) — but a genuinely unattended, unsupervised
  run (no coordinating layer double-checking sub-agent reports) would
  have silently left this task un-journal-moved, invisible to `/retro`'s
  Phase 2 classification exactly the way T20260914-422854 was filed to
  prevent.
- Root cause is a platform/harness caching behavior (the `Skill` tool /
  plugin-bundle loading mechanism), not anything wrong in this repo's own
  `drive/SKILL.md` content — the live file has been correct throughout.

## Context

- Not reproduced on demand — this is an intermittent staleness window,
  observed twice in one session (the interactive re-invocation display,
  and now this dispatched-agent miss) but with no known trigger to force
  it deliberately. May be tied to how the Claude Code plugin bundle is
  installed/synced on this box vs. the live git checkout the skills also
  live in (`/home/ci/ccxp-skills`) — the same class of drift the
  now-retired symlink-install layout (T20260914-871616) used to cause,
  though that was fully retired and this repo's own scripts (`GH_SH`
  resolution, etc.) were fixed for it.
- Nothing in *this repo* can directly fix a harness-level caching
  behavior — this task is scoped to what this repo CAN do: detect and
  cheaply recover from the symptom, since the platform-level root cause
  is out of scope for a ccxp-skills PR.
- **Verified directly (not assumed)**: `ccxp-skills` currently has **no**
  CI guard that fails when a `dev/TODO/*.md` file's frontmatter has
  `status: Done` — `repo-conventions/scripts/lint_tasks.py` only checks
  blocker cross-references against `dev/JOURNAL/`, never the file's own
  status vs. its own location (`grep -n "Done"
  repo-conventions/scripts/lint_tasks.py` — only doc comments and an
  unrelated blocker-already-closed message, no such check). A similarly-named
  guard exists in the unrelated `build-pipeline-repo` repo
  (`T20260920-111958`, mentioned in a cross-repo standup thread this
  session happened to read) — that task ID does **not** apply here; an
  earlier draft of this task cited it by mistake, caught and corrected
  before filing.

## Solution

**Decision: implement Candidate 1 only** (a new `lint_tasks.py` check).
Candidates 2 and 3 are rejected — reasons below.

- **Where it lives**: `repo-conventions/scripts/lint_tasks.py` (not a new
  standalone workflow step) — it already owns per-file frontmatter schema
  checks (`check_required`, `check_status`, `check_estimation`, …) run via
  `CHECKS` in `lint_file()` (`repo-conventions/scripts/lint_tasks.py:181-182`),
  and it is consumed both by this repo's own `test_lint_tasks.py` CI job
  (`.github/workflows/tests.yml:60-68`) and by every consumer repo's
  `actions/lint-tasks` composite action (`actions/lint-tasks/action.yml:18`).
  Adding the check here means every repo using the shared action gets the
  guard for free on its next `lint_tasks.py` pull, not just this repo.
- **New check — `check_not_done_in_todo(ctx)`**. Scope: `dev/TODO/` files
  only, never `dev/PARKING/` — a parked task legitimately keeps whatever
  status it had when parked, and `status: Parked` can't collide with the
  `done` leading token anyway. Condition: `status_head(ctx.keys["status"])`
  equals `done`. Violation message references T20260914-422854 (every
  close journal-moves immediately) and tells the reader to move the file
  into `dev/JOURNAL`. Reuses
  the existing `status_head()` helper (`repo-conventions/scripts/lint_tasks.py:67-78`)
  for the same leading-token tolerance every other status check already
  gets (a narrated `Done — superseded by T…` still matches).
  - `Ctx` doesn't currently carry which directory a file came from —
    `is_task_file()`/`iter_task_files()` do, but `Ctx` is built from a bare
    path. Derive scope the same way `is_task_file()` already does: test
    whether `ctx.path.parts` contains the open-tasks folder name — no new
    field needed on `Ctx`.
  - Register it in the `CHECKS` tuple (`repo-conventions/scripts/lint_tasks.py:181`)
    alongside the other per-file checks — it then runs automatically in both
    `--all` and `--changed` modes via the existing `lint_file()` loop, no
    `main()` changes needed.
- **Test**: add `test_lint_tasks.py` cases (mirroring the existing per-check
  test shape) — one `dev/TODO/`-status-Done file fails with the new message;
  the same content under `dev/PARKING/` passes (scope check); a
  `dev/JOURNAL/`-adjacent Done status is out of lint scope entirely
  (`is_task_file`/`iter_task_files` never look at JOURNAL) so no test needed
  there.

**Rejected alternatives:**

- **Candidate 2** (`/drive`/`/autopilot` post-merge self-check — list the
  open-tasks folder and grep for the task id right after a close-PR merges)
  — rejected as
  the *primary* fix: it only runs inside `/drive`'s own close path, so it
  can't catch the actual observed failure mode (a dispatched sub-agent that
  skipped the close path's own journal-move step entirely) any better than
  the sub-agent's self-report already should have. It also adds a second,
  bespoke verification surface to maintain in `drive/SKILL.md` for a class
  of bug a single CI check already covers for every path that can produce a
  `dev/TODO/` file — manual close, a different automation, a human editing
  by hand. Not implementing it now; CI is the one chokepoint every path
  through main has to cross regardless of which tool produced the bad file.
- **Candidate 3** (re-`cat`/`git show` a skill file directly instead of
  trusting the `Skill` tool's returned content before acting on a
  recently-changed convention) — rejected as out of this task's scope: it's
  a per-session workaround for a platform-level caching behavior this repo
  cannot fix or verify (no reproduction trigger — see Context above), not a
  repo-side mitigation with a testable done-criterion. Worth raising with
  the platform separately (outside this repo), not worth encoding as a
  standing practice here with no way to confirm compliance.

## Root cause

- `repo-conventions/scripts/lint_tasks.py` has never had a status-vs-location
  check — it was introduced in the initial public release (`5051a9e`) with
  only schema checks (`check_required`, `check_status`, `check_estimation`,
  `check_allowlist`, `check_h1_id`, `check_scheduled_when_advanced` — see
  the `CHECKS` tuple) and the board-wide `check_blocked_by` cross-reference
  pass. A file's own `status:` was always validated against the known-token
  list (`check_status`) but never cross-checked against *where the file
  lives* (open-tasks folder vs. `dev/JOURNAL`). This is an oversight from day one, not
  a deliberate decision — the schema-only scope made sense when the file
  was first written, before T20260914-422854 (2026-09-14) made "every close
  journal-moves immediately" the hard invariant that a `status: Done` file
  in `dev/TODO/` now violates.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/lint_tasks.py` | 67-78 (`status_head`), 109-116 (`check_status`, model for the new check), 181-182 (`CHECKS` tuple) | add `check_not_done_in_todo` here, register it in `CHECKS` |
| `repo-conventions/scripts/test_lint_tasks.py` | (new cases, mirroring existing per-check test shape) | regression coverage for the new check |
| `.github/workflows/tests.yml` | 60-68 (`lint-tasks` job) | already runs `test_lint_tasks.py -v` — no workflow change needed |
| `actions/lint-tasks/action.yml` | 18 | consumer-repo entry point that calls `lint_tasks.py --changed`/`--all` — picks up the new check automatically once this PR merges |

## Test plan

- [x] `python3 repo-conventions/scripts/test_lint_tasks.py -v` — new
  `check_not_done_in_todo` cases pass locally (51/51 tests OK, 5 new:
  `test_done_status_in_todo_fails`, `test_done_status_in_parking_passes`,
  `test_closed_status_in_todo_fails`, `test_narrated_done_status_in_todo_fails`,
  `test_non_done_status_in_todo_passes_the_new_check` — the `closed` case
  added after independent review on PR #219 found the check originally
  missed `status: Closed`, which `actions/sync-tasks/sync.py` treats as
  Done-equivalent for the board sync)
- [x] Manual regression per the original Done-criteria ask: created a
  throwaway `dev/TODO/T00000000-000000-test.md` with `status: Done`, ran
  `python3 repo-conventions/scripts/lint_tasks.py --all .` — failed with
  the new message; deleted the throwaway file — clean run (22/22 conform)
- [ ] CI (`tests.yml`'s `lint-tasks` job) green on the PR

## Done criteria

- [x] A decision recorded on which mitigation(s) from the Solution
  sketch above are worth implementing — Candidate 1 only (see Solution
  above); Candidates 2 and 3 explicitly rejected with reasons
- [x] CI guard implemented, tested, and verified to actually catch a
  `status: Done` file sitting in `dev/TODO/` — satisfied by
  `check_not_done_in_todo` in `repo-conventions/scripts/lint_tasks.py`
  plus its `test_lint_tasks.py` regression cases (see Test plan)

## Closed (2026-10-01)

- Shipped in **PR #219** (design in PR #218, claim in PR #217). CI
  (`tests.yml`'s `lint-tasks` job) pending at commit time — ticked once
  green, per `/address-pr`'s own hard-gate loop.
- Met: both Done-criteria items above — the design decision (Candidate 1
  only) and the implemented/tested CI guard.
- The underlying platform-level `Skill`-tool caching behavior that
  prompted this task remains unfixed and unreproducible on demand (see
  Context) — out of scope for this repo; this task's own scope was
  always the repo-side detection backstop, not the platform root cause.
  No follow-up task filed for the platform issue itself: there is no
  concrete reproduction to anchor one, per the original filing's own
  "not reproduced on demand" caveat.
- No other follow-up tasks filed — Candidates 2 and 3 were evaluated and
  explicitly rejected (see Solution), not deferred.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the first 4
  `test_lint_tasks.py` cases before `check_not_done_in_todo` existed
  (confirmed 2 failures), implemented to green, then added a 5th case
  (`test_closed_status_in_todo_fails`) test-first for the review finding
  below before fixing the check itself (red, then green at 51/51)
- Verification (`superpowers:verification-before-completion`): yes —
  manual throwaway-file regression (fail then clean), full
  `test_lint_tasks.py`/`test_lint_paragraphs.py`/`test_lint_identifiers.py`
  runs, full `bats` suite (872/872), `doc-impact.sh` review
- Systematic debugging (`superpowers:systematic-debugging`): no — no
  stuck test, straight TDD red-to-green both times
- Receiving code review (`superpowers:receiving-code-review`): yes, twice
  — design PR #218's independent review found two off-by-a-few-lines
  citations (fixed, no pushback, finding was correct); implementation
  PR #219's independent review found a real false-negative (`status:
  Closed` is Done-equivalent per `actions/sync-tasks/sync.py` but wasn't
  matched) — verified against `sync.py:519-520` directly, confirmed
  correct, fixed with a new `DONE_EQUIVALENT_HEADS` set and regression
  test, no pushback
