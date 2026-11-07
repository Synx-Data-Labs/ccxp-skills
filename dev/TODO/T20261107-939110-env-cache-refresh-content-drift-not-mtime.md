---
status: In Progress
estimation: 1
source: Owner report 2026-11-07 (job 1010) - ~/.claude/.env stayed stale though .env.tpl defines the OAuth token as an op:// reference
claimed_by: cc1-50ac6891:c4176cd40b4c22cc
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261107-939110: 1password-env-setup .envrc refreshes by mtime only; a hand-edited or later-written .env is never refreshed

## Problem

- **Type**: bug
- `1password-env-setup`'s generated `.envrc` skips `op inject` when
  `[ -s .env ] && [ ! .env.tpl -nt .env ]` (and the skill script uses
  `.env -nt .env.tpl`). Freshness is therefore mtime-only.
- Evidence on the owner machine: `.env.tpl` and `.envrc` mtime Oct 26 15:00,
  `.env.bak-20261026` Oct 26 15:00, but `.env` rewritten Oct 26 19:21 by
  something other than the generated `.envrc` (size 1407 to 1409 bytes). It
  now looks newer than the template, so every later load skips the refresh.
  Line 25 (`CLAUDE_CODE_OAUTH_TOKEN`) is a literal in `.env` while `.env.tpl`
  defines it as an `op://` reference.
- direnv is installed and `~/.claude/.envrc` is allowed, so this is not a
  direnv-allow failure. direnv only fires on `cd` in an interactive shell:
  `dev/daily-ccxp.sh` (launchd) and Claude Code processes `source` the cache
  directly and never trigger a refresh.
- The header comment already admits the gap (value rotation is not noticed).

## Proposed fix

- Content-based freshness: store a sha256 of `.env.tpl` next to the cache
  (`.env.tpl.sha256`); refresh when the hash differs or `.env` is missing or
  empty.
- Record the `.env` hash after each generated write; a mismatch means the
  cache was edited outside the generator, so refresh.
- When `op` needs the owner's unlock (biometric) or times out, print a clear
  message naming the command to run instead of silently skipping, and never
  fall through to loading a known-stale cache.
- Add a `refresh-env` helper (script) that any process (daily-ccxp.sh, a
  session hook) can call; `daily-ccxp.sh` in synxdb-build-pipeline then calls
  it before `source ~/.claude/.env` (separate task in that repo).
- BATS tests per repo standards: tpl-hash change, outside edit of `.env`,
  missing hash file, op failure path (stubbed `op`), skip when unchanged.
