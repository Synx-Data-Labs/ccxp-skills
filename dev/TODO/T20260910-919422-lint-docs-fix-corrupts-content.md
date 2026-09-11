---
status: Open
estimation: 2h
source: conversation 2026-09-10 (cross-repo, from a 75033us/mirror session)
description: lint-docs.sh --fix silently corrupts prose and always lints repo-wide despite the docs promising per-file scoping
---

# T20260910-919422: lint-docs.sh --fix corrupts prose (+ -> -) and always lints repo-wide despite path args

## Problem

- **Type**: bug
- `lint-docs.sh --fix` (`_docs/lint-docs.sh`) is invoked across skills (`new-task`,
  `gcpr`, `/drive` Phase 7) as a "fix-then-continue, never blocks" step meant to
  be scoped to a single file — but two real defects surfaced running it from a
  consumer repo (`75033us/mirror`) on 2026-09-10.
- **Content corruption**: `--fix` (shelling out to `markdownlint-cli2 --fix`)
  rewrote a hard-wrapped prose line that happens to start with a bare `+` into
  `-`, silently changing meaning. CommonMark treats a line-leading `+ ` as a
  lazy-continuation list marker, so this may be "correct" markdownlint
  behavior on ambiguous input — but it ran unreviewed against permanent
  JOURNAL records. Confirmed instances (mirror repo, before this session
  reverted them):
  - `dev/JOURNAL/2026-08-25-T20260824-396236-edge-light-top-bottom-or-sides.md:66`:
    "real preview + real ambient room light" → "real preview - real ambient
    room light".
  - `dev/JOURNAL/2026-08-25-T20260825-411772-ai-eyeline-correction-implementation.md:~511`:
    "postDisplayUniversal + mirror" → "postDisplayUniversal - mirror".
  - `dev/JOURNAL/2026-08-26-T20260825-281213-ai-zoom-super-resolution.md:~584`:
    "one debug-gated inference call + measure" → "...call - measure".
- **Scope mismatch vs. documented caller expectation**: `_docs/lint-docs.sh:25-26`
  explicitly documents that path args "cannot narrow below the config" — the
  full `dev/**/*.md` glob always runs. But `new-task/SKILL.md:89` tells callers
  this bundle step is "scoped to just the file you created, never repo-wide" —
  directly contradicted. The mirror-repo session hit exactly this: linting one
  new task file touched three unrelated pre-existing JOURNAL files.
- **Unexplained PNG rewrite**: the same invocation also rewrote
  `dev/JOURNAL/T20260825-281213-assets/calibration-grid-portrait-for-display.png`
  (480829 → 844873 bytes) — a markdown linter should never touch a binary
  asset. Coincided with the same `lint-docs.sh --fix` call but not yet
  confirmed to share the same code path; needs its own check.
- Impact: any repo using the shared doc-lint bundle risks silent, unreviewed
  corruption of permanent JOURNAL records every time `--fix` runs, since the
  bundle's whole design is fix-then-continue and never surfaces a diff for
  review.
- Workaround used in the mirror-repo session: `git checkout --` on the four
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
