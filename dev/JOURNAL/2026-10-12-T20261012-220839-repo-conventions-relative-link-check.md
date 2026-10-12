---
status: Done
estimation: 1
scheduled: 2026-10-12
source: "synxdb-team discussion 2026-10-12"
related: PR #314
description: Add relative-link existence validation to the repo-conventions lint (hard-gate capable) so consumer repos keep dev/ links current
claimed_by:
claimed_role:
---

# T20261012-220839: Add relative-link existence check to the repo-conventions lint

## TLDR

- **Type**: feature (code: new lint script + wiring + docs)
- **Problem**: no check verifies that relative links under `dev/` resolve; they rot when a task moves TODO -> JOURNAL/PARKING.
- **Solution**: `repo-conventions/scripts/lint_links.py` (read-only; `--fix` repairs by `T-id`), wired into `lint.sh`, plus a CI template and rollout docs.

## Problem

- Observed in a consumer repo (synxdb-team, 2026-10-12): about 101 of 251 relative links under `dev/**/*.md` are broken.
  - About 31 are `TODO/` paths that rotted when the task moved to JOURNAL/PARKING at close.
  - The rest are bare filenames and cross-repo `../../` paths.
- Verified: `repo-conventions/scripts/lint.sh` runs `lint_tasks.py`, `lint_refs.py`, `lint_identifiers.py` (`lint.sh` steps 4-6); none checks link targets.
- Impact: dead links in task/journal files, and no required status check to stop new ones (consumer ruleset has none).

## Context

- Siblings: `lint_refs.py` (read-only `--all` for `lint.sh`, `--fix` for `/gcpr`) is the pattern to mirror, with `test_lint_refs.py` as the unittest model.
- `lint_refs.py` already treats `[...](...)` spans as protected, so the two scripts do not conflict.
- The journal-move at close (`git mv dev/TODO/... dev/JOURNAL/...`) is the main rot source; T-id mirror links survive moves.

## Solution

- New `repo-conventions/scripts/lint_links.py` (Python, like its siblings), CLI `--all [repo]`, `--fix`, `--allow GLOB`, `--print-allowlist`.
  - Scans `dev/**/*.md`; ignores fenced code and inline code spans.
  - Skips external (`scheme:`), `mailto:`, pure `#anchor`; strips `#fragment`/`?query` before the existence check.
  - A target resolving outside the repo root is cross-repo: skipped by default (not verifiable from one clone).
  - Any other missing target is a violation (exit 1); read-only unless `--fix`.
- Allow-list: optional `dev/.link-allowlist` (one fnmatch glob per line, `#` comments) matched against the link target as written, plus `--allow`. `--print-allowlist` emits the currently-broken targets in that format as the rollout baseline.
- T-id repair: a missing target whose basename contains `T-id` that resolves in `dev/TODO|PARKING|JOURNAL` reports the new relative path; `--fix` rewrites it (idempotent: after the rewrite the target exists).
- `lint.sh` step 7 calls it. Default is warn (rollout-safe); `LINT_LINKS_HARD=1` makes it count as a violation. The CI template runs hard.
- CI template `repo-conventions/templates/link-check.yml`; `SKILL.md` gets a short section (rule, allow-list, required-check via ruleset `required_status_checks`, baseline-then-enable rollout); `lifecycle.md` gets the "link tasks by `T-id`" convention.
- Alternatives rejected:
  - Enable `markdownlint-cli2` MD051/link rules: checks anchors only, not file existence, and needs node.
  - Extend `lint_refs.py`: different purpose and mode semantics (it fixes, this gates); a separate script keeps each small.
  - Hard-fail by default in `lint.sh`: would break every consumer on upgrade (the 101-broken-links case).

## Root cause

- Link rot is structural: the close step `git mv dev/TODO/X dev/JOURNAL/date-X` (`lifecycle.md`) invalidates every relative path to the old location, and nothing re-checks links afterwards (assumed deliberate gap: `lint_refs.py` handles T-id/PR refs only, `lint_refs.py:1-60`).

## Test plan

- [x] Unit: `test_lint_links.py` covers broken/ok, fenced/inline code, external, cross-repo, fragment, allow-list, T-id suggestion, `--fix` idempotency, exit codes.
- [x] Integration: `tests/lint_links.bats` runs `lint.sh` on a fixture repo in warn and hard modes.
- [x] Local: run on this repo's own `dev/` and fix or allow-list what it finds.
- [x] CI: `tests` workflow passes (path filter covers `repo-conventions/scripts/**`).

## Done criteria

- [x] `lint_links.py` exits non-zero on a broken link, zero otherwise, read-only without `--fix` (`test_lint_links.py` exit-code and read-only tests).
- [x] Suggestion and `--fix` by `T-id`, idempotent (`test_lint_links.py` fix tests).
- [x] Allow-list documented and tested (`repo-conventions/SKILL.md` link-check section; `test_lint_links.py` allow tests).
- [x] Unit tests beside the `test_lint_*.py` siblings (`repo-conventions/scripts/test_lint_links.py`).
- [x] `lint.sh` invokes it with a hard mode (`repo-conventions/scripts/lint.sh` step 7; `tests/lint_links.bats`).
- [x] CI template added (`repo-conventions/templates/link-check.yml`).
- [x] Link-by-`T-id` convention documented (`lifecycle.md`, `repo-conventions/SKILL.md`).
- [x] Required-check and baseline/rollout docs (`repo-conventions/SKILL.md`).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/lint_refs.py` | `1-60` | sibling pattern (modes, `--all`/`--fix`) |
| `repo-conventions/scripts/lint.sh` | `95-115` | steps 4-6; new step 7 goes after |
| `repo-conventions/scripts/test_lint_refs.py` | `1-40` | unittest model |
| `.github/workflows/tests.yml` | `1-40` | path filter already covers `repo-conventions/scripts/**` |

## Follow-up

- synxdb-team adoption (fix/baseline links, enable the required check) is filed separately in that repo, not here.

## Closed (2026-10-12)

- Shipped in PR #PRNUM: `lint_links.py`, `test_lint_links.py`, `tests/lint_links.bats`, `lint.sh` step 7, `templates/link-check.yml`, docs in `repo-conventions/SKILL.md` and `lifecycle.md`.
- Dogfood: `--fix` repaired 6 rotted links in this repo's own `dev/` (5 JOURNAL files + `queue.md`).
- Quality probe: no shellcheck findings; coverage/code-scanning unavailable locally.
- External, not verified here: the `link-check.yml` template has not run in a consumer repo; synxdb-team adoption is filed in that repo.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — not invoked as a skill; unit and bats tests written alongside the code
- Verification (`superpowers:verification-before-completion`): yes — local unittest, bats, lint run before the PR
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): no — pending PR review
