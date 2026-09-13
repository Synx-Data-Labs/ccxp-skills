---
status: Open
estimation: 1h
source: consumer-repo session, 2026-09-09 — discovered while running /address-pr on a multi-account clone
related: T20260911-140914
---

# T20260911-698434: `_tc_claimant_id()` uses bare `hostname`, which can drift on the same machine

## Problem

- `_session/_lib.sh`'s `session_machine() { hostname; }` — used by
  `_session/task_claim.sh`'s `_tc_claimant_id()` to build the
  `<machine>:<working-dir>` identity that `claimed_by` is stamped with
  and compared against — returns whatever the OS's `hostname` command
  currently resolves to. That value is **not stable across time on the
  same physical machine**: it depends on which naming system currently
  wins (mDNS/Bonjour `<name>.local`, a VPN/mesh-network's own DNS such as
  Tailscale's MagicDNS `<name>.<tailnet>.ts.net`, plain `ComputerName`,
  etc.), and can change when new networking software is installed or
  reconfigured — with no code change and no new session involved.
- Observed failure: a task's `claimed_by` was stamped
  `<machine>.local:/Users/<user>/workspace/<org>/<repo>` at
  claim time. Later, on the exact same machine, exact same working
  directory, running `hostname` returned
  `<machine>-1.<tailnet>.ts.net` instead (Tailscale had been set up
  in the interim). `task_claim.sh pr-owner <pr>` computed `_tc_claimant_id()`
  fresh each call, got the new hostname, compared it against the stored
  `<machine>.local:...`, found no match, and returned
  `owned:<machine>.local:...` — a **false "owned by another agent"**
  verdict against the task's own rightful, currently-active owner.
- This directly defeats the anti-steal purpose `pr-owner` exists for
  (T20260622-404636): a false `owned:` reading either wrongly blocks the
  real owner (if followed literally) or, if routinely overridden by
  hand, erodes trust in the guard for the cases where it's protecting
  against a genuine other agent.

## Context

- `_tc_claimant_id()`'s own comment calls itself "Stable across CC
  invocations in the SAME clone" — true for the working-dir half
  (`session_clone_path()`, via `git rev-parse --show-toplevel`), false
  for the machine half whenever the OS's hostname resolution changes.
- No corroborating signal (a stored machine UUID, `ioreg` hardware
  identifier, etc.) is consulted — `hostname` is the sole source of
  truth for "which machine is this."
- Confirmed via `task_claim.sh reclaimable <id>` returning `live` (not
  stale) at the time of the false-positive — the tool's own staleness
  heuristic already knew the claim was active, just not that it was
  active *by the same machine* under a different name.

## Solution (proposed, not yet implemented)

- Stop relying solely on the live, mutable `hostname` output. Options,
  roughly in order of robustness vs. invasiveness:
  1. Cache a stable per-machine identifier on first use (e.g. under
     `~/.claude/state/machine-id`, similar to the existing
     `session_cc_session_id()` fallback pattern in the same file) and
     use *that* for `claimed_by`'s machine component instead of live
     `hostname` — immune to hostname-resolution drift entirely.
  2. If matching `hostname` exactly, treat a set of "look-alike" names
     for the same physical machine as equivalent — fragile and
     probably not worth it given option 1 exists.
- Either way, existing `claimed_by` values already on `main` (stamped
  with a since-drifted hostname) need a migration path. **Not** a plain
  "re-acquire on next touch" — checked `_tc_acquire()`: it only
  overwrites `claimed_by` unconditionally in the `none` (unclaimed)
  branch. In the `other` branch, which is exactly what a drift-orphaned
  self-claim looks like (some `claimed_by` present, string mismatch
  against the current identity), it instead *refuses* — `printf
  'claimed:%s\n' "$cur"; return 3` — rather than re-stamping. The actual
  migration needs either a one-time bulk re-stamp of existing
  `claimed_by` values (recomputing each with the new stable-machine-id
  scheme so old and new agree), or a small carve-out in `_tc_acquire`'s
  `other` branch that treats "same working-dir, only the old hostname
  half looks stale" as reclaimable rather than foreign.

## Test plan

- [ ] Simulate a hostname change on a machine holding an active claim
      (e.g. temporarily override what `hostname` returns) and confirm
      `pr-owner`/`reclaimable` still resolve correctly against the
      cached machine ID rather than flipping to `owned:<stale-name>`
- [ ] Confirm a fresh machine (no cached ID yet) still gets a sane,
      unique identity on first use

## Done criteria

- [ ] `_tc_claimant_id()` no longer depends solely on live `hostname`
      resolution
- [ ] No change needed to callers (`pr-owner`, `acquire`, `release`,
      etc.) — this is an internal fix to identity resolution
- [ ] Existing `claimed_by` values aren't broken by the change (a task
      claimed under the old scheme should re-resolve to "mine" for the
      same machine/clone, not suddenly read as foreign)
