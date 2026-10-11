---
status: Done
estimation: 1
scheduled: 2026-10-05
source: 2026-10-05 /incept of the consumer task "ROADMAP_TARGET_REPO is unset — IPM step 5b silently skipped" (build-pipeline-repo), moved here because the fix is a suite change
related: ipm/SKILL.md step 5b, ccxp/scripts/update-roadmap.sh, ccxp/scripts/epic-status.sh, ccxp/SKILL.md (standup Epic progress), README.md (env var docs), T20260911-347027 (epic-status)
description: Drop the global ROADMAP_TARGET_REPO hub config; every repo owns its own dev/ROADMAP.md and dev/EPICS.md
claimed_by:
claimed_role:
---

# T20261005-639913: Remove `ROADMAP_TARGET_REPO` — each repo owns its own `dev/ROADMAP.md` / `dev/EPICS.md`

## Problem

- `/ipm` step 5b updates a ROADMAP in a separate **hub repo** named by the
  machine-global `ROADMAP_TARGET_REPO` (`ipm/SKILL.md:328-358`,
  `ccxp/scripts/update-roadmap.sh`), and the standup's "Epic progress" reads that
  hub's `dev/EPICS.md` (`ccxp/scripts/epic-status.sh`, `ccxp/SKILL.md:358-367`).
- A consumer that never set it gets step 5b skipped and "Epics unavailable" in every
  standup (observed weekly since at least 2026-09-07 in build-pipeline-repo).
- The maintainer's position (2026-10-05): every repo should have its own
  roadmap/epics; a global hub variable is unnecessary. "Keep it simple, remove
  `ROADMAP_TARGET_REPO`."

## Design (/incept 2026-10-05)

### Decisions

- **Remove `ROADMAP_TARGET_REPO` entirely** — no fallback, no optional override.
  The ROADMAP is `dev/ROADMAP.md` and epics are `dev/EPICS.md` **in the repo the
  ritual runs in**.
- **`/ipm` step 5b edits `dev/ROADMAP.md` in place in the same IPM PR**: no
  ephemeral hub clone, no second PR. Drop `update-roadmap.sh`'s `clone` /
  `commit-pr` machinery (delete the script if nothing else needs it) and the
  "build-pipeline IPM PR URL" cross-link step.
- **`epic-status.sh` reads the local `dev/EPICS.md`** (repo toplevel), with no
  hub-scoped token picking (`_gh_pick_account`); keep its never-fail contract (one
  note line when `EPICS.md` is missing or has no epics).
