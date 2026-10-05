---
status: Design — /incept 2026-10-05 in a consumer repo (build-pipeline-repo); design settled by the maintainer there
estimation: 1
scheduled: 2026-10-05
source: 2026-10-05 /incept of the consumer task "ROADMAP_TARGET_REPO is unset — IPM step 5b silently skipped" (build-pipeline-repo), moved here because the fix is a suite change
related: ipm/SKILL.md step 5b, ccxp/scripts/update-roadmap.sh, ccxp/scripts/epic-status.sh, ccxp/SKILL.md (standup Epic progress), README.md (env var docs), T20260911-347027 (epic-status)
description: Drop the global ROADMAP_TARGET_REPO hub config; every repo owns its own dev/ROADMAP.md and dev/EPICS.md
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
