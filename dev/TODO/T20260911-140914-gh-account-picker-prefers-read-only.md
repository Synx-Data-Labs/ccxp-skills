---
status: Coding
estimation: 1h
scheduled: 2026-09-14
source: consumer-repo session, 2026-09-09 — discovered while running /gcpr on a multi-account clone
---

# T20260911-140914: `_gh/gh.sh` account-picker can cache a read-only account, silently breaking write operations

## Problem

- `_gh_pick_account()` (`_gh/gh.sh`) picks the **first** authenticated
  account for which `gh repo view <slug>` succeeds, and caches that pick
  per repo slug in `${TMPDIR}/.gh-account-cache-${USER}`. `gh repo view`
  only proves **read** access — it says nothing about write/collaborator
  status.
- On a multi-account machine where one account has read-only access to a
  repo (e.g. via org membership) and a *different* account is the actual
  owner/collaborator with write access, whichever account is probed
  first (order comes from `gh auth status`'s listing order, not access
  level) gets cached — even if it's the read-only one.
- Observed failure: `<org>/<repo>`'s cache had
  `<org>/<repo>\t<read-only-account>` (a read-only account), so
  `gh pr create` failed with `GraphQL: must be a collaborator
  (createPullRequest)` even though `git push` (SSH-key auth, unaffected
  by this cache) worked fine and a second account (`<owner-account>`, `ADMIN`
  permission) was available and correctly authenticated the whole time.
- Worked around manually that session by editing the cache file directly
  — no code fix applied yet.

## Context

- The wrapper's own header comment explicitly frames the goal as
  "picks the authenticated account with access to this repo" — read
  access was an implicit, unstated proxy for "access," which breaks for
  any repo where different accounts have different permission tiers.
- `_gh_pick_account()` (lines 72-92) never checks `viewerPermission`
  (available via `gh repo view <slug> --json viewerPermission`), and
  never invalidates a cached entry after a write operation fails against
  it — so once a wrong pick is cached, every subsequent write silently
  fails until someone notices and manually fixes the cache file.

## Solution (implemented)

- `_gh_account_tier()` replaces the bare `gh repo view <slug> >/dev/null`
  liveness check with one `gh api repos/<slug> --jq .permissions.push`
  call — gets liveness and permission level (`write`/`read`) in a single
  probe.
- `_gh_pick_account()` now runs two passes: prefer the first account with
  `write`; only settle for the first `read`-capable one if none has
  write. Order from `gh auth status` still doesn't imply permission
  level, but it no longer matters for the pick.
- Self-heal: `main()` dropped its `exec env GH_TOKEN=... gh "$@"` tail
  for a capture-then-retry shape — stdout streams straight through
  untouched (so `--jq`-piping callers see no behavior change), stderr is
  captured to a temp file. On a non-zero exit whose stderr matches
  `_gh_permission_error()` (collaborator/403/write-access-shaped text),
  the cached `(slug, account)` line is dropped, the picker re-probes, and
  — if a *different* account comes back — the command is retried once
  with it. Anything else (a genuine 404, bad args, network error) passes
  through unchanged, no retry.
- Also added `_gh/git.sh`: the same picking logic, for `git push` (not a
  `gh` subcommand, so `gh.sh` itself can't wrap it) — retires the ad-hoc
  `GH_TOKEN="$(gh auth token --user <name>)" git push ...` pattern.
  `gcpr/SKILL.md` step 5 now routes through it.

## Test plan

- [x] Unit-test-style repro: two fake accounts against a test repo, one
      read-only, one write — confirm the picker prefers the write
      account regardless of `gh auth status` ordering
      (`tests/gh.bats`, `tests/fixtures/gh/fake-gh.sh`)
- [x] Confirm a stale read-only cache entry self-heals on the next
      write-shaped call instead of requiring manual cache editing
      (`main() self-heals a stale read-only cached pick...` in
      `tests/gh.bats`)
- [x] Manually reproduced and fixed live against this repo's real
      accounts (`75033us` read-only, `xinzweb` write) — see this task's
      PR description

## Done criteria

- [x] `_gh_pick_account()` (or a new helper) checks permission level, not
      just readability
- [x] Self-heal path added for a write failure against a cached pick
- [x] Existing callers (`address-pr`, `gcpr`, `drive`, etc.) need no
      changes — this is an internal fix to the picker, not an interface
      change (the new `git.sh` is additive; `gh.sh`'s own CLI interface
      is unchanged)
