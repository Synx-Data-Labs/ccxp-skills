---
status: Done
estimation: 1
source: owner request, this conversation, 2026-11-09
description: HUD queue.source defaults to default-branch, not the local working tree
claimed_by:
claimed_role:
scheduled: 2026-11-09
---

# T20261109-338243: HUD queue source defaults to the GitHub default branch

## TLDR

- **Type**: feature
- **Problem**: an unset `queue` reads `dev/TODO` from this clone's working tree, which lags origin (README line 122: one clone 72 commits behind showed 12 claimed, origin showed 6).
- **Solution**: unset or invalid `queue.source` becomes `default-branch`; `"working-tree"` stays as an explicit opt-in; the never-fatal fallback is kept.

## Problem

- Owner: the HUD default config should always read the current repo's default branch from GitHub, not the local clone.
- Verified defaults today (all `working-tree`):
  - `hud/register.tsx:163`: `queue_source: cfg.queue?.source ?? 'working-tree'`
  - `hud/scripts/hud-data.sh:65`: any `queue_source` other than `default-branch` becomes `working-tree`
  - `hud/README.md:30` (Config table) and `:122` (Queue cell) document it as the default

## Context

- Mechanism already exists and is tested (`tests/hud_queue_source.bats`, T20261104-420419): `sl-queue-json` in `hud/scripts/hud-lib.sh:487` reads `refs/remotes/origin/<default>` via `git archive` into a temp dir, no checkout.
- Fetch target verified (`hud/scripts/hud-lib.sh` `_sl-queue-fetch-run`): `git fetch ... origin <branch>`, where `<branch>` comes from `sl-default-branch` (`refs/remotes/origin/HEAD`, else `origin/main`, else `origin/master`). Remote-tracking refs only; local branches are never read or written.
- Fallback when origin is unreadable: `{"source":"working-tree","fallback":true}`, rendered as `queue (working tree, origin unavailable)`.
- Assumed and accepted: `origin/HEAD` is set at clone time, so a repo whose default branch was renamed later keeps the old name until `git remote set-head origin -a`; unchanged by this task.

## Solution

- Default flips at the two caller edges only; the library function keeps its explicit `working-tree` parameter default so `tests/hud_lib.bats` callers (no origin) are unaffected:
  - `hud/register.tsx:163`: `?? 'default-branch'`
  - `hud/scripts/hud-data.sh:65`: `working-tree` only when stdin says so; anything else, including absent, is `default-branch`, and the `|| queue_source=...` jq-failure branch on the same line flips too (bad stdin must not keep the old default)
  - A project or user `"queue": null` no longer forces working-tree; the only way to force it is the explicit `"working-tree"` value
- `hud/config.ts` `parseQueue`: an unknown value already returns `undefined` (so the new default); comment updated. Explicit `"working-tree"` still parses.
- `/hud config` dialog (`hud/configure.ts:15-17`) already lists `default branch (recommended)` first: only the question text gains "(the default)"; the exported option constants keep their values so `hud/configure.test.ts` imports still hold.
- Fetch cost (review finding): `sl-queue-json` would now run a detached `git fetch origin <default>` every 2 minutes in every repo with an origin, queue or not. Gate it (documented limit: a queue that exists only on origin and in neither local tree is picked up once a fetch or `git fetch` by the user brings it in): one "does a queue exist anywhere?" test (`dev/TODO/queue.md` in the working tree or in the local `refs/remotes/origin/<default>` tree) at the top of the `default-branch` branch of `sl-queue-json`; when it fails, skip the fetch, the temp-dir sweep, `mktemp`, the archive and the cleanup (the queue line stays absent, as today). The test plan asserts none of those run.
- A local-only repo (no origin), or one whose origin has no `dev/TODO` yet (for example a just-created, unpushed queue), with a queue now shows the existing `queue (working tree, origin unavailable)` label by default; accepted as the honest label, documented in the README.
- Docs and comments: `hud/README.md:30` (Config row; `"queue": null` now means the default, not "off") and `:122`, `:125`, `:128`, `:181` (dialog bullet), `:217` (network sentence: the fetch now runs unless opted out, and only when a queue exists); `hud/scripts/hud-data.sh:27-29,38` header; `hud/config.ts:63` comment; `types/index.d.ts:17,40` doc comments.
- Alternatives rejected:
  - Flip the default inside `sl-queue-json`: breaks every library caller and test that has no origin.
  - Drop `working-tree`: owner asked for a default, and offline or origin-less repos still need the opt-in.
  - Query GitHub through `gh` for the default branch name: adds an auth and network dependency; `origin/HEAD` is local and already the established rule.

