---
status: Open
estimation: 1
source: Follow-up from T20261020-242723 investigation, 2026-10-20
related: T20261020-242723
---

# T20261020-231370: Rewrite `_gh/gh.sh` / `_gh/git.sh` as a compiled Go binary (deprioritized)

## Problem

- **Type**: feature
- `_gh/gh.sh`'s account-detection logic parses `gh auth status` text output
  with `awk` (`_gh_list_accounts` in `_gh/gh.sh`). This fragile text-parsing
  approach has already caused two real bugs in a single session: a
  mis-linked-gawk regex bug, and an `LC_ALL=C` locale bug.
- A compiled Go binary using structured data (`gh auth status --json` or
  direct Go API calls) would eliminate this whole class of
  locale/parsing-dependent bugs structurally, not just port the same
  fragile logic to a new language.
- **This was originally proposed as a fix for a suspected macOS kernel
  memory leak** (`data.kalloc.1024` zone) triggered by nested shebang
  invocation. T20261020-242723's investigation found that `_gh/gh.sh` /
  `_gh/git.sh`'s actual invocation chain — every caller uses explicit
  `bash <path>`, and internally the scripts only `source` each other
  (bash builtin, no exec) or exec the real compiled `gh`/`git` binaries
  (no shebang to parse) — does **not** exercise that kernel code path at
  all. The nested-shebang motivation for this rewrite does not hold for
  this target.
- **Deprioritized**: this task remains valid on its own merits (the
  awk/locale fragility), but is not urgent — it is not fixing an active
  kernel-leak contributor. Do not treat this as blocking or urgent;
  revisit only if the awk-based account detection causes further bugs or
  there's spare capacity.

## Done criteria (if/when picked up)

- Go CLI replacement for `_gh/gh.sh` and `_gh/git.sh` (one or two binaries),
  same account-picker behavior, env var bridging, and error messages as
  closely as reasonably possible.
- Account detection uses structured data (`gh auth status --json` or
  equivalent), not text-parsing.
- Build/bootstrap story documented (minimal `go build` step, e.g.
  `_gh/bin/gh`, `_gh/bin/git`).
- All call sites across the skill suite updated to invoke the compiled
  binary directly (grep repo-wide for `_gh/gh.sh`/`_gh/git.sh` to verify
  nothing is missed).
- Tests: `go test` for internal logic, plus adapted `tests/gh.bats`-style
  black-box tests against the compiled binary. Note explicitly that the
  fake-broken-awk/locale regression tests become moot (no awk dependency).
