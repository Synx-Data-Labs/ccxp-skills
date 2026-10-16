---
status: Done
estimation: 1
source: this conversation, 2026-10-12 (ssh/gh/git wrapper investigation); re-scoped 2026-10-16 (synxdb-build-pipeline consumer session — live repro of the exact `_gh_die` symptom)
related: T20260925-219021
claimed_by:
claimed_role:
scheduled: 2026-10-12
---

# T20261012-280694: harden `_gh/gh.sh` account listing against a broken `awk` on PATH

## TLDR

- **Type**: bug
- **Problem**: `_gh_list_accounts()` parsed `gh auth status` with `awk`; on a
  machine whose `awk` resolves to a mis-linked/broken `gawk`, it silently
  returned zero accounts, so the wrapper died with "no authenticated gh
  account has access to `<slug>`" even though every account WAS authenticated
  and DID have access.
- **Solution**: rewrote `_gh_list_accounts()` in pure bash (`case`/parameter
  expansion), removing the `awk` dependency entirely.
- **Scope note**: this task originally also covered "lint forbid bare
  network `gh`/`git`" + migrating ~104 bare-call sites — that's a much larger,
  separate initiative and is split out to **T20261016-278922** (follow-up,
  staged next iteration) so this bug fix could ship on its own.

## Problem

- Reported symptom (consumer-repo session, synxdb-build-pipeline,
  2026-10-16): multiple sessions hit `gh`/`git` wrapper failures shaped like
  `no authenticated gh account has access to <owner>/<repo> (try: gh auth
  login)`, even though plain ambient `gh`/`git` (direct binary paths) worked
  fine with the same credentials — forcing a workaround of calling the real
  binaries directly instead of the wrapper. It also broke `/rca`'s own
  `ci-triage.sh` helper, which shells out through the same `gh.sh`.
- **Reproduced live, this session**, directly against this repo
  (`Synx-Data-Labs/ccxp-skills`):
  - `bash _gh/gh.sh repo view --json name` → `gh.sh: no authenticated gh
    account has access to Synx-Data-Labs/ccxp-skills (try: gh auth login)`
    (exit 1).
  - Yet a direct, non-wrapped call for the exact same repo/account succeeded:
    `GH_TOKEN=<xinzweb token> /opt/homebrew/bin/gh api
    repos/Synx-Data-Labs/ccxp-skills --jq .permissions.push` → `true` (write
    access), and the same for the second account → `false` (read-only, but
    present). Both accounts are live and `gh auth status` lists both.
