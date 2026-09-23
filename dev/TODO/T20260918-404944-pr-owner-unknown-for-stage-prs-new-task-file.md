---
status: Done
estimation: 1h
source: this conversation, 2026-09-18
related: T20260718-160579, T20260922-324422
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260918-404944: `task_claim.sh pr-owner` always returns `unknown` for `/stage` PRs that introduce a brand-new task file

## TLDR

- **Type**: bug (tooling gap in `_session/task_claim.sh`)
- **Problem**: `pr-owner` resolves a PR's task file only via the GitHub contents
  API on `ref=main`; a `/stage` PR that introduces the task file for the first
  time (same PR carries `queue.md` + the new file) has no file on `main` yet,
  so resolution fails closed to `unknown`, and `/address-pr` §1.6 refuses to
  ever merge such a PR.
- **Solution**: when the `main`-ref lookup fails, fall back to resolving the
  file on the PR's own head ref (same `dev/TODO`/`dev/PARKING` search); if
  found there, fetch `claimed_by` from that ref (not `main`) and feed it
  through the normal `mine`/`free`/`owned:` decision instead of a bare
  `unknown`.

## Problem

- Discovered while running `/address-pr` on PR #39, a `/stage` PR staging
  task `T20260918-214522` (its task file was net-new in that same PR).
- `_tc_pr_owner` (`_session/task_claim.sh:739`) calls
  `_tc_resolve_task_location` (`_session/task_claim.sh:623`), which resolves
  the same-repo case by listing `dev/TODO` **on `main`** via
  `_session_gh api "/repos/$repo/contents/$dir?ref=main"`
  (`_session/task_claim.sh:673`) and matching a filename that starts with the
  task id.
- `/stage`'s own documented design (`stage/SKILL.md` step 3) commits the
  `queue.md` append **plus the new task file itself** in the *same* PR the
  first time a task is staged — the task file legitimately does not exist on
  `main` yet at the moment `/address-pr` is asked to drive that very PR.
- Result: the same-repo loop finds nothing in either `dev/TODO` or
  `dev/PARKING` on `main` → `_tc_resolve_task_location` returns 1 →
  `_tc_pr_owner` prints `unknown` (`_session/task_claim.sh:750`) →
  `/address-pr` §1.6's fail-safe says defer, never merge. Taken literally,
  `/address-pr` can never merge a `/stage` PR for a task that didn't already
  exist on `main` — contradicting `/stage`'s own instruction to hand such PRs
  to `/address-pr`.
- Distinct from T20260718-160579 (a stale branch-name-vs-body `Task:` link
  mismatch on a *rescoped* PR): here the file is simply not on `main` yet, by
  design — not mislinked.
- Manual workaround used on PR #39 (not repeatable at scale): confirmed the PR
  body's staged task id matched the one new file in the diff exactly,
  confirmed the new file carried no `claimed_by` (freshly authored, nothing to
  race), and proceeded since `/stage` PRs are pure lifecycle bookkeeping with
  no implementation to steal.

## Context

- **Bug** — the repro is any `/stage` PR (or `/new-task` immediately followed
  by `/stage`) whose diff is the *first* commit of a task file: `git diff
  main...HEAD --name-status` shows the file as `A` (added), never `M`.
- `_tc_resolve_task_location`'s two call sites both key off the same
  `main`-only assumption:
  - the cross-repo branch (`_session/task_claim.sh:637-661`) parses a `Task:`
    body link and is unaffected — that link always names an *existing* hub
    file — so this bug is same-repo only.
  - the same-repo branch (`_session/task_claim.sh:662-680`) is the one that
    fails.
- `_tc_fetch_fm_field` (`_session/task_claim.sh:682-693`) also hardcodes
  `?ref=main` — even if location resolution were fixed, fetching
  `claimed_by` would still need a ref override to read a not-yet-merged file.

## Solution

