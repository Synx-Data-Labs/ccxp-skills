---
status: Coding
estimation: 2h
source: conversation 2026-09-10 (cross-repo, from a downstream consumer-repo session)
description: lint-docs.sh --fix silently corrupts prose and always lints repo-wide despite the docs promising per-file scoping
claimed_by: cc1-9a4074da:94a83ff0e786a885
scheduled: 2026-09-14
claimed_role: interactive
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

## Confirmed recurrence (2026-09-22, lsc-pa repo)

Same failure mode hit again in a second, unrelated consumer repo (`75033us/lsc-pa`,
via `/gcpr`'s doc-lint guard step during an unrelated task-parking commit), with full
concrete (non-redacted) evidence this time:

- **Same `+` → `-` corruption, 5 confirmed instances, 3 files** (all wrapped-continuation
  prose lines beginning with a literal `+` meaning "and/plus", none of them list items):
  - `dev/JOURNAL/T20260714-963726-training-tutorial-md-content.md:33`: `+ PDF)` → `- PDF)`
  - `dev/JOURNAL/T20260905-058581-sunday-0906-service-pptx.md:104`: `+ \`.rels\`)` → `- \`.rels\`)`
  - `dev/JOURNAL/T20260916-807752-sunday-0920-lyrics-mix.md:133,221,234`: three instances,
    same pattern
- **New variant, not previously documented**: dropped the space after a comma in 2 more
  lines (not a `+`/`-` flip, but the same "fix" pass touching content it shouldn't):
  - `dev/JOURNAL/T20260409-655304-skill-reorg.md:14`: `*.lyrics.md,*.service.md` (space
    stripped from `*.lyrics.md, *.service.md`)
  - `dev/JOURNAL/T20260717-493786-highlight-reel-skill.md:108`: `_013.mp4,_014.mp4` (space
    stripped from `_013.mp4, _014.mp4`)
- **Scope-mismatch also reconfirmed**: this run was meant to accompany a single-file
  task-parking commit but touched ~45 unrelated pre-existing `dev/JOURNAL`/`dev/TODO`
  files repo-wide, matching this task's existing "always lints repo-wide" finding.
- **How it was caught this time**: an independent review agent (dispatched per
  `address-pr/SKILL.md` step d, given only the PR diff and no implementation context)
  flagged all 7 corrupted lines by cross-referencing against `origin/main`'s actual
  content — none of it was caught by the tool itself or by the author before review.
  All 7 reverted before merge (`75033us/lsc-pa#29`).
- This confirms the `+` → `-` bug is not a one-off from the 2026-09-10 session — it's
  a real, reproducible defect in `markdownlint-cli2 --fix`'s handling of a leading `+`
  that will keep silently corrupting permanent JOURNAL records in every consumer repo
  until fixed. The comma-spacing drop is a separate, so-far-unexplained observation
  from the same lint pass — not yet confirmed to share a root cause with the `+`/`-`
  flip (comma-spacing normalization isn't a documented markdownlint-cli2/MD004
  behavior); flag it as a second symptom to investigate during the design phase,
  not an established fact.

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
