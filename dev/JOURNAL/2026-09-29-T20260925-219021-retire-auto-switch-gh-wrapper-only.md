---
status: Done
estimation: 4h
source: lsc-pa conversation, 2026-09-25
claimed_by:
claimed_role:
scheduled: 2026-09-28
---

# T20260925-219021: Retire `auto-switch.sh` and caller-side `GH_TOKEN`; route all `gh` through `_gh/gh.sh`

## TLDR

- **Type**: chore
- **Problem**: `_gh/auto-switch.sh`'s `SessionStart` hook globally mutates
  `gh auth switch`, so concurrent sessions on different accounts keep
  flipping each other's active account; some callers have worked around
  this by hardcoding `GH_TOKEN=$(gh auth token --user <name>)` instead.
- **Solution**: delete `auto-switch.sh` + its hook + its tests; move its
  git-credential wiring into `_gh/git.sh` (self-contained, idempotent, no
  hook needed); fix the one caller-side `GH_TOKEN=` site that's actually a
  bug (`_session/_lib.sh`); explicitly allowlist the one that's a
  documented, deliberate cross-repo exception (`ccxp/scripts/epic-status.sh`);
  add a bats check so a new caller-side `GH_TOKEN=` doesn't creep back in.

## Problem

- **Type**: chore
- `hooks/hooks.json` wires `_gh/auto-switch.sh` as a plugin-level
  SessionStart hook, so every session in every repo runs a global
  `gh auth switch`
  - Concurrent sessions on different accounts (<consumer-account> vs <owner-account>) keep
    flipping each other's active account
  - Consumers have fallen back to hardcoding
    `GH_TOKEN=$(gh auth token --user <name>)` per command
- `_gh/gh.sh` already solves this with no global state: it picks the account
  that can read `origin` and runs `gh` with a process-scoped `GH_TOKEN`
  - It should be the only sanctioned way to call `gh`; `auto-switch.sh`
    becomes redundant
