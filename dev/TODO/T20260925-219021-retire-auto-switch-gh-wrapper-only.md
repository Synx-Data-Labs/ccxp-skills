---
status: Design
estimation: 4h
source: lsc-pa conversation, 2026-09-25
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
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
   drive/SKILL.md` — exactly seven hits, all real (an earlier version of
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

- [ ] `bats tests/gh-wrapper-usage.bats` — new file, asserts the
      allowlist-scoped `GH_TOKEN=` check (clean repo passes; a fixture
      with a new offending assignment fails with the right `file:line`).
- [ ] `bats _gh/*.bats` (or wherever `git.sh`/`gh.sh` tests live) — new
      case: `_git_wire_credentials` sets `credential.helper` +
      `url.insteadOf` idempotently (ported from the deleted
      `auto-switch.bats` cases, adapted to `git.sh`'s call shape).
- [ ] `bats tests/*.bats _docs/*.bats` (full suite) passes with
      `auto-switch.bats` gone and no new failures.
- [ ] Manual: on a scratch clone with no prior `SessionStart` hook run
      (fresh `.git/config`, no `credential.helper`), `bash _gh/git.sh
      push -u origin <throwaway-branch>` succeeds — proves `git.sh` no
      longer depends on the retired hook having run first.
- [ ] `git grep -n 'GH_TOKEN='` across the repo (excluding `_gh/gh.sh`,
      `_gh/git.sh`, `tests/**`) turns up only the three allowlisted
      sites.

## Done criteria

- [ ] `_gh/auto-switch.sh`, its `hooks/hooks.json` entry, and
      `tests/auto-switch.bats` are deleted — `git status` / `ls hooks/`
      confirm.
- [ ] `_gh/git.sh` wires repo-local git credentials itself
      (`_git_wire_credentials()`, called from `main_git()`) — see the new
      bats case in Test plan.
- [ ] `_session/_lib.sh:88-91`'s dead outer `GH_TOKEN="$tok"` (wrapper-
      present branch) is gone; the no-wrapper CI fallback keeps it.
- [ ] `ccxp/scripts/epic-status.sh`'s five `GH_TOKEN=` sites are
      unchanged and explicitly allowlisted in
      `tests/gh-wrapper-usage.bats`.
- [ ] `tests/gh-wrapper-usage.bats` exists and fails on an injected new
      offending `GH_TOKEN=` (verified during implementation, not just
      asserted).
- [ ] `README.md:29-32` (install-time note) and `README.md:285-308`
      (the `auto-switch.sh` bullet) are updated/removed; the
      `git.sh` bullet documents the credential wiring as its own.
- [ ] `_taskid/url.sh:43` is left untouched here; this task's own
      Problem-section bullet for it is struck through with a pointer to
      T20260925-427007 once that task lands (not blocking this one's
      merge — either task can land first).
- [ ] `stage/SKILL.md`, `top/SKILL.md`, `bottom/SKILL.md`,
      `claim/SKILL.md`, `retro/SKILL.md`, `drive/SKILL.md` route every
      bare `git push` against `origin` through `_gh/git.sh` (see
      Solution step 7's per-file line list; `git pull` is explicitly out
      of scope, not merely deferred — see that step's rationale) —
      `git grep -nE '(^[[:space:]]*|&& )git push' -- stage/SKILL.md
      top/SKILL.md bottom/SKILL.md claim/SKILL.md retro/SKILL.md
      drive/SKILL.md` (verified against the pre-implementation tree to
      return exactly the 7 real sites Solution step 7 lists — an
      earlier, broader draft of this exact check both false-positived on
      `address-pr/SKILL.md` and false-negatived on two indented sites;
      fixed by a second review pass, 2026-09-29) comes back empty once
      all 7 are rewritten.
- [ ] Follow-up task filed for `_ipm/ipm-iteration-drain-check.sh:224`'s
      bare `gh project item-list` call (see Alternatives rejected).
- [ ] Full bats suite (`bats tests/*.bats _docs/*.bats`) is green.
