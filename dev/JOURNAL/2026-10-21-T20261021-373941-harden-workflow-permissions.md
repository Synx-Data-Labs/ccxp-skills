---
status: Done
estimation: 1
source: CI secret audit, this conversation, 2026-10-21
description: Least-privilege permissions and SHA-pinned actions for ccxp-skills workflows; CODEOWNERS for .github/
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261021-373941: Harden ccxp-skills workflow permissions and action pins

## Problem

- **Type**: chore
- Repo is public; `.github/workflows/markdown-lint.yml` and `tests.yml` declare no `permissions:`, so GITHUB_TOKEN gets the repo default.
- Third-party actions are pinned by mutable tag (`actions/checkout@v6`, `setup-python@v6`, `setup-go@v6`).
- No CODEOWNERS, so `.github/**` changes need no designated review.

## Fix

- PR #408: top-level `permissions: contents: read` on both workflows; `actions/checkout`, `setup-python`, `setup-go` pinned to the SHAs of their v6 tags.
- This PR: `.github/CODEOWNERS` with `/.github/ @xinzweb`.

| File | Change |
|------|--------|
| `.github/workflows/markdown-lint.yml` | permissions, SHA pins |
| `.github/workflows/tests.yml` | permissions, SHA pins |
| `.github/CODEOWNERS` | new |

## Next steps

- Enforcement needs the branch-protection/ruleset toggle "Require review from Code Owners"; `main` currently has no protection. Owner decides separately.