- Caller-side `GH_TOKEN` / bare `gh` sites that bypass the wrapper:
  - `ccxp/scripts/epic-status.sh:144,217,261,276,337`: `GH_TOKEN="$tok" gh ...`
  - `_session/_lib.sh:74-91`: token fallback chain ending in `GH_TOKEN`,
    with a raw-`gh` branch
  - `_taskid/url.sh:43` looks for the wrapper at the dead
    `~/.claude/skills/_gh/gh.sh` path, so it silently falls back to bare
    `gh` under plugin installs; resolve via `CLAUDE_PLUGIN_ROOT` or the
    plugin cache instead (lsc-pa's `dev/scripts/lint_refs.py` hit the same)
  - README.md:59 and README.md:275-282 plus `gcpr/SKILL.md:182` document
    the old pattern
- Done looks like:
  - `auto-switch.sh`, its hook entry, `tests/auto-switch.bats`, and its
    README section are deleted
  - All `gh` calls in skills/scripts go through `_gh/gh.sh` (git through
    `_gh/git.sh`)
  - Only `gh.sh`/`git.sh` set `GH_TOKEN` internally; CI-only paths
    (`actions/sync-tasks/`, keyring-less) are an explicit allowlisted
    exception
  - A lint or bats check fails on a new caller-side `GH_TOKEN=` in
    skill/script sources outside the allowlist

## Context

- `_gh/auto-switch.sh` does two things, verified by reading it in full:
  - Runs `gh auth switch` globally on `SessionStart` (the harmful global
    mutation this task retires).
  - Once an account is confirmed, wires the **repo-local** `.git/config`
    (`credential.helper` → `gh auth git-credential`, plus
    `url."https://github.com/".insteadOf` for both `git@github.com:` and
    `ssh://git@github.com/`) so a bare `git push`/`pull`/`fetch` — and
    `_gh/git.sh`, which relies on this wiring — authenticate over HTTPS
    instead of the SSH agent (`dev/JOURNAL/2026-09-16-T20260916-873841-auto-switch-git-credentials.md`).
  - **This second piece has no other owner today.** `_gh/git.sh:20-30`
    (`main_git()`) just does `GH_TOKEN="$tok" exec git "$@"` — it depends
    on the credential-helper wiring already being in place; it doesn't set
    it up itself. Retiring `auto-switch.sh` outright, with no
    replacement, would break `git.sh` (and any bare push) on a **fresh
    clone that never ran the `SessionStart` hook** — this task's own
    "Done looks like" doesn't mention this dependency, so it's easy to
    miss.
- `README.md`'s own citations of "the old pattern" are partly stale
  already: `README.md:275-282` (the `gh.sh`/`git.sh` bullets) and
  `gcpr/SKILL.md:182` (`Route through _gh/git.sh`) already document the
  **correct** pattern — no change needed there. Only the `auto-switch.sh`
  bullet itself (`README.md:285-308`) and the install-time note
  (`README.md:29-32`) describe the hook being retired.
- Caller-side `GH_TOKEN=` sites, checked individually:
  - `_session/_lib.sh:88-91` (`_session_gh()`): when the `_gh/gh.sh`
    sibling exists, it runs `GH_TOKEN="$tok" bash "$wrapper" "$@"` — but
    `gh.sh`'s own `main()` re-derives its token internally via
    `_gh_pick_account`/`_gh_token_for` and never reads an inherited
    `GH_TOKEN`, so this outer `GH_TOKEN="$tok"` is dead — a real bug, not
    a deliberate exception. The no-wrapper fallback branch (`bash "$wrapper"`
    absent → bare `GH_TOKEN="$tok" gh "$@"`) is a legitimate CI-only
    exception (a GHA runner sparse-cloning just `_session/` has exactly
    one token, no account ambiguity — same rationale the task's own
    "Done looks like" already grants `actions/sync-tasks/`).
  - `ccxp/scripts/epic-status.sh:144,217,261,276,339` (the Problem
    section above cites the same fifth site as line `337` — two lines of
    drift since the task was filed, not a newly-discovered site): all
    five already use the sanctioned `_gh_pick_account`/`_gh_token_for`
    account-picking logic (sourced from `gh.sh`, per its own header
    comment at `epic-status.sh:17-32`) — they just can't call `gh.sh`'s
    `main()` CLI form, because `main()` always derives its target slug
    from `$PWD`'s `origin` (`_gh/gh.sh:94-101`, no `--repo` override) and
    this script does cross-repo reads against `$ROADMAP_TARGET_REPO`, a
    **different** repo than `$PWD`. This is a documented, deliberate
    exception — not a bypass of the account-picking mechanism, only of
    its CLI wrapper shape.
  - `_taskid/url.sh:43` — **out of scope here.** T20260925-427007 (already
    filed, `related:` on this task) owns the dead
    `~/.claude/skills/_gh/gh.sh` legacy-path lookup at this exact site
    (plus three others); its own file says "this task is just the
    dead-path lookup ... so it can ship on its own. Tick that bullet
    there when this one lands." Duplicating it here would just create
    two PRs touching the same lines.
  - `_ipm/ipm-iteration-drain-check.sh:224` (`gh project item-list ...`)
    — a genuine bare, unwrapped `gh` call this task's Problem section
    didn't originally list. Not touched here (see Alternatives rejected)
    — filed as a follow-up instead.
- **Bare `git push` sites bypassing `_gh/git.sh` entirely** (caught by
  independent review of this design, 2026-09-29 — verified by reading
  each file): `stage/SKILL.md:78`, `top/SKILL.md:138`, `bottom/SKILL.md:63`,
  `claim/SKILL.md:62,79,129`, `retro/SKILL.md:295`, and `drive/SKILL.md:114`
  (the last found by a second review pass, same day — it restates
  `claim/SKILL.md`'s solo-repo chain in prose and says so explicitly)
  all still instruct a bare `git push` — only `gcpr/SKILL.md:186` was
  ever updated to `bash ../_gh/git.sh push -u origin <branch>`. This
  matters *specifically because* of this task's own change: today, a
  bare `git push` in an existing clone still works by accident (the
  repo-local `credential.helper` wiring `auto-switch.sh`'s
  `SessionStart` hook left behind persists in `.git/config` even after
  the hook stops running). But a **fresh clone that never ran the
  hook** — exactly what `/drive` Phase 1.5's ephemeral cross-repo target
  clones are — has no such wiring, and never will, once the hook is
  deleted with nothing calling these skills' bare `git push` through
  `_gh/git.sh` (the only thing left that wires it, per step 1 below).
  This reintroduces the same wrong-account/no-credential-helper failure
  the hook's git-wiring half was fixing, for exactly the callers most
  likely to hit it. Folded into scope below rather than deferred —
  unlike the `_ipm` bare-`gh` case, this one *is* made strictly worse by
  this task's own change. (Bare `git pull` sites in these same files are
  a **different** call — see Solution step 7's rationale for why they
  stay out of scope.)

## Solution

1. **Move credential wiring into `_gh/git.sh`, not a hook.** Port
   `_auto_switch_wire_git_credentials()` (verbatim logic) into
   `_gh/git.sh` as `_git_wire_credentials()`, called at the top of
   `main_git()` before the `git "$@"` exec. It's cheap (a handful of
   `git config --local` calls) and already idempotent
   (unset-all-before-add), so running it on every `git.sh` invocation
   instead of once per `SessionStart` costs nothing measurable and needs
   no hook at all — `git.sh` becomes fully self-contained.
