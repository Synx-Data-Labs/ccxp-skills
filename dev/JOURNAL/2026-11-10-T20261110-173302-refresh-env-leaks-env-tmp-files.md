---
status: Done
estimation: 1
source: owner request, this conversation, 2026-11-10
description: .env.tmp.* / .env.err.* temp files leak when refresh-env or an old .envrc is killed mid op inject
---

# T20261110-173302: refresh-env leaks .env.tmp.* temp files

## Problem

- **Type**: bug
- 822 zero-byte `.env.tmp.XXXXXX` files in a consumer repo root (2026-11-03 to 11-07, bursts of ~58/hour); no `.env.err.*`.
- Creator: the consumer repo's `.envrc` is an old pre-`refresh-env` template (inline `mktemp .env.tmp.XXXXXX`, `rm` only when `op inject` fails, no signal trap); direnv kills it while `op inject` waits for unlock, and every prompt re-runs it.
- `1password-env-setup/scripts/refresh-env.sh` fixed INT/TERM/HUP only (trap at the lock step); no EXIT trap, nothing sweeps leftovers from older versions or SIGKILL.
- Done: no `.env.tmp.*` / `.env.err.*` remains after success, failure, or a killed run; stale leftovers (older than a threshold, not held by a live process) are swept; bats tests prove it.

## Solution

- `refresh-env.sh`: in-flight temp files tracked and removed after every refresh, on INT/TERM/HUP, and by an EXIT trap when run directly; no more glob-delete in the signal trap.
- New `re-sweep-stale`: removes mktemp-shaped `.env.tmp.*` / `.env.err.*` older than `REFRESH_ENV_SWEEP_MINS` (default 10) and not open; skipped in `--check`.
- Bats: success, failure, SIGTERM, SIGKILL then sweep, sweep shape/age, `--check` read-only.

## Closed (2026-11-10)

- Shipped in PR #649 (task claim/stage PR #647).
- Consumer repos still on the old inline-mktemp `.envrc` keep leaking until `/1password-env-setup` is re-run there; the owner's consumer repo was cleaned up by hand.
