---
name: journal-compact
description: Use when the user explicitly asks to compact a month of dev/JOURNAL/ into a digest
disable-model-invocation: false
argument-hint: "<month>"
---

> **Script paths**: `<skills-root>` = the "Base directory for this skill" shown at load, minus its last path component (the ccxp-skills root). Substitute that literal absolute path in every `<skills-root>/...` command below; never run them cwd-relative (`skill-conventions` §9).

Archive a completed month of `dev/JOURNAL/*.md` task-closure files into
`archive/<month>/` and (re)generate `dev/JOURNAL/<month>-digest.md` — see
`_journal/README.md` for the full algorithm.

## Argument

`<month>` — `YYYY-MM`, e.g. `2026-04`. Required.

## Workflow

1. Determine the repo root from the current working directory (the repo
   whose `dev/JOURNAL/` is being compacted — normally the current repo's
   top level, `git rev-parse --show-toplevel`).
2. Run:

   ```bash
   bash <skills-root>/_journal/compact.sh <month> --repo-root "$(git rev-parse --show-toplevel)"
   ```

3. Review the printed summary (files archived, digest path), then commit
   the result (`git add dev/JOURNAL/`, since `compact.sh` already staged
   the `git mv`s and the digest) and open it as a normal docs PR.