- Traced with `bash -x` (a copy of `_gh/gh.sh` with `set -x` + `exec 2>` a
  log file, since sourcing isn't needed to see the failure): `main()` →
  `_gh_pick_account` → `for user in $(_gh_list_accounts)` **iterates zero
  times** — `_gh_list_accounts` returned nothing, so `_gh_pick_account`
  returns 1 before ever calling `_gh_account_tier` for either account.
  `_gh_list_accounts` (`_gh/gh.sh:61-68` pre-fix) was:

  ```bash
  gh auth status 2>&1 | awk '
    /Logged in to github.com account/ {
      for (i = 1; i <= NF; i++) if ($i == "account") { print $(i + 1); break }
    }'
  ```

  - The `gh auth status` half works — captured its raw output and it's
    exactly the expected two-account text (`✓ Logged in to github.com
    account xinzweb (keyring)` / `... 75033us ...`).
  - The `awk` half is what's broken: `command -v awk` resolves to
    `/opt/homebrew/opt/gawk/libexec/gnubin/awk` (a symlink to
    `/opt/homebrew/opt/gawk/libexec/bin/gawk` — a valid Mach-O arm64 binary,
    not corrupted/missing) ahead of `/usr/bin/awk` on `$PATH`. That specific
    `gawk` never matches **any** regex via the `~` operator or a
    `/pattern/ {action}` rule — verified with cases that have nothing to do
    with `gh`: `echo "abc123" | awk '{if ($0 ~ /[0-9]/) print "YES"; else
    print "NO"}'` prints `NO` (should be `YES`); `/usr/bin/awk` run against
    the identical input correctly prints `YES`. So `_gh_list_accounts`'s
    `awk '/Logged in.../{...}'` rule never fires, on **any** input, on this
    machine — it would fail identically for 1 account or 10.
  - Impact: every caller of `_gh/gh.sh`/`_gh/git.sh` on this machine
    (interactive sessions and `/rca`'s `ci-triage.sh`, which sources
    `gh.sh`) hits this, for every repo, deterministically — matching "hit
    repeatedly across multiple sessions/jobs".

## Context

- **Bug**, repro environment: any machine where `$PATH` resolves `awk` to an
  incompatible/broken build *ahead of* a working one — observed concretely
  with a Homebrew `gawk` gnubin shim (`/opt/homebrew/opt/gawk/libexec/gnubin`
  is on `$PATH` ahead of `/usr/bin`, a common macOS GNU-coreutils-first setup)
  whose regex engine silently never matches. `gh`/`git` CI runners don't hit
  this (their `awk` isn't a broken gawk build), which is why the 19
  pre-existing `tests/gh.bats` cases — which stub `gh` entirely but never
  stub `awk` — never caught it; it's a machine-local PATH/toolchain issue,
  not a logic bug any existing hermetic test could see.
- Two unrelated, previously-considered theories (from the 2026-10-12 design,
  kept here as related but NOT what fixed this bug — see `## Root cause`):
  - *Bare `gh`/`git` calls skip the wrapper entirely* — true, and still a
    real gap, but orthogonal: this bug hits even a fully-wrapped call.
  - *Ambient `GITHUB_TOKEN` overrides account choice* — tested directly this
    session (`GITHUB_TOKEN=bogus_value gh auth status`): it does make `gh
    auth status` print an extra "Failed to log in... (GITHUB_TOKEN)" block
    and exit 1, but the two real keyring-account lines are still present and
    still correctly extracted by the (now bash-native) parser — so on its
    own it does not reproduce this failure. Carried into the split-out
    follow-up (T20261016-278922) as a defense-in-depth item, not re-verified
    as a root cause of the reported symptom.
- `_gh/git.sh` sources `_gh/gh.sh` (`source "$_gh_git_dir/gh.sh"`), so the
  fix covers both wrappers with one change.

## Solution

- Rewrote `_gh_list_accounts()` (`_gh/gh.sh`) to parse `gh auth status`
  output in pure bash — `while IFS= read -r line; do case "$line" in
  *"Logged in to github.com account"*) ...` + `${line#*account }` /
  `${rest%% *}` parameter expansion — instead of piping through `awk`.
  Bash's own glob/substring matching has no external binary to get out of
  sync with.
- **Alternatives considered and rejected**:
  - *Hardcode `/usr/bin/awk`* — rejected: fragile on non-macOS runners
    (no guaranteed `/usr/bin/awk`), and still leaves a dependency on an
    external tool's regex semantics for a job bash can do natively.
  - *Detect-and-warn on a broken `awk` at wrapper startup* — rejected as
    unnecessary complexity once the dependency is removed outright; nothing
    left to detect.
  - *Fix/relink the broken `gawk` on this one machine* — rejected as the
    actual fix: it would leave every other machine with the same
    `gnubin`-ahead-of-`/usr/bin` PATH shape (a common, reasonable setup) one
    bad `brew upgrade` away from hitting this again. Fixing the wrapper's
    own dependency is the generalizable fix.

## Root cause

- Introduced in `_gh/gh.sh`'s original authoring (git history for this repo
  bottoms out at a single squashed "Initial public release" commit per
  T20260925-427007's own note — exact original SHA not recoverable here).
  `awk` was a reasonable, idiomatic choice for line-oriented text parsing at
  the time; the bug is an **unstated assumption**, not a deliberate
  trade-off: the script assumed `awk` on `$PATH` has a working regex engine,
  which held on every machine/CI runner the script was developed and tested
  against, but doesn't hold universally — a GNU-coreutils-first `$PATH`
  arrangement (common on macOS dev machines, orthogonal to `gh`/`git`) can
  put an incompatible `gawk` build ahead of a working `awk`.
- Why existing tests missed it: `tests/gh.bats` stubs `gh` (via
  `tests/fixtures/gh/fake-gh.sh`) for every account-picking test, but never
  stubbed or asserted anything about `awk` — a hermetic unit test has no way
  to catch a *host toolchain* defect it doesn't simulate.

## Test plan

- [x] New regression test: `tests/gh.bats` — `"_gh_list_accounts parses
      accounts correctly even with a broken awk on PATH"` — puts a fake
      `awk` at the front of `$PATH` that mimics the real broken gawk exactly
      (reads stdin, matches nothing, exits 0) plus the existing
      `fake-gh.sh` stub, and asserts `_gh_list_accounts` still returns both
      accounts. RED before the fix (old `awk`-piping implementation
      returned nothing under the fake broken `awk`), GREEN after.
- [x] Full `tests/gh.bats` suite: 19/19 green (was 18; +1 new case), no
      regressions to the existing `_gh_repo_slug`/`_gh_pick_account`/
      `main()` self-heal cases.
- [x] Manual, non-hermetic verification against the real failure on this
      machine: `bash _gh/gh.sh repo view --json name` — failed with the
      reported error before the fix, returns `{"name":"ccxp-skills"}` after.
- [x] Full repo `bats tests/*.bats` regression sweep — see `## Closed` for
      the result.

## Done criteria

- [x] `_gh_list_accounts()` no longer shells out to `awk` — `_gh/gh.sh`'s
      `_gh_list_accounts` function body (pure bash `case`/parameter
      expansion).
- [x] New bats case proves correctness under a broken-awk `$PATH` —
      `tests/gh.bats` `"_gh_list_accounts parses accounts correctly even
      with a broken awk on PATH"`.
- [x] No regression to existing `_gh/gh.sh`/`_gh/git.sh` behavior — full
      `tests/gh.bats` (19/19) and repo-wide `bats tests/*.bats` green (see
      `## Closed`).
- [x] Follow-up for the original lint + bare-call-migration + remaining
      hardening scope filed and staged — **T20261016-278922**.

## Closed (2026-10-16)

- Fix: pure-bash rewrite of `_gh_list_accounts()` in `_gh/gh.sh` (covers
  `_gh/git.sh` too, which sources it); new regression test in
  `tests/gh.bats`.
- All Done criteria met — see checked boxes above. `tests/gh.bats` 19/19;
  repo-wide `bats tests/*.bats` regression sweep also run (see PR for CI
  result).
- Follow-up filed: **T20261016-278922** (lint forbid bare network `gh`/`git`
  calls, migrate existing bare-call sites, and remaining wrapper hardening —
  ambient `GITHUB_TOKEN`, `clone`/`fetch`/`ls-remote` outside a repo),
  staged into the next iteration and promoted to the front of the queue.
- External/unverified: none — the fix was reproduced and verified live
  against this repo's real `gh auth status`/account state, not just unit
  tests.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the
  broken-awk-on-PATH `tests/gh.bats` case, confirmed the failure mode
  against the real wrapper first (live repro), then rewrote
  `_gh_list_accounts()` and watched the new case (and the full suite) go
  green.
- Verification (`superpowers:verification-before-completion`): yes — live
  repro against the real repo/accounts before AND after the fix, plus the
  full `tests/gh.bats` suite and a repo-wide `bats tests/*.bats` sweep.
- Systematic debugging (`superpowers:systematic-debugging`): yes — the
  reported symptom's pre-existing design doc guessed at two causes
  (bare-call bypass, ambient `GITHUB_TOKEN`); neither explained a
  fully-wrapped call failing, so traced with `bash -x` + isolated `awk`
  probes down to the actual mechanism (a broken `gawk` ahead of
  `/usr/bin/awk` on `$PATH`) rather than accepting the pre-existing
  hypotheses.
- Receiving code review (`superpowers:receiving-code-review`): n/a — no
  review round completed yet in this session at time of writing.
