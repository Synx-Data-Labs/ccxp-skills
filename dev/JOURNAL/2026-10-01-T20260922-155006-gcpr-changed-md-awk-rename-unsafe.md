---
status: Done
scheduled: 2026-09-28
estimation: 1
source: PR #64's independent review, 2026-09-22 — the same `awk '{print $2}'` pattern this PR fixed for `CHANGED_MD` also exists at two other call sites in the same file
related: T20260910-919422
claimed_by:
claimed_role:
---

# T20260922-155006: `gcpr/SKILL.md`'s `CHANGED_TASKS`/`CHANGED_REFS` extraction is rename/delete-unsafe, same bug as the fixed `CHANGED_MD` one

## Problem

- **Type**: bug
- `T20260910-919422` ([PR #64](https://github.com/Synx-Data-Labs/ccxp-skills/pull/64)) fixed `gcpr/SKILL.md`'s `CHANGED_MD` extraction
  (`git status --porcelain | awk '{print $2}'`) because it grabbed the *old*
  path for a renamed `.md` file, and passed already-deleted paths through
  for a `D` status — `gcpr/SKILL.md:61` now skips `D`-status entries and
  strips the `old ->` prefix on renames.
- The exact same unfixed pattern is copy-pasted twice more in the same
  file, feeding two other `--changed`-taking scripts:
  - `gcpr/SKILL.md:82` — `CHANGED_TASKS`, feeds
    `lint_paragraphs.py --changed`
  - `gcpr/SKILL.md:97` — `CHANGED_REFS`, feeds
    `python3 ../repo-conventions/scripts/lint_refs.py --fix --changed`
- Left unfixed by T20260910-919422 because both were pre-existing,
  unrelated to that task's own scoping change — but they share the
  identical failure mode: a renamed `dev/TODO/*.md` or `dev/JOURNAL/*.md`
  file silently gets the *old* (nonexistent) path passed to
  `lint_paragraphs.py`/`lint_refs.py --changed`, and a deleted one gets a
  path that no longer exists.
- Done looks like: apply the same fix already landed at
  `gcpr/SKILL.md:61-64` (skip `D`-status, strip `.* ->` prefix) to both
  remaining call sites, or extract the pattern into one shared snippet if
  that reads better inline in the doc.

## Context

- `gcpr/SKILL.md:82,97` — the two unfixed call sites.
- `gcpr/SKILL.md:61-64` — the already-fixed reference implementation.

## Closed (2026-10-01)

- Shipped in [PR #211](https://github.com/Synx-Data-Labs/ccxp-skills/pull/211).
- Applied the same skip-`D`-status / strip-`.* ->`-prefix awk pattern already
  landed at `gcpr/SKILL.md:61-64` to both remaining call sites:
  `CHANGED_TASKS` (`gcpr/SKILL.md:82`, now `:85`) and `CHANGED_REFS`
  (`gcpr/SKILL.md:97`, now `:100`).
- Verified by manually running the awk snippet against simulated
  `git status --porcelain` output covering modify / delete / rename /
  untracked rows — deletes are skipped, renames resolve to the new path.
  No bats tests apply — this is a bash snippet embedded in a `.md` doc,
  docs-class per the Phase 3.0 classifier, not a standalone script.
- `bash _docs/doc-impact.sh origin/main` reported `docs-only change` —
  no other doc needed updating.
- No follow-up tasks filed — the fix is complete and scoped exactly to
  the two call sites named in the Problem section.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (bash
  snippet inside `gcpr/SKILL.md`, no standalone script/bats harness)
- Verification (`superpowers:verification-before-completion`): yes —
  manually exercised the awk pattern against representative
  `git status --porcelain` input before opening the PR
- Systematic debugging (`superpowers:systematic-debugging`): no — the
  fix was a direct application of an already-proven pattern, no
  debugging needed
- Receiving code review (`superpowers:receiving-code-review`): no — no
  review comments received at close time
