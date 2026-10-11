---
status: Done
scheduled: 2026-10-05
estimation: 1
source: 2026-10-05 /incept readiness pass in a consumer repo (build-pipeline-repo) — follow-up from closing its board-sync task as moot
related: T20261002-359869 (lifecycle.md opt-in board note — prose side), _ipm/ipm-iteration-drain-check.sh, ipm/SKILL.md (step 5a drain gate), lifecycle.md (§ Iteration assignment, board described as optional)
description: The /ipm drain gate hard-requires a GitHub Project board; a consumer that has retired its board gets a permanently red gate
claimed_by:
claimed_role:
---

# T20261005-554581: `ipm-iteration-drain-check.sh` hard-requires a Project board, so a board-less consumer's IPM gate is permanently red

## Problem

- `_ipm/ipm-iteration-drain-check.sh:224` lists items with
  `gh project item-list <n>` and treats the board's Iteration/Status fields as
  the source of truth.
- `lifecycle.md` already says the board is optional ("`scheduled:` plus the
  local `dev/TODO/` and `dev/JOURNAL/*.md` files are fully sufficient"), but
  the gate contradicts that.
- Observed: a consumer repo retired its `sync-tasks-to-issues` workflow and
  closed its Project board (2026-09-25). Since then every Monday `/ipm` reports
  the drain gate red, and the IPM notes blame an unrelated, now-closed task.
- The consumer's maintainer confirmed (2026-10-05) they do not want a board.

## Plan sketch (to be settled in Design)

- Make the gate derive "left over from iteration N" from `scheduled:` in
  `dev/TODO/` when no live board is configured (or the board is closed), instead
  of failing; keep the board path for consumers that still use one.
- Fold in the old consumer-side ask (closed there as moot): never block on the
  previous IPM's own auto-generated "Weekly Focus" pointer issue.
- Refresh `ipm/SKILL.md` step 5a and `lifecycle.md` prose to match.

## Done criteria

- [x] With no board configured, the gate runs from `scheduled:` alone and
      exits 0 on a drained iteration
- [x] BATS coverage

## Closed (2026-10-10)

- Scoped together with T20261005-639913 (remove `ROADMAP_TARGET_REPO`) and
  T20261010-665166 (drop the hour budget) in one PR — all three touch
  `ipm/SKILL.md` steps 4/5/5a/5b and would leave it internally inconsistent
  done separately.
- Went further than the Plan sketch's "keep the board path for consumers
  that still use one": confirmed repo-wide that no consumer has a live,
  configured Project board or PAT, so `_ipm/ipm-iteration-drain-check.sh`
  dropped the board path **entirely** rather than branching on it —
  `--home-repo`/`--owner`/`--project`, the cross-repo partition, the
  lint-frozen sub-partition, and the `gh project item-list` call are all
  gone. The gate now reads `dev/TODO/*.md` frontmatter directly: a
  non-terminal task whose `scheduled:` equals the previous iteration's
  Monday (current-week Monday minus 7 days, or `--prev-start` to force it)
  is an offender. Same blocking contract (exit 0/1/2), same default
  terminal set (`Done|Parked`).
- `tests/ipm_iteration_drain_check.bats` rewritten for the file-only
  contract (hermetic `--todo-dir` fixtures, no `IPM_DRAIN_BOARD_JSON`
  injection needed since there's no board JSON left to inject) — 15 cases,
  including one that runs the gate with `gh` entirely absent from `PATH`.
- `ipm/SKILL.md` step 5a rewritten to describe the file-only gate;
  step 0's "Source of truth for iteration" paragraph, step 1, and step 5's
  `scheduled:`-advancement notes all dropped their board-mirror framing.
  `lifecycle.md`, `todo/SKILL.md`, `drive/SKILL.md`, `_session/task_claim.sh`,
  and `README.md` had their own stale GH-Project-board-as-source-of-truth
  references fixed in the same PR (see T20261005-639913's Closed section
  for the `ROADMAP_TARGET_REPO`-specific half of that sweep).
- Also fixed in passing (same root cause, same PR): `ipm/SKILL.md` step 3.4
  told the reader to "correct" a grilled task's status back to `Design` via
  `_session/status.sh`, but that script only ever mirrors a GH Project board
  field — it never writes the task file's frontmatter — so the correction
  silently never happened. Replaced with a direct frontmatter edit
  instruction; moot as a board-mirror call now that there's no board to
  mirror to, but the frontmatter bug was real and is now fixed regardless.
- Closes T20260929-120385 as superseded in the same PR: its "route the bare
  `gh project item-list` call through `_gh/gh.sh`" ask no longer applies —
  that call doesn't exist anymore.
- Verification: `bats tests/*.bats _docs/*.bats _slack/*.bats` green (7
  pre-existing unrelated failures in `compute_velocity.bats`/`eta.bats`/
  `gh-app-token.bats`, confirmed present on `main` before this branch, not
  touched by this change); `lint_tasks.py`/`lint-docs.sh`/
  `lint_paragraphs.py`/`lint_refs.py` clean on every changed file;
  `skill_score.py --check` passes (50 skills at or above baseline).

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — rewrote
  `tests/ipm_iteration_drain_check.bats` against the new contract before/alongside
  the script rewrite, red-then-green
- Verification (`superpowers:verification-before-completion`): yes — full
  bats suite + all doc/task lints + the skill-quality ratchet, before PR
