---
status: Open
estimation: 1
source: Maintainer session, 2026-10-20 — suspected macOS kernel leak investigation
related: T20261020-231370
---

# T20261020-242723: Harden `_gh/gh.sh` and `_gh/git.sh` against nested-shebang invocation (investigation-scoped, not a Go rewrite)

## Problem

- **Type**: chore
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

## Root cause / investigation

Performed a full audit of `_gh/gh.sh` and `_gh/git.sh`'s invocation chain,
both how callers invoke them and what they invoke internally:

- **Caller side** — grepped every reference to `_gh/gh.sh` / `_gh/git.sh`
  repo-wide (`*.md`, `*.sh`, `*.yml`, `*.yaml`, `*.json`): `drive/SKILL.md`,
  `address-pr/SKILL.md`, `verify-site/SKILL.md` + `verify-site/scripts/verify.sh`,
  `_session/_lib.sh`, `_taskid/url.sh`, `tests/gh.bats`, `tests/git.bats`.
  **Every single call site uses explicit `bash <path> ...` invocation.** None
  invoke it as `./gh.sh` / bare `gh.sh` relying on kernel shebang resolution.
- **Internal side** — read both scripts in full
  (`_gh/gh.sh`, `_gh/git.sh`):
  - `git.sh` pulls in `gh.sh`'s functions via `source "$_gh_git_dir/gh.sh"`
    — a bash **builtin** that reads the file into the current shell. No
    `exec`, no subprocess, no kernel shebang parsing involved at all.
  - Both scripts' only subprocess calls are to `git`, `gh`, `awk`, `sed`,
    `mktemp` — in particular `git.sh`'s `exec git "$@"` and `gh.sh`'s
    `GH_TOKEN=... gh "$@"` target the real **compiled** `gh`/`git` binaries.
    A compiled binary has no shebang line, so `execve()` never reaches the
    shebang-recursion code path for these calls either.
  - No internal implicit-shebang invocation of any other repo script exists
    in either wrapper's call graph.
- **Conclusion**: this wrapper's actual invocation chain does **not**
  exercise the suspected nested-shebang kernel code path anywhere — not in
  production usage, not in its own internals. It is not a meaningful
  contributor to the observed leak. The full Go rewrite is therefore
  lower-value than assumed for *this specific target* and is being scoped
  as a documented, deprioritized follow-up (see Related) rather than this
  task's deliverable.

## Scope of this task (smaller, cheaper fix)

- Audit above is already clean — zero implicit-shebang invocations exist in
  `gh.sh`/`git.sh`'s call graph today, so there is nothing to convert.
- Add a regression test (bats) asserting no caller/internal invocation of
  `gh.sh`/`git.sh` (or anything they source/exec) uses bare/implicit
  invocation going forward — a structural guardrail against regressing into
  the trigger pattern, in the spirit of the existing
  `tests/gh-wrapper-usage.bats` scan.
- Document this finding in `dev/JOURNAL/` on completion.
- File a separate, explicitly deprioritized follow-up task for the Go
  rewrite (see Related) — do not drive it as part of this task.

## Alternatives rejected

- **Full Go rewrite now** — rejected per the investigation above; the
  wrapper's call chain doesn't exercise the suspected kernel bug, so the
  primary motivation doesn't hold for this target.
- **Python rewrite** — rejected per the maintainer's own reasoning: Python
  scripts still carry a shebang and don't structurally avoid the bug unless
  always explicitly invoked (`python3 script.py`), which isn't a structural
  guarantee the language itself provides — same class of risk as the
  current bash scripts.

## Done criteria

- New bats test(s) added asserting explicit-invocation-only for
  `gh.sh`/`git.sh`'s call graph, passing in CI.
- This task file documents the investigation and "no rewrite" finding
  (above).
- A follow-up task filed for the deprioritized Go rewrite, cross-linked via
  `related:`, status `Open`, not driven as part of this task.
- `dev/JOURNAL/` entry on completion summarizing the investigation outcome.
