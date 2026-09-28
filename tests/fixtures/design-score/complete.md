---
estimation: 4h (M)
status: Design
scheduled: 2026-06-18
priority: P2 — prevents a silent data-loss regression; not urgent but high blast radius.
source: conversation 2026-06-15 (shine) — port scanner drops symlinked libs
related: T20260608-672829; lifecycle.md
---

# T20260615-123456 — Fix symlink-following in the ELF runtime-lib scanner

## TLDR

- **Type**: bug
- **Problem**: the runtime-lib scanner skips symlinked shared objects,
  under-reporting the FCS manifest's dependencies.
- **Solution**: add `-L` to the `find` invocation so symlinks resolve, then
  de-dup by realpath.

## Problem

The runtime-lib scanner skips symlinked shared objects, so the FCS manifest
under-reports dependencies. Reproduction (verified):

```bash
$ scripts/scan-runtime-libs.sh /opt/acmedb/bin/postgres
# expected 42 libs, got 38 — the 4 missing are all symlinks
```

The wrong value is observed at `scripts/scan-runtime-libs.sh:88` where `find`
runs without `-L`.

## Plan

Add `-L` to the `find` invocation so symlinks resolve, then de-dup by realpath.

- Phase 1 — `scripts/scan-runtime-libs.sh:88` gains `-L`; de-dup at line 95.
- Phase 2 — characterization BATS test pinning the 42-lib expectation.

**Alternatives considered and rejected:**

- `readlink -f` post-pass over the result set — rejected: doubles the walk and
  still misses libs whose *directory* is a symlink (`find -L` handles both).
- Switch to `ldd` — rejected: `ldd` executes the binary, unsafe for cross-arch
  artifacts the FCS pipeline scans.

## Root cause

`find` without `-L` does not descend into symlinked directories nor stat
symlinked files as their targets. Introduced in `a1b2c3d` (2026-03-02) when the
scanner was first written — an oversight, not deliberate: the commit message
("initial ELF scan") shows symlinks were never considered.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `scripts/scan-runtime-libs.sh` | `88–96` | the buggy `find` + de-dup |
| `tests/scan_runtime_libs.bats` | `1–40` | characterization test |

## Test plan

- [ ] Unit: `tests/scan_runtime_libs.bats` — symlinked `.so` is counted.
- [ ] Local: re-run `scripts/scan-runtime-libs.sh /opt/acmedb/bin/postgres` → 42.
- [ ] CI: bats suite green.

## Done criteria

- [ ] Symlinked libs are counted — pinned by `tests/scan_runtime_libs.bats:22`.
- [ ] No duplicate realpaths — pinned by `tests/scan_runtime_libs.bats:31`.
- [ ] Ships in PR #0 (placeholder until raised) — `scripts/scan-runtime-libs.sh:88`.

## Closed

_(pending)_

## Skills invoked

_(pending — recorded at Phase 7.0)_
