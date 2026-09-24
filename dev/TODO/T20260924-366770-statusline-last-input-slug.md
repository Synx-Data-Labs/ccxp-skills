---
status: Open
estimation: 1h
source: this conversation, 2026-09-24
---

# T20260924-366770: Add a last-user-input slug to the statusline

## Problem

- **Type**: feature
- `statusline-setup/scripts/statusline-command.sh` currently renders
  `ctx: N% left | branch: X | TASK: ...` — with several sessions/clones
  running in parallel, there's no quick way to tell *what the user last
  asked in this particular session* just by glancing at the status bar.
- Requested: append a short slug/summary of the last user input to the
  statusline, so the context is visible at a glance without switching to
  the terminal's scrollback.
- Open questions for design:
  - The statusLine hook's stdin JSON (parsed via `jq` today for `cwd` and
    `context_window.remaining_percentage`) needs to actually carry a
    `transcript_path` (or equivalent) field to source the last user
    message from — confirm this against the current hook schema before
    implementing.
  - The script is pure bash/jq with no LLM call at render time, so the
    "summary" can only be a mechanical truncation/single-line-ification of
    the raw last user message, not a real generated summary — set
    expectations accordingly (truncate length, strip newlines).
  - How to handle a last input that's huge (a pasted file, `<pasted_content>`
    block) or empty (e.g. right after a tool-only turn with no new user
    text).
