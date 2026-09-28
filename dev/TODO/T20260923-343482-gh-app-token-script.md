---
status: Open
estimation: 2d
source: split off a larger "App-auth merge workflow" task (2026-09-23); the org-specific rollout moved out of this repo
owner: Xin Zhang (Shine)
---

# T20260923-343482: Add `_gh/gh-app-token.sh` — mint GitHub App installation tokens

## Problem

- Some workflows need a GitHub identity distinct from the human `gh` account — e.g. a bot that submits a formal PR approval or arms auto-merge.
- A GitHub App is the right primitive (short-lived, repo-scoped tokens, minimal permissions), but no helper here mints an installation token.
  - Callers would each re-implement JWT signing and the token exchange.

## Design

- **New**: `_gh/gh-app-token.sh` — a generic helper that mints a short-lived installation token for a GitHub App and prints it to stdout.
  - Inputs: App ID, private key, and the target repo (to scope the token).
  - Credential source is the caller's choice (env vars, a secret manager CLI); the script does not hardcode any.
  - Flow: sign an RS256 JWT with the private key, look up the repo's installation, exchange for an installation token.
- Follows the repo script standards (`dev/guidelines.md`): function-wrapped, sourceable, idempotent, `set -euo pipefail`.
- Out of scope: any change to `address-pr` merge behavior or branch protection — consumers wire the token in themselves.

## Test plan

- [ ] bats coverage with `curl`/`gh` and `openssl` stubbed: JWT header/claims shape, installation lookup, token output, and non-zero exit on missing inputs or API errors.
- [ ] Manual: mint a token for a real App + repo, then use it for a read call on a real PR via `GH_TOKEN=<token> gh pr view`.

## Done criteria

- [ ] `_gh/gh-app-token.sh` merged with tests.
- [ ] Usage documented (header comment or `_gh/` docs), with no company-specific names.