2. **Delete the global-mutation half outright** — nothing replaces `gh
   auth switch`ing for a genuinely bare, unwrapped `gh` call (a human
   typing `gh` in a terminal, an ad hoc Bash-tool invocation). That
   residual risk is accepted: the fix is removing the *reason* code needs
   to call bare `gh` at all (route everything through the wrapper),
   not re-inventing a global-mutation safety net whose own side effect
   (cross-session account flipping) is what motivated this task.
3. **Delete**: `_gh/auto-switch.sh`, its `hooks/hooks.json` entry (the
   file becomes empty — delete the whole file, nothing else references
   it), `tests/auto-switch.bats`, `README.md:285-308` (the bullet),
   `README.md:29-32` (rewritten to drop the "wires itself automatically"
   note — nothing to wire anymore).
4. **Update `README.md`'s `git.sh` bullet** (`README.md:279-284`) to
   describe the credential wiring as `git.sh`'s own responsibility now,
   not something a separate hook did for it.
5. **Fix `_session/_lib.sh:88-91`**: drop the dead outer
   `GH_TOKEN="$tok"` on the wrapper-present branch (`gh.sh` ignores it
   regardless) — call `bash "$wrapper" "$@"` directly. Keep
   `GH_TOKEN="$tok" gh "$@"` only in the no-wrapper fallback (the CI-only
   exception).
6. **Allowlist `ccxp/scripts/epic-status.sh`** explicitly in the new bats
   check (step 8) — its five `GH_TOKEN="$tok" gh ...` call sites stay
   as-is; they're the documented cross-repo exception, not a violation.
