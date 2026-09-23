---
status: Open
scheduled: 2026-10-05
estimation: 2h
source: this /autopilot run, discovered when a dispatched /drive sub-agent
  closed T20260919-231319 without the always-immediate journal-move
  (T20260914-422854), then fixed via a follow-up housekeeping PR (#105)
related: T20260914-422854
---

# T20260922-201976: `Skill` tool invocations can serve stale cached skill content that disagrees with the live repo checkout

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
  T20260919-231319 — flipped `status: Done`, wrote `## Closed`/`## Skills
  invoked` — but never journal-moved the file from `dev/TODO/` to
  `dev/JOURNAL/`. Caught only because the coordinating `/autopilot` loop
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
  live in (`/home/rocky/ccxp-skills`) — the same class of drift the
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
  guard exists in the unrelated `synxdb-build-pipeline` repo
  (`T20260920-111958`, mentioned in a cross-repo standup thread this
  session happened to read) — that task ID does **not** apply here; an
  earlier draft of this task cited it by mistake, caught and corrected
  before filing.

## Solution (sketch — needs a design pass, filed as a task not a bounded PR)

- Candidate mitigations, not yet chosen between:
  1. **A new CI guard** (this repo doesn't have one today — see the
     verified-directly note above): fail loudly (in `lint-tasks` CI, or a
     new dedicated check) if any `dev/TODO/*.md` or `dev/PARKING/*.md`
     file's frontmatter `status:` leads with `Done` — such a file should
     always have been journal-moved. Cheap, mechanical, and would have
     caught this exact case on `main` after PR #104 merged (before this
     task's own follow-up PR #105 fixed it by hand).
  2. `/drive`/`/autopilot`'s own post-merge verification step could
     explicitly re-check `git ls-files dev/TODO/ | grep "$task_id"`
     returns empty right after a close-PR merges, failing loudly (not
     just trusting a dispatched sub-agent's own self-report) if the file
     is still present there — catches it at merge time, not on a later
     CI run.
  3. Investigate whether re-reading a skill's file directly (e.g. `cat
     drive/SKILL.md` or `git show HEAD:drive/SKILL.md`) instead of
     relying solely on the `Skill` tool's returned content, immediately
     before acting on a recently-changed convention, is a reasonable
     standing practice for skills that get edited frequently by the same
     session (self-diagnosis / workaround, not a real fix for the
     underlying platform caching behavior).
- Candidates 1 and 2 are complementary (a CI guard as a backstop, a
  `/drive`-side check for immediate feedback), not mutually exclusive —
  whoever picks this up should decide whether to do one or both, and
  whether the platform-level caching root cause is worth reporting
  upstream separately from this repo's own mitigation.

## Done criteria

- [ ] A decision recorded on which mitigation(s) from the Solution
  sketch above are worth implementing (a new CI guard, a `/drive`-side
  post-merge check, both, or neither pending more data)
- [ ] If a CI guard is chosen: implemented, tested, and verified to
  actually catch a `status: Done` file sitting in `dev/TODO/`
  (regression test: create one, confirm the guard fails; journal-move
  it, confirm the guard passes)
