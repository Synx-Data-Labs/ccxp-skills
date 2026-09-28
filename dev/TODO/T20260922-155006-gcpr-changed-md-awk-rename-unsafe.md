---
status: Open
scheduled: 2026-10-05
estimation: 15m
source: PR #64's independent review, 2026-09-22 — the same `awk '{print $2}'` pattern this PR fixed for `CHANGED_MD` also exists at two other call sites in the same file
related: T20260910-919422
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