7. **Route the bare `git push` sites in `stage`/`top`/`bottom`/`claim`/
   `retro`/`drive` through `_gh/git.sh`** — the same mechanical edit
   `gcpr/SKILL.md:186` already got. **Scoped to `push` only, not `pull`**
   (see Alternatives rejected for why): a bare `git push` silently
   authenticating as the wrong globally-active account is the actual
   harm this task retires the safety net for; a bare `git pull`/`fetch`
   fails closed (wrong/no credential just errors out) rather than
   silently doing the wrong thing, so it's not this task's problem to
   fix. Verified against the current tree with
   `git grep -nE '(^[[:space:]]*|&& )git push' -- stage/SKILL.md
   top/SKILL.md bottom/SKILL.md claim/SKILL.md retro/SKILL.md
   drive/SKILL.md` — exactly eight hits, all real (an earlier version of
   this check used a `^git push`-anchored, `*/SKILL.md`-repo-wide
   pattern that both false-positived on `address-pr/SKILL.md`'s prose
   mention of "push" and false-negatived on two indented sites; fixed by
   a second review pass, 2026-09-29 — see below):
   - `stage/SKILL.md:78`, `top/SKILL.md:138`, `bottom/SKILL.md:63`,
     `retro/SKILL.md:295`: `git push -u origin "$BRANCH"` →
     `bash ../_gh/git.sh push -u origin "$BRANCH"`.
   - `claim/SKILL.md:129`: `git push -u origin t<id>-claim` →
     `bash ../_gh/git.sh push -u origin t<id>-claim`.
   - `claim/SKILL.md:62,79` (solo-repo mode): the trailing `git push` in
     `git checkout main && git merge --ff-only t<id>-<slug> && git push`
     is the one network call in that chain — rewrite just that segment:
     `... && bash ../_gh/git.sh push`. `git checkout`/`git merge
     --ff-only` stay bare (local-only, no GitHub auth involved).
   - `drive/SKILL.md:114` — the **identical** solo-repo-mode chain,
     restated in prose because that section explicitly says it's "kept
     in sync with" `claim/SKILL.md`'s Solo-repo mode section — fixing
     `claim/SKILL.md` alone would have immediately desynced the two
     docs. Same rewrite.
   - **Checked and excluded**: `address-pr/SKILL.md:129-130` (prose
     mention of "push", not a literal invocation — the broad first-draft
     grep matched it); every bare `git pull`/`git checkout main && git
     pull` site in these six files and in `drive/SKILL.md`'s "Post-merge
     branch hygiene" idiom (7+ occurrences) — pull is out of scope per
     the rationale above, not merely deferred.
   No behavior change for an already-wired clone; restores the missing
   safety net for a fresh one (see Context).
8. **New `tests/gh-wrapper-usage.bats`**: greps all `*.sh`/`*.py` under
   the repo (excluding `tests/**`, `dev/JOURNAL/**`, `dev/TODO/**`,
   `_gh/gh.sh`, `_gh/git.sh` themselves) for a caller-side `GH_TOKEN=`
   assignment; the only permitted hits are the explicit allowlist
   (`ccxp/scripts/epic-status.sh`, `_session/_lib.sh`'s no-wrapper
   fallback line, `actions/sync-tasks/sync.py`). Anything else fails the
   test with the offending `file:line`.
   - **Scope note**: this checks the caller-side-`GH_TOKEN=` half of the
     Problem statement only, not "any bare `gh` call" — see Alternatives
     rejected for why a general bare-`gh`-call detector is out of scope.

**Alternatives rejected**:

