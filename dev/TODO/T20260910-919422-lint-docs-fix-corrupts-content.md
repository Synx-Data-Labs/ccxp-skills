---
status: Open
estimation: 2h
source: conversation 2026-09-10 (cross-repo, from a downstream consumer-repo session)
description: lint-docs.sh --fix silently corrupts prose and always lints repo-wide despite the docs promising per-file scoping
---

# T20260910-919422: lint-docs.sh --fix corrupts prose (+ -> -) and always lints repo-wide despite path args

## Problem

- **Type**: bug
- `lint-docs.sh --fix` (`_docs/lint-docs.sh`) is invoked across skills (`new-task`,
  `gcpr`, `/drive` Phase 7) as a "fix-then-continue, never blocks" step meant to
  be scoped to a single file — but two real defects surfaced running it from a
  consumer repo (a downstream skills consumer) on 2026-09-10.
- **Content corruption**: `--fix` (shelling out to `markdownlint-cli2 --fix`)
  rewrote a hard-wrapped prose line that happens to start with a bare `+` into
  `-`, silently changing meaning. CommonMark treats a line-leading `+`
  followed by a space as a lazy-continuation list marker, so this may be
  "correct" markdownlint
  behavior on ambiguous input — but it ran unreviewed against permanent
  JOURNAL records. Three confirmed instances in the consumer repo (reverted
  before that session committed), each a hard-wrapped prose line whose
  continuation happened to begin with a bare `+`:
  - `dev/JOURNAL/<entry-a>.md:66`: "<term> + <term>" → "<term> - <term>".
  - `dev/JOURNAL/<entry-b>.md:~511`: "<identifier> + <term>" → "<identifier> - <term>".
  - `dev/JOURNAL/<entry-c>.md:~584`: "<phrase> + measure" → "<phrase> - measure".
- **Scope mismatch vs. documented caller expectation**: `_docs/lint-docs.sh:25-26`
  explicitly documents that path args "cannot narrow below the config" — the
  full `dev/**/*.md` glob always runs. But `new-task/SKILL.md:89` tells callers
  this bundle step is "scoped to just the file you created, never repo-wide" —
  directly contradicted. The consumer-repo session hit exactly this: linting one
  new task file touched three unrelated pre-existing JOURNAL files.
- **Unexplained PNG rewrite**: the same invocation also rewrote
  a PNG under `dev/JOURNAL/<entry-c>-assets/`
  (480829 → 844873 bytes) — a markdown linter should never touch a binary
  asset. Coincided with the same `lint-docs.sh --fix` call but not yet
  confirmed to share the same code path; needs its own check.
- Impact: any repo using the shared doc-lint bundle risks silent, unreviewed
  corruption of permanent JOURNAL records every time `--fix` runs, since the
  bundle's whole design is fix-then-continue and never surfaces a diff for
  review.
- Workaround used in the consumer-repo session: `git checkout --` on the four
  unintended file changes before committing the actual task file being filed
  there.

## Root cause candidates (not yet confirmed — for the design phase)

- `markdownlint-cli2 --fix`'s ul-style normalization (likely MD004) treating a
  line-leading bare `+` as a list marker on prose never meant as a list.
- `new-task/SKILL.md:89`'s "scoped to just the file... never repo-wide" claim
  is false against `_docs/lint-docs.sh`'s own documented behavior (lines
  25-26) — needs either `lint-docs.sh` gaining real per-path scoping, or every
  skill making this claim (at least `new-task`, check `gcpr`) being corrected
  to stop promising narrowing that doesn't exist.
- PNG mutation: unconfirmed whether `markdownlint-cli2` itself touched it, or
  something else running in the same working tree did.
