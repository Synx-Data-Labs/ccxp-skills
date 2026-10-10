---
status: Open
estimation: 1
source: this conversation, 2026-10-10
---

# T20261010-274793: Add the cross-repo rule to the conventions layer and guidelines

## Problem

- **Type**: chore
- The rule (fresh local clone, branch, PR in the target repo; never `cd` into an existing clone) exists only in `drive/SKILL.md` Phase 1.5 (lines ~132-189, 85, 335, 575) and `gotchas.md:33`.
- It is missing from `repo-conventions/SKILL.md`, `repo-conventions/templates/guidelines.md`, `dev/guidelines.md` and `lifecycle.md`.
  - `lifecycle.md:51` and `:178-195` mention target-repo without saying how to work in it.
- Candidate homes (pick one in design):
  - A "Cross-repo work" subsection in `repo-conventions/templates/guidelines.md`, mirrored in `dev/guidelines.md`.
  - `lifecycle.md` after line 195, with the guidelines linking to it.
- Root cause (why we missed it): the rule lived in one skill (`/drive`), not in the conventions layer every consumer repo and non-`/drive` workflow reads.
  - Add a short root-cause note to the task's design doc and the fix PR.
  - Propose prevention: a rule that binds more than one skill must live in the conventions layer (guidelines/lifecycle) with skills linking to it, and a periodic audit (or lint) for rules found in only one SKILL.md.
- Done: the rule is stated once in the chosen home, `drive/SKILL.md` and `gotchas.md` link to it, `dev/guidelines.md` mirrors the template, and the prevention step is recorded.