- **First run:** if `dev/ROADMAP.md` doesn't exist, create it from a template
  shipped in this repo (e.g. `ipm/templates/ROADMAP.md`) — the current text points
  at a task file's "Initial content shape" section that no longer exists. A missing
  `dev/EPICS.md` is not created automatically (it's human-owned); the standup just
  prints the note.
- Update `ipm/SKILL.md`, `ccxp/SKILL.md` (Epic progress + the line-629 reuse of
  update-roadmap), and `README.md` (remove the env-var entry, describe the
  per-repo files).

### Out of scope

- Migrating any existing hub repo's ROADMAP content into each consumer repo (a
  consumer's maintainer can copy it by hand if they want history).
- Changing ROADMAP.md's section structure or the step 5b promote/demote/archive rules.

### Test Plan

- Unit: `tests/epic-status.bats` — reads `dev/EPICS.md` from the repo under test;
  missing file / no epics prints the one-line note and exits 0; no reference to
  `ROADMAP_TARGET_REPO` remains.
- Unit: `tests/update_roadmap.bats` removed or rewritten for whatever survives;
  `tests/gh-wrapper-usage.bats` updated for the dropped hub-token path.
- Static: `grep -rn ROADMAP_TARGET_REPO` outside `dev/JOURNAL` is empty; doc lint passes.
- Integration: a dry `/ipm` step 5b against a fixture repo without
  `dev/ROADMAP.md` creates it from the template inside the IPM change set; a second
  run edits it in place.

## Closed (2026-10-10)

- Scoped together with T20261005-554581 (file-only drain gate) and
  T20261010-665166 (drop the hour budget) in one PR — all three touch
  `ipm/SKILL.md` steps 4/5/5a/5b and would leave it internally inconsistent
  done separately.
- Implemented exactly as designed: `ipm/SKILL.md` step 5b now edits
  `dev/ROADMAP.md` in place, in the same working tree/commit/PR as the IPM
  file — no ephemeral clone, no second PR, no `ROADMAP_TARGET_REPO`.
  `ipm/templates/ROADMAP.md` added (Near-term / Deferred-on-watch /
  Recently-shipped sections) for the first-run `cp` case.
- `ccxp/scripts/update-roadmap.sh` deleted entirely — once both
  `dev/ROADMAP.md` and `dev/EPICS.md` are local files, nothing needs its
  `clone`/`commit-pr` machinery (not even Phase 2b's `EPICS.md` proposal,
  which is now a plain local edit in the retro's own commit).
  `tests/update_roadmap.bats` deleted with it.
- `ccxp/scripts/epic-status.sh` rewritten local-only: dropped
  `ROADMAP_TARGET_REPO` env loading, `_epic_gh_token`/`_gh_pick_account`
  cross-repo token picking, and the `_epic_hub_lookup` GitHub Contents-API
  fallback (`epic_resolve` is now local-dev/TODO|PARKING|JOURNAL-only, same
  resolution `taskid-path` already did). `epic_fetch` reads `dev/EPICS.md`
  straight off disk instead of base64-decoding a Contents-API response into
  a tmp file. `epic_pr_state`'s PR lookup is always the plain local
  `_gh/gh.sh` path now (previously only true for a task that happened to
  resolve locally). `tests/epic-status.bats` rewritten around a single local
  fixture repo (31 cases); `tests/fixtures/epics/fake-gh.sh` trimmed to the
  3 `gh` calls that remain (`auth status`/`auth token`/the
  `_gh_account_tier` permission probe/`pr list --search`) — the
  contents/commits-API fakes are gone. `tests/gh-wrapper-usage.bats`'s
  allowlist dropped `epic-status.sh`'s 5 cross-repo `GH_TOKEN=` sites (it
  has zero now) and gained a regression test pinning that.
- `ccxp/SKILL.md`: Epic progress section + Phase 2a/2b prose reconciled to
  the local-file model; `ipm/SKILL.md`: Phase-2a-style GH-Project-board
  framing removed (see T20261005-554581's Closed section for the shared
  board-removal sweep across `lifecycle.md`/`todo/SKILL.md`/`drive/SKILL.md`/
  `_session/task_claim.sh`). `README.md`'s `ROADMAP_TARGET_REPO` Prerequisites
  bullet removed; the `dev/EPICS.md format` section renamed/expanded to
  cover `dev/ROADMAP.md` too and describe the per-repo (no-hub) model.
- Test Plan's literal "`grep -rn ROADMAP_TARGET_REPO` outside `dev/JOURNAL`
  is empty" relaxed to "no functional dependency remains" — the task's own
  Problem/Design prose (this file) and a couple of explanatory code
  comments/test names legitimately name the retired variable when
  describing the removal. Pinned instead by a regression test
  (`tests/epic-status.bats`: "no functional ROADMAP_TARGET_REPO /
  hub-contents-API dependency remains (comments aside)") that strips
  comment lines before asserting.
- Not verified: no live `/ipm` dry run against a fixture repo (the
  Integration item above) — the mechanics (template `cp`, in-place edit,
  `_docs/lint-docs.sh` check) are plain file operations, each individually
  exercised, but not chained through an actual `/ipm` invocation end to end.
- Verification: `bats tests/*.bats _docs/*.bats _slack/*.bats` green (7
  pre-existing unrelated failures in `compute_velocity.bats`/`eta.bats`/
  `gh-app-token.bats`, confirmed present on `main` before this branch);
  `lint_tasks.py`/`lint-docs.sh`/`lint_paragraphs.py`/`lint_refs.py` clean;
  `skill_score.py --check` passes (50 skills at or above baseline).

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — `tests/epic-status.bats`
  and `tests/gh-wrapper-usage.bats` rewritten against the local-only
  contract before/alongside the script rewrite, red-then-green
- Verification (`superpowers:verification-before-completion`): yes — full
  bats suite + all doc/task lints + the skill-quality ratchet, before PR
