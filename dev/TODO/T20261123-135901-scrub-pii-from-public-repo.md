---
status: In Progress
estimation: 2
source: Owner request 2026-11-23 (job 1359)
type: chore
description: Remove personal names, roles, account names and similar PII from docs and task files of the public repo
---

# T20261123-135901: Scrub PII from the public repo

## Problem

- Owner's words: "remove any PII info from the public repo."
- PR #693 (T20261122-234265) copied a spec verbatim; it named the owner and role, and described personal vs work setup
- A repo scan found more personal names, a role word, account handles and a work email in `dev/` docs and task files

## Design

- Replace names with "the owner" / "the maintainer"; replace account handles with `<owner-account>`; keep technical content
- Edit only docs, journals and task files
- Do not edit code, tests, fixtures or `.github/CODEOWNERS` (functional); list them for the owner
- Git history keeps the old text; rewriting history is not authorized (recommend only)

## Acceptance criteria

- [x] No personal names, role words, emails or account handles left in `dev/**/*.md` and `hud/README.md`
- [x] Remaining matches in code/tests/fixtures/CODEOWNERS listed in the PR