- *Keep `auto-switch.sh`'s global-mutation half, drop only the
  credential-wiring half* — rejected: the global mutation is the actual
  harm described in the Problem section (concurrent sessions flipping
  each other's account); keeping it and dropping the harmless
  credential-wiring half would be backwards.
- *Extend `_gh/gh.sh main()` with a `--repo <slug>` override so
  `epic-status.sh` could route through the CLI wrapper fully* —
  rejected as disproportionate scope for a 4h chore: `epic-status.sh`
  already uses the sanctioned account-picking primitives, just not the
  CLI entrypoint; allowlisting it is a one-line test change vs. a new
  `gh.sh` command-line surface + its own tests.
- *Write a general "no bare `gh` call outside the wrapper" static
  checker* — rejected: reliably distinguishing a real invocation
  (`gh pr view`) from a comment/doc-string mentioning `gh` (this repo's
  `SKILL.md`/README files intentionally instruct "use `_gh/gh.sh`" in
  prose and code-fenced examples) needs either an AST-level shell parser
  or a hand-tuned regex with a growing exception list — disproportionate
  for what this task can verify by hand today (one real hit,
  `_ipm/ipm-iteration-drain-check.sh:224`, handled below). The
  `GH_TOKEN=`-assignment check (step 8) is unambiguous and covers the
  Problem section's actual named sites.
- *Rewrite bare `git pull` alongside `git push` in the six affected
  skills, "for consistency"* — rejected on a second look (an earlier
  draft of this design did exactly this, then a second review pass
  caught it): `drive/SKILL.md` alone repeats the idiomatic
  `git checkout main && git pull && git remote prune origin` sequence
  7+ times as its documented "post-merge branch hygiene" — rewriting
  every one to satisfy a "for consistency" instinct would make this
  chore touch a form of expression `drive/SKILL.md` uses throughout,
  for a call whose actual failure mode (a stale/failed read) is not the
  silent-wrong-account harm this task exists to fix. `git push` sites
  are the complete, correct scope.
- *Fix `_ipm/ipm-iteration-drain-check.sh:224`'s bare `gh project
  item-list` call inline here* — rejected: it wasn't in this task's
  original Problem section, isn't touched by anything this task changes,
  and fixing it would mean auditing the *rest* of the repo for similar
  stray bare-`gh` sites to be thorough — real work, but a distinct scope
  from "retire `auto-switch.sh`". Filed as `T20260929-<new-id>` (soft,
  non-blocking — a workaround exists: nothing this task does makes that
  call *worse*, since `auto-switch.sh` was going to flip the wrong
  account under it just as easily as it already might).

## Test plan

- [x] `bats tests/gh-wrapper-usage.bats` — new file, asserts the
      allowlist-scoped `GH_TOKEN=` check (clean repo passes; a fixture
      with a new offending assignment fails with the right `file:line`) —
      all 6 cases pass.
- [x] `bats tests/git.bats` — new cases: `_git_wire_credentials` sets
      `credential.helper` + `url.insteadOf` idempotently, and `main_git`
      wires them unconditionally as the first thing it does (ported from
      the deleted `auto-switch.bats` cases, adapted to `git.sh`'s call
      shape) — all 3 pass.
- [x] `bats tests/*.bats _docs/*.bats` (full suite) passes with
      `auto-switch.bats` gone and no new failures — 779/779, exit 0.
- [x] Manual: a genuinely fresh `git clone` (no prior `SessionStart` hook
      run — confirmed `credential.helper`/`url.insteadOf` both unset
      immediately post-clone) copied the branch's `_gh/git.sh` in and
      sourced `_git_wire_credentials` directly — both entries land
      correctly with no dependency on the retired hook having ever run.
- [x] `git grep` for `GH_TOKEN=`/`"GH_TOKEN":` across the repo (excluding
      `_gh/gh.sh`, `_gh/git.sh`, `tests/**`, `dev/JOURNAL/**`,
      `dev/TODO/**`) turns up only the three allowlisted sites —
      asserted by `tests/gh-wrapper-usage.bats`'s own two checks (exact
      site + exact count per allowlisted file).

## Done criteria

- [x] `_gh/auto-switch.sh`, its `hooks/hooks.json` entry, and
      `tests/auto-switch.bats` are deleted — `git status` shows all
      three as `D`; `ls hooks/ _gh/auto-switch.sh tests/auto-switch.bats`
      all report "No such file or directory".
- [x] `_gh/git.sh` wires repo-local git credentials itself
      (`_git_wire_credentials()`, called unconditionally as the first
      line of `main_git()`) — confirmed by reading the file; covered by
      the new bats cases in Test plan.
- [x] `_session/_lib.sh:88-91`'s dead outer `GH_TOKEN="$tok"` (wrapper-
      present branch) is gone; the no-wrapper CI fallback keeps it —
      confirmed by reading the diff.
- [x] `ccxp/scripts/epic-status.sh`'s five `GH_TOKEN=` sites are
      unchanged (no diff on that file) and explicitly allowlisted in
      `tests/gh-wrapper-usage.bats`.
- [x] `tests/gh-wrapper-usage.bats` exists and fails on an injected new
      offending `GH_TOKEN=` (both a shell and a Python fixture case
      verify this — not just the clean case).
- [x] `README.md:29-32` (install-time note) and the `auto-switch.sh`
      bullet are updated/removed; the `git.sh` bullet documents the
      credential wiring as its own — confirmed by reading the diff.
- [x] `_taskid/url.sh:43` is left untouched here (no diff on that file);
      this task's own Problem-section bullet for it stays as-is until
      T20260925-427007 lands (not blocking this one's merge — either
      task can land first).
- [x] `stage/SKILL.md`, `top/SKILL.md`, `bottom/SKILL.md`,
      `claim/SKILL.md`, `retro/SKILL.md`, `drive/SKILL.md` route every
      bare `git push` against `origin` through `_gh/git.sh` (`git pull`
      explicitly out of scope, not merely deferred — see Solution step
      7's rationale) — `git grep -nE '(^[[:space:]]*|&& )git push' --
      stage/SKILL.md top/SKILL.md bottom/SKILL.md claim/SKILL.md
      retro/SKILL.md drive/SKILL.md` returns empty against the
      implemented tree.
- [x] Follow-up task filed for `_ipm/ipm-iteration-drain-check.sh:224`'s
      bare `gh project item-list` call — T20260929-120385 (see
      Alternatives rejected).
- [x] Full bats suite (`bats tests/*.bats _docs/*.bats`) is green —
      779/779, exit 0.

## Closed (2026-09-29)

- Shipped in [PR #175](https://github.com/Synx-Data-Labs/ccxp-skills/pull/175).
- Every Solution step and Done criterion above is checked off with the
  verification evidence gathered during implementation (bats runs, hand
  greps, a fresh-clone manual test) — none left as external/unverified.
- Filed T20260929-120385 as the one follow-up (out-of-scope bare `gh`
  call in `_ipm/ipm-iteration-drain-check.sh:224`), staged into the next
  iteration.
- Three review rounds on the design PR (#174) each caught a real,
  substantive gap before any code was written: missing bare-`git push`
  callers in `stage`/`top`/`bottom`/`claim`/`retro`, a `drive/SKILL.md`
  site the fix initially missed, and a broken verification grep (too
  broad + too narrow) — all fixed before the design merged.
- A 4th independent review, on the *implementation* PR (#175) itself,
  still caught two real gaps the design didn't anticipate: `_git_wire_
  credentials()` running unconditionally (a behavior change from the
  retired `auto-switch.sh`, which only wired credentials once an account
  was confirmed reachable — silently wiring regardless could break a
  repo authenticating some other way, e.g. an SSH deploy key), and
  `tests/gh-wrapper-usage.bats`'s own `GH_TOKEN=` detector missing
  `GITHUB_TOKEN=`, single-quoted Python dict literals, and subscript/
  `putenv` assignment forms. Both fixed (commit `62f54ce`) before merge —
  a good design doesn't guarantee a good implementation matches it in
  every detail; the review loop caught the gap either way.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — code-class per Phase
  3.0, but this was existing-behavior-preserving infra work (moving/
  fixing wiring, not new logic under a red→green cycle); the sequential
  Implement→Test→Verify Workflow substituted structurally-equivalent
  rigor (write code, run the full suite, adversarially verify against
  the design) — see Phase 3.1's own guidance for this task shape.
- Verification (`superpowers:verification-before-completion`): yes —
  invoked implicitly via the Phase 3.1 Workflow's own Test/Verify stages,
  plus this session's own hands-on re-verification (fresh-clone test,
  direct diff reads, re-running the design's own grep checks) before
  declaring any Done criterion checked.
- Systematic debugging (`superpowers:systematic-debugging`): no — no test
  went red-and-stayed-red across attempts; the only stuck-feeling moment
  (the Test stage's pathspec-syntax false alarm on `sync.py`) resolved in
  one direct re-check, not a multi-attempt debug loop.
- Receiving code review (`superpowers:receiving-code-review`): yes — 4
  independent review rounds total (3 on the design PR #174, 1 on the
  implementation PR #175), each with real findings; all accepted and
  fixed (steelmanned first via re-reading the cited files myself), none
  pushed back on as wrong.
