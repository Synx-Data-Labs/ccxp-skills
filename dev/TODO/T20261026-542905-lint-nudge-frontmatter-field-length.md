---
status: Open
estimation: 1
source: "T20260901-121577 (synxdb-build-pipeline), via a 2026-10-26 triage"
description: "warn-only lint nudge for over-long task frontmatter field values"
---

# T20261026-542905: lint_tasks.py nudge for over-long frontmatter field values

## Problem

- **Type**: chore
- Convention (one short line per frontmatter field) was documented in synxdb-build-pipeline `dev/pre-commit-checklist.md` by T20260901-121577.
- That task did NOT ship a lint nudge: the frontmatter lint lives here, in `repo-conventions/scripts/lint_tasks.py`.
- Long values (paragraph-length `source`/`related`/`status`) are what trigger YAML truncation and parse bugs.
- Done looks like: a warn-only (non-blocking) nudge when a field value exceeds ~200 chars, plus a test; priority low.
