---
status: Done
estimation: 1
source: Maintainer session, 2026-10-20 — suspected macOS kernel leak investigation
related: T20261020-231370
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261020-242723: Harden `_gh/gh.sh` and `_gh/git.sh` against nested-shebang invocation (investigation-scoped, not a Go rewrite)

> Design approved in-conversation 2026-10-20 — maintainer authorized filing and driving this
> task directly, with the investigation below standing in as the design; design PR skipped.

## TLDR

- **Type**: chore
- **Problem**: a suspected macOS kernel memory leak triggered by nested-shebang invocation
  (a script launching another script via implicit shebang resolution) was thought to implicate
  `_gh/gh.sh`/`_gh/git.sh`, motivating a proposed full Go rewrite.
- **Solution**: investigation found the wrapper's actual call graph never exercises that kernel
  path — every caller uses explicit `bash <path>`, and the wrapper's own internals only `source`
  or exec real compiled binaries — so the fix is a cheap regression-test guardrail instead of a
  rewrite; the Go rewrite is filed separately as an explicitly deprioritized follow-up
  (`T20261020-231370`).

## Problem

- Maintainer suspected a macOS kernel memory leak (`data.kalloc.1024` zone,
  confirmed actively growing on their machine this session) documented to be
  triggered by **nested shebang invocation**: a script launching another
  script via implicit shebang resolution (bare `./script` or `script`
  relying on PATH + kernel shebang parsing) — not explicit interpreter
  invocation (`bash script`/`sh script`), which never exercises that kernel
  code path.
- Proposed fix under consideration: rewrite `_gh/gh.sh`/`_gh/git.sh` as a
  compiled Go binary (no shebang line at all, structurally immune).
- **Required investigation before committing to that rewrite**: does this
  specific wrapper's actual invocation chain exercise the nested-shebang
  trigger at all?

## Context

- `_gh/gh.sh` (`_gh/gh.sh:1-179`) and `_gh/git.sh` (`_gh/git.sh:1-82`) are the
  repo's only sanctioned way to call `gh`/authenticated `git` — every skill
  (`drive/SKILL.md`, `address-pr/SKILL.md`, `verify-site/SKILL.md`) and
  helper script in the suite goes through them for account-picking.
- `_gh/gh.sh`'s account detection (`_gh_list_accounts`, `_gh/gh.sh:61-68`)
  parses `gh auth status` text output with `awk` — fragile, and has already
  caused two real bugs in one session (a mis-linked-gawk regex bug and an
  `LC_ALL=C` locale bug), which is what originally motivated considering a
  rewrite in a memory-safer, locale-independent language.

## Solution

Performed a full audit of `_gh/gh.sh` and `_gh/git.sh`'s invocation chain,
both how callers invoke them and what they invoke internally, before
committing to any fix:

- **Caller side** — grepped every reference to `_gh/gh.sh` / `_gh/git.sh`
  repo-wide (`*.md`, `*.sh`, `*.yml`, `*.yaml`, `*.json`): `drive/SKILL.md:138,163,472,557,558,582`,
  `address-pr/SKILL.md:45-410` (many sites), `verify-site/SKILL.md:37,45,106` +
  `verify-site/scripts/verify.sh:24,33,123`,
  `_session/_lib.sh:89-90`, `_taskid/url.sh:50-51`, `tests/gh.bats:187,215`, `tests/git.bats:58,80`.
  **Every single call site uses explicit `bash <path> ...` invocation.** None
  invoke it as `./gh.sh` / bare `gh.sh` relying on kernel shebang resolution.
