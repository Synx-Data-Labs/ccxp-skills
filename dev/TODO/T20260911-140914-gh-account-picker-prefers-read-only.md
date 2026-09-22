---
status: Coding
estimation: 1h
source: consumer-repo session, 2026-09-09 — discovered while running /gcpr on a multi-account clone
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
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

## Solution (proposed, not yet implemented)

- Prefer accounts with `viewerPermission` of `WRITE`/`MAINTAIN`/`ADMIN`
  over `READ`/`TRIAGE` when picking, e.g. `gh api repos/<slug> --jq
  .permissions` or `gh repo view <slug> --json viewerPermission`) instead
  of a bare `gh repo view <slug> >/dev/null` liveness check.
- If no account has write access, still pick the first read-capable one
  (today's behavior) — some operations (`pr list`, `pr view`) are
  legitimately read-only, so don't regress those.
- Add a self-healing path: if a cached account's use of `gh pr create`
  / `gh pr merge` / similar write op fails with a permission-shaped error
  (e.g. "must be a collaborator"), drop that cache line and re-probe
  before failing outright, rather than requiring a human to edit the
  cache file by hand.
  - **Implementation obstacle**: `main()` ends with `exec env
    GH_TOKEN="$tok" gh "$@"` (line 101) — `exec` replaces the wrapper's
    own process image with `gh`, so the wrapper never regains control to
    inspect `gh`'s exit code or output. Self-healing requires dropping
    the `exec` for a capture-then-retry shape (run `gh` as a normal
    child, check its exit status, drop the cache + re-probe + re-run on
    a permission-shaped failure, otherwise pass through its exit code)
    — a real restructuring of `main()`, not a one-line addition.

## Test plan

- [ ] Unit-test-style repro: two fake accounts against a test repo, one
      read-only, one write — confirm the picker prefers the write
      account regardless of `gh auth status` ordering
- [ ] Confirm a stale read-only cache entry self-heals on the next
      write-shaped call instead of requiring manual cache editing

## Done criteria

- [ ] `_gh_pick_account()` (or a new helper) checks permission level, not
      just readability
- [ ] Self-heal path added for a write failure against a cached pick
- [ ] Existing callers (`address-pr`, `gcpr`, `drive`, etc.) need no
      changes — this is an internal fix to the picker, not an interface
      change
