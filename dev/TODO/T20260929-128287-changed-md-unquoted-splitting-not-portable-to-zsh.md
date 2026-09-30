---
status: Open
scheduled: 2026-10-05
estimation: 1h
source: discovered while implementing T20260928-608242 (2026-09-29)
related: T20260910-919422, T20260627-192311, T20260928-608242
---

# T20260929-128287: `$CHANGED_MD`-style unquoted word-splitting silently lints zero files under zsh

## Problem

- The `$CHANGED_MD` doc-lint recipe (`gcpr/SKILL.md` Step 1.5, originally
  T20260627-192311; now reused by `ccxp/SKILL.md` 1.3b and
  `ccxp/scripts/reclaim-sweep-pr.sh` as of T20260928-608242) relies on
  **unquoted** variable expansion to word-split a newline-joined file list
  into separate positional args:

  ```bash
  CHANGED_MD=$(git status --porcelain | awk '...' | grep -E '\.md$' || true)
  # shellcheck disable=SC2086
  bash ../_docs/lint-docs.sh $CHANGED_MD ...
  ```

- This only word-splits on newlines under a POSIX/bash-style shell where the
  unquoted expansion happens in the same process that will run
  `_docs/lint-docs.sh`. **Reproduced directly** (this session's own Bash
  tool shell is zsh — `$0` reports `/bin/zsh`, `$BASH_VERSION` is empty):

  ```
  $ x=$'a.md\nb.md\nc.md'; set -- $x; echo "argc=$#"
  argc=1
  ```

  zsh does not perform IFS word-splitting on unquoted parameter expansion by
  default (needs `setopt SH_WORD_SPLIT` or `$=x`) — the entire multi-line
  string is passed through as **one** argument. Confirmed the resulting
  failure mode: `bash _docs/lint-docs.sh $CHANGED_MD` (executed at a zsh
  prompt) called the script with a single argument containing embedded
  newlines, which matches no real file — `markdownlint-cli2 --no-globs`
  reports `Linting: 0 file(s)` / `Summary: 0 error(s)` and **exits 0**.
- **Impact**: on any zsh-default environment (macOS Terminal's default shell
  since Catalina — this repo's own `dev/spinup`/session docs already note
  "Shell: zsh" for at least this clone), the local doc-lint pre-commit guard
  silently becomes a no-op — it reports clean regardless of real content,
  with no visible symptom (the PR's own CI `Markdown Lint` check is the
  actual, unaffected backstop, so this degrades defense-in-depth rather than
  causing a visible failure — which is presumably why it went unnoticed
  since T20260627-192311).
- **Confirmed NOT an issue** for a `.sh` file with a `#!/usr/bin/env bash`
  shebang invoked as `bash script.sh` (e.g. `reclaim-sweep-pr.sh`,
  `update-roadmap.sh`) — once bash itself is the process performing the
  expansion, word-splitting works correctly regardless of the outer/login
  shell. The risk is specific to a bare ` ```bash ` fenced snippet in a
  `SKILL.md` that an agent executes directly via its Bash tool, whose
  underlying shell is whatever `$SHELL`/harness default applies (zsh here).

## Context

- Found while implementing T20260928-608242 (removing `lint-docs.sh --fix`
  and giving `ccxp/SKILL.md`/`ccxp/scripts/reclaim-sweep-pr.sh` a
  `$CHANGED_MD`-derived replacement for their prior bare/no-path `--fix`
  calls) — the replacement code mirrors `gcpr/SKILL.md`'s pre-existing
  pattern verbatim, so it inherits this same latent fragility rather than
  introducing a new one.
- Soft/non-blocking for T20260928-608242: the guard degrading to a silent
  no-op under zsh is a pre-existing condition of the pattern it's reusing,
  and CI `Markdown Lint` remains the authoritative gate either way — noted
  here rather than fixed inline to avoid scope creep across every
  `$CHANGED_MD`-style site in one unrelated PR.

## Solution (draft — not yet designed in full)

- Likely direction: read the newline-joined list into a real bash array
  with `mapfile`/`readarray` (bash-only, but these call sites already
  `bash ../_docs/lint-docs.sh ...`, so wrapping the whole guard in an
  explicit `bash -c '...'` — or moving the array-building into the same
  `bash -c` invocation — sidesteps the outer shell's splitting rules
  entirely) instead of relying on ambient word-splitting.
- Needs a survey of every `$CHANGED_MD`/`$CHANGED_TASKS`/`$CHANGED_REFS`-style
  unquoted-splitting site (`gcpr/SKILL.md`, `ccxp/SKILL.md`,
  `ccxp/scripts/reclaim-sweep-pr.sh`, and any `lint_paragraphs.py --changed
  $CHANGED_TASKS` / `lint_refs.py --fix --changed $CHANGED_MD` callers) —
  out of scope to enumerate exhaustively here; that survey is this task's
  own first design step.
- Alternatives to weigh: `setopt SH_WORD_SPLIT` isn't available to force from
  inside a plain ```bash fence executed by a possibly-zsh harness; NUL/
  newline-delimited + `xargs -0`-style piping avoids the splitting question
  entirely but changes every call site's shape.

## Test plan

- [ ] A bats/manual repro proving the fix: build a `$CHANGED_MD`-shaped
  multi-line variable, run the guard's replacement recipe under both
  `bash -c` and a simulated zsh-splitting-disabled context, and confirm both
  correctly enumerate N > 1 files.

## Done criteria

- [ ] Every `$CHANGED_MD`/`$CHANGED_TASKS`/`$CHANGED_REFS`-style call site
  reads multi-file lists in a shell-portable way (not dependent on the
  invoking shell's word-splitting default) — verified by the test plan
  above plus a `git grep` sweep confirming no remaining bare unquoted
  multi-line expansion feeding a command's argv.

## Skills invoked

(filled at close)
