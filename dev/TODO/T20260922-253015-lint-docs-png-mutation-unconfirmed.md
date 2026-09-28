---
status: Open
scheduled: 2026-10-05
estimation: 30m
source: T20260910-919422's Closed section, 2026-09-22 — an unconfirmed report from that task's original 2026-09-10 Problem section
related: T20260910-919422
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
