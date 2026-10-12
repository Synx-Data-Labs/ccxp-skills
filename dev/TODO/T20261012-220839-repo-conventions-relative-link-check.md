---
status: Design
estimation: 1
source: "synxdb-team discussion 2026-10-12"
description: Add relative-link existence validation to the repo-conventions lint (hard-gate capable) so consumer repos keep dev/ links current
claimed_by: cc1-50ac6891:da7297ceb68effbb
claimed_role: interactive
---

# T20261012-220839: Add relative-link existence check to the repo-conventions lint

## Problem

- Consumer repos have no enforced check that relative links under `dev/` resolve.
  - Observed in one consumer repo (synxdb-team): `markdownlint-cli2` workflow has no link-existence rule (MD051 disabled).
  - `repo-conventions/scripts/lint.sh`, `lint_tasks.py`, `lint_refs.py` do not verify relative link targets exist.
  - `lint.sh` is not run by any workflow there, and no lint is a required status check on `main` (ruleset has no `required_status_checks`).
- Scan of that repo's `dev/**/*.md`: ~101 of 251 relative links broken.
  - ~31 are `TODO/` paths that rot when a task moves to JOURNAL/PARKING at close.
  - The rest: bare filenames and cross-repo `../../` paths.
- Done = any ccxp-skills consumer can run one command (and one CI template) that fails on broken `dev/` links.

## Proposed design

- New `check-links` script in `repo-conventions/scripts/`, next to `lint_refs.py`.
  - Follow repo script standards (idempotent; sourceable function-wrapped bash, or Python like its siblings); read-only by default.
  - Checks every relative `[text](path)` target in `dev/**/*.md` exists.
- Task-ID-aware repair.
  - Missing target whose filename contains a `T<id>` that resolves in TODO/PARKING/JOURNAL: report the new path.
  - Optional `--fix` rewrites the link to the resolved path.
- Allow-list for cross-repo and external paths.
- Convention doc: link tasks by `T<id>` (mirror link), not by relative path into TODO/JOURNAL/PARKING.
- Wire into `lint.sh`; ship a reusable CI workflow template/snippet.
- Docs for making it a required check (repo admin; ruleset `required_status_checks`).
- Rollout note: fix or baseline existing broken links before enabling the hard gate.

## Acceptance criteria

- [ ] `check-links` exists, exits non-zero on a broken relative link, zero otherwise; read-only unless `--fix`.
- [ ] Missing-target report suggests the new path when a `T<id>` resolves in TODO/PARKING/JOURNAL; `--fix` applies it idempotently.
- [ ] Allow-list mechanism documented and tested (cross-repo, external).
- [ ] Unit tests alongside the existing `test_lint_*.py` pattern.
- [ ] `lint.sh` invokes it; a hard-gate mode is available.
- [ ] CI workflow template added under `repo-conventions/templates/`.
- [ ] Convention (link by `T<id>`) documented in the conventions layer and `lifecycle.md` as needed.
- [ ] Required-check and baseline/rollout docs written.

## Follow-up

- synxdb-team adoption (fix/baseline links, enable the required check) is filed separately in that repo, not here.
