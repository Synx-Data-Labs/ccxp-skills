---
status: Design
estimation: 1
source: owner request, this conversation, 2026-11-09
description: HUD queue.source defaults to default-branch, not the local working tree
claimed_by: cc1-9f320372:f9b2137c9918a8ee
claimed_role: interactive
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
  - `hud/scripts/hud-data.sh:65`: `working-tree` only when stdin says so; anything else, including absent, is `default-branch`
- `hud/config.ts` `parseQueue`: an unknown value already returns `undefined` (so the new default); comment updated. Explicit `"working-tree"` still parses.
- `/hud config` dialog (`hud/configure.ts:15-17`) already lists `default branch (recommended)` first: only the question text gains "(the default)"; the exported option constants keep their values so `hud/configure.test.ts` imports still hold.
- Fetch cost (review finding): `sl-queue-json` would now run a detached `git fetch origin <default>` every 2 minutes in every repo with an origin, queue or not. Gate it: fetch only when `dev/TODO/queue.md` exists in the working tree or in the local `refs/remotes/origin/<default>` tree; otherwise skip the fetch (the queue line then stays absent, as today).
- A local-only repo (no origin) with a queue now shows the existing `queue (working tree, origin unavailable)` label by default; accepted as the honest label, documented in the README.
- Docs and comments: `hud/README.md:30` (Config row; `"queue": null` now means the default, not "off") and `:122`, `:125`, `:128`, `:181` (dialog bullet), `:217` (network sentence: the fetch now runs unless opted out, and only when a queue exists); `hud/scripts/hud-data.sh:27-29,38` header; `hud/config.ts:63` comment.
- Alternatives rejected:
  - Flip the default inside `sl-queue-json`: breaks every library caller and test that has no origin.
  - Drop `working-tree`: owner asked for a default, and offline or origin-less repos still need the opt-in.
  - Query GitHub through `gh` for the default branch name: adds an auth and network dependency; `origin/HEAD` is local and already the established rule.

## Test plan

- [ ] `hud/pure.test.ts` (vitest): the queue-source section states the new default; `parseQueue` invalid or unset gives the default, explicit working-tree still parses.
- [ ] `hud/configure.test.ts`: dialog question wording; writes unchanged.
- [ ] `tests/hud_queue_source.bats:183` ("queue_source in stdin picks the source; absent or unknown means the working tree"): rewritten so absent and unknown mean default-branch and an explicit `working-tree` means the working tree; `:59` case reworded to explicit opt-in; new cases: fetch targets `origin <default>` only, and no fetch when no queue exists anywhere.
- [ ] `tests/hud_data.bats:544-553` (no stdin, repo without origin, exact queue JSON): pass `queue_source:"working-tree"` or expect the fallback keys; `tests/hud_queue_hwm.bats:105,175` kept hermetic with `HUD_QUEUE_FETCH_SYNC=1` / a stamp dir.
- [ ] `bats tests/` and `npx vitest run` (or the repo's runner) green locally; CI green.

## Done criteria

- [ ] Unset `queue` reads the default branch: `hud/register.tsx` and `hud/scripts/hud-data.sh`, covered by `tests/hud_queue_source.bats:183`.
- [ ] Explicit `"working-tree"` still works: `hud/pure.test.ts` and `tests/hud_queue_source.bats`.
- [ ] Origin unreadable falls back and is flagged: `tests/hud_queue_source.bats` (no origin case).
- [ ] Fetch goes to `origin <default>` only: `hud/scripts/hud-lib.sh` `_sl-queue-fetch-run`, asserted in `tests/hud_queue_source.bats`.
- [ ] README and dialog text updated: `hud/README.md`, `hud/configure.ts`, `hud/configure.test.ts`.

## Closed

- Pending.

## Skills invoked

- Pending.