- **Internal side** — read both scripts in full:
  - `_gh/git.sh:29` pulls in `gh.sh`'s functions via `source "$_gh_git_dir/gh.sh"`
    — a bash **builtin** that reads the file into the current shell. No
    `exec`, no subprocess, no kernel shebang parsing involved at all.
  - Both scripts' only subprocess calls are to `git`, `gh`, `awk`, `sed`,
    `mktemp` — in particular `_gh/git.sh:75`'s `exec git "$@"` and
    `_gh/gh.sh:155`'s `GH_TOKEN=... gh "$@"` target the real **compiled**
    `gh`/`git` binaries. A compiled binary has no shebang line, so
    `execve()` never reaches the shebang-recursion code path for these
    calls either.
  - No internal implicit-shebang invocation of any other repo script exists
    in either wrapper's call graph (confirmed: `grep -n '\.sh\b' _gh/gh.sh
    _gh/git.sh` turns up only comments plus the one `source` line).
- **Conclusion**: this wrapper's actual invocation chain does **not**
  exercise the suspected nested-shebang kernel code path anywhere — not in
  production usage, not in its own internals. It is not a meaningful
  contributor to the observed leak. The full Go rewrite is therefore
  lower-value than assumed for *this specific target*.

### Alternatives rejected

- **Full Go rewrite now** — rejected per the investigation above; the
  wrapper's call chain doesn't exercise the suspected kernel bug, so the
  primary motivation doesn't hold for this target. Filed instead as an
  explicitly deprioritized follow-up: `T20261020-231370` (the awk/locale
  fragility remains a separate, valid-but-lower-urgency motivation for it).
- **Python rewrite** — rejected per the maintainer's own reasoning: Python
  scripts still carry a shebang and don't structurally avoid the bug unless
  always explicitly invoked (`python3 script.py`), which isn't a structural
  guarantee the language itself provides — same class of risk as the
  current bash scripts.

### Scope of this task (the cheaper fix, in place of the rewrite)

- Audit above is already clean — zero implicit-shebang invocations exist in
  `gh.sh`/`git.sh`'s call graph today, so there is nothing to convert.
- Add a bats regression test (`tests/gh-wrapper-shebang-invocation.bats`)
  asserting no caller/internal invocation of `gh.sh`/`git.sh` uses
  bare/implicit invocation going forward — a structural guardrail against
  regressing into the trigger pattern, in the spirit of the existing
  `tests/gh-wrapper-usage.bats` scan.
- Document this finding in `dev/JOURNAL/` on completion.

## Root cause

- Not a bug — a **misdirected-motivation** investigation task: the premise
  ("this wrapper triggers the kernel bug") was asserted, not verified,
  before the Go-rewrite proposal was made.
- Mechanism (why the premise doesn't hold): the kernel's shebang-recursion
  path is only reached when `execve()` is handed a file whose first two
  bytes are `#!` and the kernel itself resolves and re-execs the named
  interpreter. `_gh/gh.sh:176-178`'s own direct-execution guard
  (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) shows the
  file *is* exec'd directly when run standalone — but every real call site
  in this repo bypasses that path entirely by invoking `bash <path>`
  (`bash` itself is exec'd, and simply reads the script file as its `$1`
  argument — the kernel never parses *that* file's shebang line at all).
  `_gh/git.sh:29`'s `source` of `gh.sh` doesn't exec anything. Introduced
  this way from the start (`_gh/gh.sh` git history — the `bash gh.sh ...`
  usage convention is documented in the file's own header comment,
  `_gh/gh.sh:4-6`, since its original authorship) — a deliberate convention,
  not an oversight that happened to be safe.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_gh/gh.sh` | 1–179 | `gh` wrapper — account-picking logic; audited for internal implicit-shebang calls (none found) |
| `_gh/git.sh` | 1–82 | `git` wrapper — sources `gh.sh` via `source` (builtin, not exec); `exec git "$@"` targets the real compiled binary |
| `drive/SKILL.md` | 138, 163, 472, 557, 558, 582 | caller sites, all `bash <skills-root>/_gh/gh.sh ...` |
| `address-pr/SKILL.md` | 45–410 (many) | caller sites, all `bash <skills-root>/_gh/gh.sh ...` |
| `verify-site/SKILL.md` | 37, 45, 106 | caller sites, all `bash <skills-root>/_gh/gh.sh ...` |
| `verify-site/scripts/verify.sh` | 24, 33, 123 | caller sites, all `bash "$HERE/../../_gh/gh.sh" ...` |
| `_session/_lib.sh` | 89–90 | caller site, `bash "$wrapper" "$@"` (wrapper path built via a variable, still explicit `bash`) |
| `_taskid/url.sh` | 50–51 | caller site, `bash "$_TASKID_URL_DIR/../_gh/gh.sh" "$@"` |
| `tests/gh.bats` | 187, 215 | test subprocess invocation, `bash "$REPO_ROOT/_gh/gh.sh" ...` |
| `tests/git.bats` | 58, 80 | test subprocess invocation, `bash "$REPO_ROOT/_gh/git.sh" ...` |
| `tests/gh-wrapper-usage.bats` | 53–72 | existing sibling scanner this task's new test follows the style of |
| `tests/gh-wrapper-shebang-invocation.bats` | new | this task's new regression-test guardrail |

## Test plan

- [x] `bats tests/gh-wrapper-shebang-invocation.bats` — new test file, all cases pass locally
- [x] `bats tests/gh.bats tests/git.bats tests/gh-wrapper-usage.bats` — no regressions in the
      sibling wrapper test suites
- [x] CI `bats` workflow green on the implementation PR (PR #378)

## Done criteria

- [x] `tests/gh-wrapper-shebang-invocation.bats` added, asserting explicit-invocation-only for
      `gh.sh`/`git.sh`'s call graph, passing in CI (`bats tests/gh-wrapper-shebang-invocation.bats`)
- [x] This task file documents the investigation and "no rewrite" finding (`## Solution` /
      `## Root cause` above)
- [x] A follow-up task filed for the deprioritized Go rewrite, cross-linked via `related:`,
      status `Open`, not driven as part of this task (`T20261020-231370`)
- [ ] `dev/JOURNAL/` entry (pending: Friday retro sweep moves this Done file; investigation outcome is in Solution/Root cause) on completion summarizing the investigation outcome (Phase 7 journal
      move)

## Closed (2026-10-20)

- Shipped in PR #378 (`tests/gh-wrapper-shebang-invocation.bats`, 18 cases, all pass locally).
- Investigation finding (no rewrite needed) is in `## Solution` / `## Root cause`.
- Follow-up `T20261020-231370` (Go rewrite) stays deprioritized, untouched.
- Journal entry: this file, moved to `dev/JOURNAL/` by the Friday retro sweep.

## Skills invoked

- TDD: no - tests landed with PR #378 before this drive; this PR is close-out only (docs-class)
- Verification: yes - reran the new bats file (18/18 ok) before closing
- Systematic debugging: no - did not get stuck
- Receiving code review: no - docs-only close PR
