---
status: In Progress
estimation: 1
source: CI secret audit, this conversation, 2026-10-21
description: Least-privilege permissions and SHA-pinned actions for ccxp-skills workflows; CODEOWNERS for .github/
claimed_by: cc1-50ac6891:03e07097482518d6
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261021-373941: Harden ccxp-skills workflow permissions and action pins

## Problem

- **Type**: chore
- Repo is public; `.github/workflows/markdown-lint.yml` and `tests.yml` declare no `permissions:`, so GITHUB_TOKEN gets the repo default.
- Third-party actions are pinned by mutable tag (`actions/checkout@v6`, `setup-python@v6`, `setup-go@v6`).
- No CODEOWNERS, so `.github/**` changes need no designated review.