**Revision (2026-09-22, after design review — see `## Design review` below):**
the original draft reused the existing `free` verdict for this case; an
independent review caught that `free`'s existing handling
(`address-pr/SKILL.md` §1.6) cannot actually be exercised for a not-yet-merged
file (see that section for why) — so this case gets its **own** verdict,
`new`, with its own (simpler) handling. What follows is the corrected design.

- **`_tc_resolve_task_location_head`** (new function, `_session/task_claim.sh`,
  inserted immediately after `_tc_resolve_task_location` — does **not** modify
  that function or its 2-field return contract): same-repo-only directory
  search (mirrors `_tc_resolve_task_location`'s same-repo branch) against the
  PR's own head ref (`gh pr view <pr> --json headRefOid`) instead of `main`.
  Returns a **3-field** `<owner/repo>\t<path>\t<head-sha>` — a distinct shape
  from `_tc_resolve_task_location`'s existing 2-field `<owner/repo>\t<path>`,
  so the two are never confused and every existing caller/test of the 2-field
  function is untouched. Only called by `_tc_pr_owner`, and only as a
  fallback.
- **`_tc_pr_has_cross_repo_task_link`** (renamed from the first `_tc_pr_has_task_link`
  draft, per Design review Finding A below — the old name/regex was broader
  than what it needed to guard): fetches the PR body itself (its own `gh pr
  view` call) and reports **true** iff the body has a `Task:`-prefixed line
  containing an actual github blob-link URL — the **exact same two-stage
  test** `_tc_resolve_task_location` uses to decide whether to take its
  cross-repo branch at all (`_session/task_claim.sh:642-644`: line 642's
  `Task:`-prefix grep piped into line 643's blob-URL grep — **both** stages,
  not line 642 alone). A `Task:`-prefixed line with **no** link (a checklist
  item, decoy text, unrelated prose) correctly reports **false** here, exactly
  as it would never have sent `_tc_resolve_task_location` down the cross-repo
  branch either — so the two functions can never disagree about which branch
  `_tc_resolve_task_location` actually took. **Fails CLOSED on its own body
  fetch failure**: report **true** ("assume a link is present, block the
  fallback") rather than **false** — mirrors `_tc_resolve_task_location`'s own
  fetch-failure fail-closed behavior (`_session/task_claim.sh:638-639`,
  guarded by `tests/task_claim.bats:780`) so a transient API error can never
  be misread as "no link -> safe to fall through."
- **`_tc_pr_owner`**: call `_tc_resolve_task_location` first as today. On its
  failure, **do not** unconditionally fall back to
  `_tc_resolve_task_location_head` — first check
  `_tc_pr_has_cross_repo_task_link`:
  - **True** (a `Task:` line with a real blob link is present — the
    cross-repo branch was taken and failed: fetch error, ambiguous/decoy/
    mismatched link, wrong-id link — **or** this helper's own fetch failed):
    print `unknown` and **stop**, exactly as today. **Never** fall through to
    the same-repo head-ref search in this case — doing so would resolve a
    same-repo id-prefix match in *this* repo's `dev/TODO`/`dev/PARKING`
    without ever having validated the PR's own (failed) cross-repo claim,
    silently reintroducing the exact fail-closed violation
    `resolve_task_location: body-fetch FAILURE fails closed (no same-repo
    fall-through)` (`tests/task_claim.bats:780`) and the ambiguous-link tests
    (`:773`, `:788`, `:796`) already guard against — one layer up, in the
    caller instead of the callee.
  - **False** (no `Task:` line at all, **or** a `Task:`-prefixed line with no
    blob link — either way, `_tc_resolve_task_location` itself would have
    gone straight to its same-repo branch, which is exactly the `/stage`
    scenario this task fixes): call `_tc_resolve_task_location_head`. If it
    also fails, print `unknown` (fully unresolvable, same fail-safe as
    today). If it succeeds, record that this resolution came from the head
    ref (a local flag) plus that ref (for the `claimed_by` fetch below) —
    never mix the two code paths.

  **Correction to an earlier draft**: this design previously asserted "a
  same-repo PR never carries a `Task:` line" — that's false as stated. PR #85
  (see [T20260922-324422](T20260922-324422-pr-owner-task-link-to-not-yet-merged-path.md),
  a related, separately-tracked bug) is a real same-repo PR whose body *did*
  carry a `Task:` line with a genuine blob link (pointing at a not-yet-merged
  JOURNAL path). This design's gate handles that case correctly regardless —
  it reports `unknown` for it (matching `_tc_resolve_task_location`'s real
  cross-repo-branch failure on that path), which is the *other* task's
  problem to fix, not a regression introduced here. The claim this design
  actually depends on is narrower and still true: `/stage`'s own PR-body
  template (`stage/SKILL.md`) never itself *writes* a `Task:` line — only
  `/gcpr`'s cross-repo convention does (`gcpr/SKILL.md:221`) — so the
  ordinary, unmodified `/stage` PR this task targets has no such line, and
  correctly falls through.
  Read `claimed_by` via `_tc_fetch_fm_field ... "$ref"` (`main` in the normal
  case, the head SHA in the fallback case). Then:
  - If the resulting decision is `mine` or `owned:<by>`: print that verdict
    **unchanged**, exactly as the main-resolved path would — a head-fallback
    resolution that finds an existing claim (this session's own prior claim
    commit on the PR's branch, or another agent's) needs no special handling,
    it flows through `_tc_decide` exactly as today.
  - If the resulting decision is `none` (unclaimed) **and** the resolution
    came from the head-ref fallback: print the new verdict **`new`** instead
    of `free` — this is the one case that needs different caller-side
    handling (see below), so it needs its own name.
  - If decision is `none` and resolution came from `main` (the pre-existing
    case): print `free`, unchanged.
- **`_tc_fetch_fm_field`**: add an optional 4th arg (ref, default `main`) so
  existing call sites (which all omit it) are unaffected.
- **`/address-pr` §1.6 — new `new` case**: unlike `free` (claim on a fresh
  branch off `main`, then merge that claim PR, then return to the original
  PR), `new` claims **directly on the PR's own branch**, in one push, because
  that branch is the only place the file exists:
  1. `git fetch && git checkout <the PR's headRefName>` (not a new branch —
     the existing PR branch, so the just-added task file is present in the
     local working tree).
  2. `bash task_claim.sh release-others <id>` then `bash task_claim.sh
     acquire <id>` — now succeeds, because `_tc_find_file`'s local glob finds
     the file on this checked-out branch.
  3. Commit (pure frontmatter change) and push — lands as one more commit on
     the *same* PR, no separate claim-PR/merge round-trip.
  4. **Push rejected (non-fast-forward) = you lost the race** — mirrors
     `free`'s own step 3 (`address-pr/SKILL.md:119`): another session saw
     `new` on this same PR and pushed its own claim commit first. Do **not**
     force-push. `git fetch && git checkout <branch>` again (picks up their
     commit) and re-run `task_claim.sh pr-owner <number>` — it re-resolves via
     the same head-ref fallback against the *new* head SHA, reads their now-
     stamped `claimed_by`, and reports `owned:<other>`. Defer per that case.
  5. Otherwise, continue driving this PR through the rest of the `/address-pr`
     loop as normal (§2 onward) — one PR, one push, done.

**Alternatives considered and rejected**:

- *Reuse the existing `free` verdict, since `/address-pr` already has tested
  free-then-claim handling.* **Rejected — this was the original design and an
  independent review caught why it's wrong**: `free`'s documented handling
  cuts a **fresh branch off `main`** and runs `task_claim.sh acquire`, which
  resolves the task file via a **local filesystem glob** (`_tc_find_file`,
  `_session/task_claim.sh:310-318`) against the checked-out working tree — a
  branch cut from `main` does not have a file that exists only on the
  `/stage` PR's own branch, so `_tc_acquire` fails closed (`return 2`, "no
  task file for $id") the instant it's tried. `free` is only ever safe today
  because every existing caller of it already found the file **on `main`**
  before deciding `free` — this change is the first to produce a
  free-like verdict for a file that ISN'T on `main` yet, so it cannot silently
  share `free`'s machinery.
- *Return a hardcoded `free`/`new` whenever the PR's diff adds a task file
  matching the id, without reading its `claimed_by`.* Rejected: skips the
  "confirm no claimed_by" check the manual workaround did on PR #39 — a raced
  re-stage where the new file already carries a stamped `claimed_by` (two
  agents racing `/new-task` + `/stage`, or one agent's own prior claim commit
  on this exact branch) would then be silently mis-decided instead of
  correctly resolving to `mine`/`owned:` via the normal decision path.
- *Have `/address-pr` special-case "PR adds the task file" instead of fixing
  `task_claim.sh`.* Rejected: `pr-owner` is the single source of truth other
  callers (the reclaim sweep, tests) also rely on; fixing it there fixes every
  caller at once instead of duplicating the diff-vs-main check in each one.

## Design review

- 2026-09-22: an independent review (dispatched per `/address-pr` §2.d)
  against the first draft of this design found:
  1. **(High, addressed above)** the `free`-reuse plan is unworkable because
     `task_claim.sh acquire`'s file lookup is local-filesystem, not
     API-based — a claim branch cut from `main` can't see a file that only
     exists on the PR's own branch. Fixed by giving this case its own `new`
     verdict and handling (see Solution and the new `/address-pr` §1.6
     section below) instead of reusing `free`.
  2. **(Medium, addressed above)** the original wording ("return the path
     exactly as before" vs. "track which ref resolved") was internally
     inconsistent about the interface. Fixed by making
     `_tc_resolve_task_location_head` a **separate function with a 3-field
     return**, never sharing `_tc_resolve_task_location`'s 2-field contract.
  3. **(Minor, addressed)** the Test plan's first checkbox was pre-checked
     (`[x]`) on a design-only PR before any code existed. Reworded below to
     describe what was actually verified pre-code (nothing yet) vs. what
     verifies the eventual change.
- 2026-09-22 (second pass): a fresh independent review of the revision above
  confirmed findings 1-3 fixed, but found one more real gap:
  1. **(Medium-High, addressed above)** the fallback was gated only on
     "`_tc_resolve_task_location` failed," not on *why* — so a cross-repo PR
     whose `Task:` link is ambiguous/mismatched/unfetchable (cases
     `tests/task_claim.bats:773,780,788,796` deliberately guard as fail-closed)
     would also fall through to the same-repo head-ref search, one layer up
     from where those tests protect. Fixed by adding a presence-check helper
     and gating the fallback on "no `Task:` line at all" specifically.
  2. **(Low-Medium, addressed above)** the `new` claim procedure had no
     documented "lost the race" step, unlike `free`'s step 3. Added an
     equivalent step 4.
  3. **(Low, cosmetic, addressed above)** the Repo file references table's
     wording for `_session/task_claim.sh:623-680` read as "modify this
     function," re-introducing the interface ambiguity Finding 2 (first pass)
     already fixed in prose. Reworded to say "unchanged."
- 2026-09-22 (third pass): a fresh independent review of the second-pass
  gating fix found it was itself scoped wrong:
  1. **(High, addressed above)** the presence-check (then `_tc_pr_has_task_link`)
     matched on the mere presence of a `Task:`-prefixed line
     (`_session/task_claim.sh:642` alone) — but `_tc_resolve_task_location`
     only takes its cross-repo branch when that line **also** contains a
     github blob-link URL (line 642 **and** 643 together, `if [ -n "$links"
     ]` at 644). A `Task:`-prefixed line with no link (unrelated prose, a
     checklist item) never sends `_tc_resolve_task_location` down the
     cross-repo branch — it falls straight to the same-repo branch, which is
     exactly the genuine `/stage` scenario this task fixes. Under the
     second-pass gate, that case would have wrongly reported `unknown`,
     reproducing the original bug. Fixed: renamed to
     `_tc_pr_has_cross_repo_task_link` and rewritten to check the **same
     two-stage condition** `_tc_resolve_task_location` itself uses, so the
     two functions can never disagree about which branch was taken.
  2. **(Medium, addressed above)** the presence-check's own fetch-failure
     behavior was unspecified — a naive implementation could report "no
     link" (and fall through) on a transient API error, silently
     reintroducing the same fail-closed violation Finding 1 (second pass)
     fixed, one layer further down. Fixed: the helper now fails CLOSED on its
     own fetch failure (reports "link present," blocking the fallback),
     mirroring `_tc_resolve_task_location`'s own fetch-failure behavior.
  3. **(Low, cosmetic, addressed above)** the Repo file references table row
     described both new functions as sharing "a 3-field return" — only
     `_tc_resolve_task_location_head` has that shape;
     `_tc_pr_has_cross_repo_task_link` is a plain boolean presence-check.
     Split into two rows.
  Also corrected a now-known-false categorical claim ("a same-repo PR never
  carries a `Task:` line") surfaced during this pass — see the Solution
  section's "Correction to an earlier draft" note.

## Test plan

- [x] Baseline: `bats tests/task_claim.bats` passes on `main` today (before
      any code change) — 83 cases, all passing prior to this task's changes.
- [x] New unit test: `resolve_task_location_head: task file present on the
      PR's own HEAD ref but absent from main -> resolves via head-ref
      fallback` (`tests/task_claim.bats`, alongside the existing
      `resolve_task_location: same-repo, task file present in NEITHER dir ->
      fails closed (unknown)` case).
- [x] New unit test: `pr-owner: cross-repo Task: link present but
      unresolvable (ambiguous/mismatched) -> unknown, NEVER falls through to
      the same-repo head-ref search` — guards Design review (second pass)
      Finding 1; must not regress `tests/task_claim.bats:773,780,788,796`'s
      existing fail-closed guarantees one layer up in `_tc_pr_owner`.
- [x] New unit test: `pr-owner: task file new in this PR (absent on main,
      present on head, no claimed_by) -> new` (verdict is `new`, not `free`
      — see the design revision above).
- [x] New unit test: `pr-owner: task file new in this PR but already carries a
      claimed_by (mine) on head -> mine` and `... (another agent's) on head ->
      owned:<by>` (the raced-restage edge case named in Solution's
      rejected-alternative above) — both flow through the *unchanged*
      `mine`/`owned:` paths, only the unclaimed case gets the new verdict.
- [x] `bats tests/task_claim.bats` — full suite passes locally **after** the
      change: 98 cases, all passing (15 new). Full repo suite (`bats tests/`):
      705 cases, all passing — no regressions.
- [x] Manual smoke: re-run `bash _session/task_claim.sh pr-owner 39` against
      the real PR #39 (already merged) is not repeatable as a live repro since
      the file is on `main` now — instead verified against **this task's own
      claim PR (#93)**, merged, a same-repo PR whose diff added no new task
      file: `bash _session/task_claim.sh pr-owner 93` → `mine` — the
      main-resolved path is unaffected, exactly as before this change.
- [ ] Manual/documentation verification: `address-pr/SKILL.md` §1.6's new
      `new` case is exercised the next time a real `/stage`-introduces-a-new-
      file PR is addressed (can't be dry-run in bats, since it's a documented
      *procedure* for the driving session, not a pure function) — **post-merge
      item, left unchecked**: genuinely external, will be confirmed the next
      time such a PR goes through `/address-pr`.

## Done criteria

- [x] `_tc_pr_owner` returns `new` (not `unknown`, not `free`) for a same-repo
      PR whose diff introduces the task file and that file carries no
      `claimed_by` — `tests/task_claim.bats` test `pr-owner: task file new in
      this PR (absent on main, present on head, no claimed_by) -> new`.
- [x] `_tc_pr_owner` returns `mine`/`owned:<by>` (not `new`) for the same
      shape but with a `claimed_by` already stamped on the head-ref copy —
      `tests/task_claim.bats` tests for both sub-cases.
- [x] `_tc_resolve_task_location_head` only runs after
      `_tc_resolve_task_location` (the `main`-ref lookup) fails, and never
      changes `_tc_resolve_task_location`'s own 2-field return contract —
      `tests/task_claim.bats` test `resolve_task_location_head: task file
      present on the PR's own HEAD ref but absent from main -> resolves via
      head-ref fallback`.
- [x] All pre-existing `_tc_resolve_task_location` / `_tc_pr_owner` bats cases
      at `tests/task_claim.bats:585-880` still pass unchanged — no regression
      to the `main`-resolved path (full-suite run: `bats tests/task_claim.bats`,
      98/98 passing).
- [x] `_tc_fetch_fm_field` (`_session/task_claim.sh:682`) accepts an optional
      ref argument, default `main` — existing callers that omit it are
      unaffected (same bats full-suite run as above covers this).
- [x] `address-pr/SKILL.md` §1.6 documents the `new` case's own claim
      procedure (checkout the PR's own branch, not a fresh branch off `main`,
      including the "lost the race" step) — done.
- [x] `_tc_pr_has_cross_repo_task_link` reports true only when the body has a
      `Task:`-prefixed line **containing a github blob-link URL** (the exact
      `_tc_resolve_task_location:642-644` condition) — never on bare
      `Task:`-line presence alone, and never `false` on its own fetch
      failure — both new unit tests below.
- [x] A cross-repo PR whose `Task:` link fails to resolve for any of the
      pre-existing reasons (ambiguous, ID mismatch, fetch failure) still
      returns `unknown` from `_tc_pr_owner` and never reaches
      `_tc_resolve_task_location_head` — `tests/task_claim.bats` test
      `pr-owner: cross-repo Task: link present but unresolvable -> unknown,
      NEVER falls through to the same-repo head-ref search`.
- [x] New unit test: `pr-owner: body has a Task:-prefixed line with NO blob
      link (not a real cross-repo pointer) -> still falls through to the
      head-ref search, verdict new` — the negative counterpart to the item
      above; guards Design review (third pass) Finding A — a `Task:`-worded
      line alone must never block the fallback, only an actual blob link
      does.
- [x] New unit test: `pr_has_cross_repo_task_link: its own body-fetch failure
      fails CLOSED (reports "link present", blocking the fallback)` — guards
      Design review (third pass) Finding B.

## Root cause

- `_tc_resolve_task_location`'s same-repo branch was written assuming the
  task file it's asked to locate always already exists on `main` — true for
  every caller *except* `/stage`'s own documented "commit the new file in the
  same PR" pattern (`stage/SKILL.md` step 3, itself pre-existing).
- Git archaeology: this repo's history starts at a single squashed `Initial
  public release` commit (`890c1ce`) after the split from a private
  predecessor — `_tc_resolve_task_location` and the same-repo fallback
  (`git log -S _tc_resolve_task_location`) both predate that split, so the
  original introduction date/rationale isn't recoverable from this clone's
  git log. The oversight is structural (a `main`-only assumption baked into
  the original design), not a recent regression — `/stage`'s "commit the new
  file in the same PR" convention and `pr-owner`'s `main`-only resolution were
  never reconciled against each other until this task surfaced the gap on a
  real PR (#39).
- Deliberate-vs-oversight: oversight — `/address-pr` §1.6's own "unknown"
  case comment (`address-pr/SKILL.md`) explicitly frames unresolvable-as-fail-safe
  for network/not-found reasons, not for "resolvable, just not merged yet";
  the `/stage`-introduces-the-file case was never enumerated as a scenario
  when that fail-safe was designed.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | 623-680 | `_tc_resolve_task_location` — same-repo `main`-only lookup; **unchanged**, cited only as the insertion point for the new function on the next row |
| `_session/task_claim.sh` | (new, after 680) | `_tc_resolve_task_location_head` — new function; a 3-field return, never sharing `_tc_resolve_task_location`'s 2-field contract |
| `_session/task_claim.sh` | (new, near `_tc_resolve_task_location`) | `_tc_pr_has_cross_repo_task_link` — new function; plain boolean presence-check (exit status), no return-shape contract; mirrors `_tc_resolve_task_location`'s own 642-644 two-stage test exactly |
| `_session/task_claim.sh` | 682-693 | `_tc_fetch_fm_field` — hardcoded `?ref=main`; add optional ref arg |
| `_session/task_claim.sh` | 739-764 | `_tc_pr_owner` — thread the resolved ref through to the `claimed_by` fetch |
| `tests/task_claim.bats` | 581-880 | Existing `pr-owner`/`resolve_task_location` bats coverage; add new cases alongside |
| `stage/SKILL.md` | step 3 | Documents the "commit the new file in the same PR" convention this bug is triggered by (no change needed — cited for context) |
| `address-pr/SKILL.md` | §1.6 | Caller of `pr-owner`; **needs a new `new` case** (checkout-the-PR's-own-branch claim procedure) — `free`'s existing handling does NOT cover this outcome (see Design review) |

## Dependencies

- Related to T20260718-160579 (a different `pr-owner` misresolution — stale
  branch/body-link mismatch on a rescoped PR) and T20260922-324422 (another
  `pr-owner` misresolution class) — same function family, different root
  causes; no blocking relationship.

## Closed (2026-09-22)

- Shipped in **PR #94** (design, merged) and the implementation PR opened
  immediately after this section was written (see the PR this task file's
  own commit history points to — same branch `t20260918-404944-impl`).
- **Met**: `_tc_pr_owner` now returns `new` for a same-repo PR (e.g. `/stage`)
  that introduces its own task file, unclaimed, not yet on `main` — instead
  of `unknown`. The fallback is correctly gated so cross-repo PRs with an
  unresolvable `Task:` link still return `unknown` (no regression to the
  fail-closed guarantees `tests/task_claim.bats:773,780,788,796` protect).
  `address-pr/SKILL.md` §1.6 documents the `new` case's own claim procedure.
  All Done criteria items checked; 98/98 `task_claim.bats` cases and 705/705
  full-repo bats cases pass.
- **External/unverified**: the one post-merge Test-plan item — exercising
  `address-pr/SKILL.md` §1.6's new `new` case against a *real* `/stage`
  PR through `/address-pr` — is left unchecked; it's a documented procedure
  for a driving session, not something a unit test can exercise. Will be
  confirmed the next time such a PR is addressed.
- **Design process note**: this task's design went through four independent
  review rounds (see `## Design review` above) before implementation — three
  found real, escalating-precision bugs in the fallback-gating mechanism
  (the `free`-verdict reuse itself, then two rounds narrowing exactly which
  cross-repo failures must still block the fallback); the fourth was a clean
  bill. Worth noting for future `/drive` runs on this task family: the
  `pr-owner`/`_tc_resolve_task_location` function family is unusually
  fail-closed-sensitive — small gating changes there deserve the same
  scrutiny this task got, not less.
- **Follow-up tasks filed**: none — no new blockers or issues surfaced beyond
  what's already tracked in `related:` (T20260718-160579, T20260922-324422).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — this is a same-repo,
  code-class task where the design doc itself (after independent review)
  fully specified the exact test cases before implementation; tests were
  written alongside the implementation from that spec rather than a
  separate red-green-refactor loop, but every new branch is covered (98
  `task_claim.bats` cases, 15 new).
- Verification (`superpowers:verification-before-completion`): yes — ran the
  full bats suite (705 cases) and a live manual smoke test
  (`pr-owner 93 -> mine`) before treating the implementation as complete.
- Systematic debugging (`superpowers:systematic-debugging`): yes — one bats
  test failure (`pr_has_cross_repo_task_link`'s fetch-failure case) was
  root-caused via hypothesis-and-isolation (reproduced in a minimal debug
  `.bats` file) to a `set -e`/command-substitution interaction, rather than
  guessed at; fixed by wrapping in `run`, matching the file's existing idiom
  for exactly this scenario.
- Receiving code review (`superpowers:receiving-code-review`): yes — four
  independent review rounds on the design PR; three raised real findings,
  all steelmanned, verified against the actual code, and fixed (no
  pushback needed — every finding held up under verification).