## Test plan

- [x] `hud/pure.test.ts` (vitest): the existing `parseQueue`/`mergeConfig` cases (`:1505-1513`) stay green; section header text updated.
- [x] `hud/pure.test.ts:1512-1513`: comment and an assertion for the new `"queue": null` meaning (project null replaces a user `working-tree`, giving the default); README band examples (`:46-47`, `:53`) re-read.
- [x] `hud/hooks.test.tsx` (near `:211`): the stdin the mod sends has `queue_source: "default-branch"` when `queue` is unset and `"working-tree"` when explicit.
- [x] `hud/configure.test.ts`: dialog question wording; writes unchanged.
- [x] `tests/hud_queue_source.bats:183` ("queue_source in stdin picks the source; absent or unknown means the working tree"): rewritten so absent and unknown mean default-branch and an explicit `working-tree` means the working tree; `:59` case renamed "library default" (the library default stays `working-tree`; default-flip coverage lives at the `hud-data.sh` and `register.tsx` edges); a case pins the documented limit (queue only on origin, in neither local tree: not fetched); new cases: fetch targets `origin <default>` only, and no fetch when no queue exists anywhere.
- [x] `tests/hud_data.bats:544-553` (`_hud` sends stdin without `queue_source`, repo without origin, exact queue JSON): pass `queue_source:"working-tree"` or expect the fallback keys; `tests/hud_queue_hwm.bats:105,175` verified unchanged (its `setup()` already sets `HUD_QUEUE_FETCH_SYNC=1` and a state dir; those repos have no origin).
- [x] `bats tests/hud_*.bats` green locally and CI green; the vitest files (`claude-code/testing` runner) are edited but not runnable outside Claude Code, so they are verified by review only.

## Done criteria

- [x] Unset `queue` reads the default branch: `hud/scripts/hud-data.sh` covered by `tests/hud_queue_source.bats:183`; `hud/register.tsx` covered by the new `hud/hooks.test.tsx` case.
- [x] Explicit `"working-tree"` still works: `hud/pure.test.ts` and `tests/hud_queue_source.bats`.
- [x] Origin unreadable falls back and is flagged: `tests/hud_queue_source.bats` (no origin case).
- [x] Fetch goes to `origin <default>` only: `hud/scripts/hud-lib.sh` `_sl-queue-fetch-run`, asserted in `tests/hud_queue_source.bats`.
- [x] README and dialog text updated: `hud/README.md`, `hud/configure.ts`, `hud/configure.test.ts`.

## Closed (2026-11-09)

- Shipped in PR #624 (claim #622, design #623, queue #621); CI green (bats, Markdown Lint, lint-tasks, skill-quality, sync-tasks).
- Met: unset, absent, unknown or malformed `queue.source` means `default-branch`; explicit `working-tree` is the opt-in; fallback to the working tree is kept and flagged; the fetch targets `origin <default>` only (new bats case); no queue anywhere means no fetch, temp dir or archive.
- Unverified: the vitest files (`hud/hooks.test.tsx`, `hud/pure.test.ts`) were edited but cannot run outside Claude Code; reviewed by reading only.
- Quality regression (shellcheck_error,shellcheck_warning,shellcheck_info,max_fn_lines): false positive; the probe compared against a record with a different file set, and shellcheck output for `hud/scripts/hud-lib.sh` (3 lines) and `hud/scripts/hud-data.sh` (5 lines) is identical before and after.
- Release: no version bump here; the owner releases the plugin and updates installs for the new default to take effect.
- Follow-ups: none filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, not invoked as a skill; bats cases were written alongside the change and one mutation check was done by the reviewer
- Verification (`superpowers:verification-before-completion`): bats and lint run before each PR; independent fresh-agent review on every PR
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): applied to the design PR (3 revision rounds), no pushbacks
