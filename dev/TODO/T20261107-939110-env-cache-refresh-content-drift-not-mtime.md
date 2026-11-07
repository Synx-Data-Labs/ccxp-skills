---
status: Design
estimation: 3
source: Owner report 2026-11-07 (job 1010) - ~/.claude/.env stayed stale though .env.tpl defines the OAuth token as an op:// reference
claimed_by: cc1-50ac6891:c4176cd40b4c22cc
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261107-939110: 1password-env-setup .envrc refreshes by mtime only; a hand-edited or later-written .env is never refreshed

## TLDR

- **Type**: bug
- **Problem**: the generated `.envrc` (and the skill script) refresh `.env` by mtime only, so a hand-edited or later-written `.env` looks fresh forever; launchd and Claude Code processes never trigger direnv at all
- **Solution**: refresh by content (sha256 of `.env.tpl` plus of the generated `.env`), report drift by key name, fail loudly when `op` needs the owner's unlock, and ship a standalone `refresh-env` helper any process can call


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

## Context

- **Verified**: current checks are mtime-only: `1password-env-setup/scripts/1password-env-setup.sh` (`pes-envrc-content`, `pes-materialize-env`), and `tests/1password_env_setup.bats` asserts the mtime behaviour
- **Verified**: direnv fires only on an interactive `cd`; other processes `source` the cache directly
- **Assumed**: `op inject` blocks on the biometric prompt when the 1Password app is locked, so a bounded wait is needed
- Git archaeology: the mtime check was a deliberate simplification (header comment admits value rotation is not noticed), not a regression

## Root cause

- Freshness is a proxy (mtime ordering) for "cache equals inject(template)". Any write to `.env` that is not the generator (hand edit, restore from backup) flips the proxy to "fresh" without the content being right.
- The proxy also says nothing about the template content changing without a newer mtime (copy preserving mtime).

## Solution

- **State files** next to the cache: `.env.tpl.sha256` (hash of the template at last refresh) and `.env.sha256` (hash of the `.env` the generator wrote). Hashes only; never values.
- **Fresh** iff `.env` is non-empty AND both stored hashes match the current files. Otherwise stale, with the reason printed (`tpl-changed`, `env-edited-outside-generator`, `no-state`, `missing`).
- **Drift report** (`refresh-env --check`): key names (never values) that the template defines as `op://` references but whose `.env` line is missing or still an unresolved `op://` string, plus the `env-edited-outside-generator` reason when the `.env` hash no longer matches. Exit 0 fresh, 1 stale.
- **Refresh**: `op inject` into a temp file, atomically moved over `.env` only on success, then both hashes recorded. A failure never clobbers the old cache and never records a hash, so the next call retries.
- **Biometric**: `op inject` runs with a bounded wait (`REFRESH_ENV_OP_TIMEOUT`, default 60s). On timeout or failure, print a clear message naming the command to run in an unlocked terminal and exit 75; callers must not load the stale cache. `op` missing exits 10 with install guidance.
- **Helper**: `1password-env-setup/scripts/refresh-env.sh`, sourceable and function-wrapped; the skill copies it to `<dir>/refresh-env` (self-contained, executable, idempotent) so launchd, session hooks and scripts call `<dir>/refresh-env`.
- **.envrc template** calls `./refresh-env .` and runs `dotenv .env` only when it succeeds; otherwise `log_error` with the same message.
- **Skill script**: `pes-materialize-env` delegates to the same function, mapping exit 10 (op missing) to the existing skip-with-guidance behaviour.
- **Alternatives rejected**: hashing `op://` resolved values (stores secret-derived data); comparing `.env` values to `op read` (needs biometric on every check); keeping mtime and adding hash only for the template (misses the hand-edit case in this incident).

## Test plan

- [ ] BATS (fake `op` stub only, fake values): tpl hash change refreshes; outside edit of `.env` refreshes; missing hash file refreshes; unchanged skips without calling `op`
- [ ] BATS: `op` failure and timeout exit 75, keep the old `.env`, record no hash, print the unlock message
- [ ] BATS: `--check` reports key names only (no values) for missing or unresolved keys
- [ ] BATS: generated `.envrc` content and that the skill copies an executable `refresh-env`
- [ ] CI: `bats` job green on the PR
- [ ] Post-merge, owner: re-run `/1password-env-setup` on `~/.claude`, approve the biometric prompt once

## Done criteria

- [ ] Content-hash freshness: `tests/1password_env_setup.bats` hash tests
- [ ] Drift detection by key name: `tests/1password_env_setup.bats` `--check` tests
- [ ] Clear unlock message, no silent skip: `tests/1password_env_setup.bats` op-failure tests
- [ ] `refresh-env` helper installed by the skill: `1password-env-setup/scripts/refresh-env.sh`, `tests/1password_env_setup.bats` install test
- [ ] SKILL.md documents the new flow: `1password-env-setup/SKILL.md`

## Skills invoked

- Design written under `/drive` Phase 2
