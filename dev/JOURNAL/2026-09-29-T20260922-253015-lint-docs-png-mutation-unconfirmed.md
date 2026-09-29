---
status: Done
scheduled: 2026-09-28
estimation: 30m
source: T20260910-919422's Closed section, 2026-09-22 — an unconfirmed report from that task's original 2026-09-10 Problem section
related: T20260910-919422
claimed_by:
claimed_role:
---

# T20260922-253015: Confirm or rule out `lint-docs.sh --fix` rewriting a PNG asset

## Problem

- **Type**: research
- `T20260910-919422`'s original Problem section (2026-09-10, consumer-repo
  session) reported that the same `lint-docs.sh --fix` invocation that
  corrupted `+` → `-` prose also rewrote a PNG under a JOURNAL assets
  directory (480829 → 844873 bytes) in the same commit — a markdown linter
  should never touch a binary asset, so this was flagged as unconfirmed
  whether `markdownlint-cli2` itself did it, or something else running in
  the same working tree did.
- This was never re-investigated: the 2026-09-22 recurrence (a different
  consumer repo) reconfirmed the `+`/`-` and comma-spacing corruption with
  full non-redacted evidence, but did not mention or check for a similar
  PNG/binary-asset mutation, so it's still an open, single-instance,
  unconfirmed report from the original session.
- Done looks like: either reproduce the PNG mutation under controlled
  conditions (a fixture tree with a JOURNAL-assets-style PNG, run
  `lint-docs.sh --fix` against it, diff bytes before/after) and confirm/deny
  whether `markdownlint-cli2`'s own process touches non-markdown files at
  all, or — if it can't be reproduced — mark the original report as likely
  an unrelated coincidence (e.g., a different tool running in the same
  working tree at the time) and close with that explanation.

## Context

- `_docs/lint-docs.sh` — its own path-resolution/glob logic (`**/*.md`,
  before or after `T20260910-919422`'s `--no-globs` fix) should never
  select a `.png` file for `markdownlint-cli2` to touch; if a repro
  confirms it does, that's a much more surprising and separate finding
  than the prose-corruption issues already fixed/tracked.

## Confirmed (2026-09-29)

Reproduced under controlled conditions. **`markdownlint-cli2`'s own file
selection — not `lint-docs.sh`'s glob/path logic — is the cause**, and it
happens with or without `--no-globs`.

- **Repro**: fixture tree with `dev/JOURNAL/<assets-dir>/screenshot.png` (a
  minimal valid 68-byte PNG) plus one `.md` file, this repo's real
  `.markdownlint-cli2.jsonc` (`"globs": ["**/*.md"]`) copied alongside.
  - `bash _docs/lint-docs.sh --fix` (bare, default scope — `dev/JOURNAL
    dev/TODO` as directory args) reported `Linting: 2 file(s)` (the `.md`
    files only) but the PNG's bytes changed anyway: 68 → 82 bytes, hash
    changed, `cmp` reports a diff at byte 1.
  - Isolated the mechanism further by bypassing the wrapper script entirely:
    raw `npx --yes markdownlint-cli2@0.22.1 --fix --no-globs dev/JOURNAL
    dev/TODO` (directories as literal args) reproduces the identical
    corruption — so this is **not** a `lint-docs.sh`-specific bug, it's
    `markdownlint-cli2` itself.
  - Check-only mode (no `--fix`) leaves the PNG's bytes untouched, but
    still counts it as a lintable file and reports a real (bogus) violation
    against it: `screenshot.png:4:56 error MD047/single-trailing-newline`.
    So `markdownlint-cli2`, when given a **directory** as a positional
    argument, does not filter its candidate file set to `.md` at all —
    the config's `globs: ["**/*.md"]` is not applied when a directory path
    is passed on the CLI; every file under it becomes a candidate.
  - With `--fix` enabled, the tool decodes each candidate file as UTF-8 text
    and rewrites it (invalid byte sequences replaced with U+FFFD, `\r\n`
    normalized to `\n`), which is what corrupts binary content and changes
    its length. Byte-level diff confirms this pattern exactly (e.g. the PNG
    signature byte `0x89` — invalid as a UTF-8 lead byte alone — becomes the
    3-byte replacement char `EF BF BD`).
  - Control: an explicit **single `.md` file** argument (`markdownlint-cli2
    --fix --no-globs dev/JOURNAL/note.md`) leaves the PNG completely
    untouched — it's never a candidate when the argument is a file, not a
    directory.
- **Conclusion**: the 2026-09-10 PNG mutation was not a coincidence or an
  unrelated tool — it's the same `markdownlint-cli2 --fix` invocation, same
  root mechanism as the `+`/`-` and comma-spacing prose corruption
  (`T20260910-919422`), just manifesting on a binary file instead of text.
  Any `lint-docs.sh` call whose effective file-selector is a **directory**
  (the bare/default no-args scope — still used by `ccxp/SKILL.md:422` and
  `retro/SKILL.md:293` per `git grep -n "lint-docs.sh --fix"`) risks
  silently corrupting any non-`.md` file — binary or otherwise — that lives
  under `dev/JOURNAL`/`dev/TODO` when it runs. The explicit-single-file
  invocation path (`new-task`, `drive` Phase 7, `gcpr`'s per-file loop, and
  the isolated safe-fix tmpdir copy from `T20260922-383156`) is unaffected,
  since the PNG is never a member of the file list in the first place.
- **Not fixed here** (research task, scoping deliberately confirm/deny-only
  — see Problem's "Done looks like"): `T20260928-608242` ("Remove
  `lint-docs.sh`'s `--fix` entirely and require an explicit path argument",
  already open, unrelated discovery 2026-09-28) independently proposes
  removing `--fix` and making a path argument mandatory — once shipped, the
  bare/default-scope directory-argument path this task reproduces can no
  longer occur, closing this corruption vector as a side effect. Left a
  note on that task (its own "Update the two callers" step names only
  `gcpr`/`new-task`, but `ccxp`/`retro` also invoke the bare form and would
  need the same update) rather than duplicating a fix task here.

## Closed (2026-09-29)

- Confirmed (see "Confirmed (2026-09-29)" above) — the PNG mutation is real
  and reproducible, not a coincidence. Root cause: `markdownlint-cli2`
  doesn't filter to `.md` when given a directory argument; `--fix` then
  corrupts every non-`.md` file found there via a lossy UTF-8
  decode/re-encode + newline normalization.
- No code change shipped from this task — it was scoped confirm/deny-only.
  The fix is already tracked in the pre-existing open task
  `T20260928-608242` (which independently targeted the same directory-arg
  default-scope path); left a note there about a caller-list gap
  (`ccxp`/`retro` also invoke the bare form) found while cross-checking call
  sites for this investigation.
- Design PR skipped: this is a pure research/reproduction task with no
  implementation decision — the investigation plan was already fully
  specified in the Problem section, and the deliverable is the finding
  itself, written directly into this file.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class, pure
  investigation/write-up, no code shipped
- Verification (`superpowers:verification-before-completion`): yes —
  reproduced the finding three independent ways (via the wrapper script,
  via raw `npx markdownlint-cli2` bypassing the wrapper, and via a
  file-vs-directory control) before writing up the conclusion
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; each hypothesis (wrapper bug vs. tool bug vs. coincidence) was
  falsified or confirmed on the first isolating test
- Receiving code review (`superpowers:receiving-code-review`): no — no
  code change, no Claude Code review dispatched
