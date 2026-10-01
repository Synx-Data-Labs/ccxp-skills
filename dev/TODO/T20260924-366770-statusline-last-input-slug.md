---
status: In Progress
scheduled: 2026-09-28
estimation: 2
source: this conversation, 2026-09-24
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
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

## Design

Grilled via `/incept` 2026-10-01.

- **Architecture**: a new `UserPromptSubmit` hook caches the raw prompt
  text per-session; `statusline-command.sh` just reads that cache file.
  Replaces the original "parse `transcript_path`'s JSONL at render time"
  design wholesale — confirmed via Claude Code's own hooks docs that
  `UserPromptSubmit` fires exactly once per genuine human submission
  (slash commands included, as their literal typed text), carrying
  `prompt`/`session_id`/`cwd` on stdin. This makes the original filtering
  concern (transcript tool-result entries also carry `role: user`,
  confirmed by inspecting this session's own transcript JSONL) moot —
  the hook never sees anything but real human input.
- **Cache path**: `~/.claude/state/last-input/<session_id>`, one line of
  plain text, overridable via a `LAST_INPUT_STATE_DIR` env var mirroring
  `claimant-id.sh`'s existing `CLAIMANT_STATE_DIR` convention, for BATS
  isolation.
- **Truncation/sanitization**: happens in the hook at write-time (~40
  chars + `…` if truncated, newlines replaced with spaces) — the hook
  fires once per submitted prompt, vs. `statusline-command.sh` which can
  render far more often, so keeping that already perf-sensitive path
  (SKILL.md's "never let it hang" rule) to a bare file read.
- **Stale-cache cleanup**: the hook self-prunes files older than 30 days
  from `last-input/` on each write — not tied to `SessionEnd`, since
  `/clear` or a crashed session can skip that hook.
- **Deploy wiring**: `statusline-setup/SKILL.md`'s deploy workflow gets a
  new step verifying/adding the `UserPromptSubmit` hook entry in
  `settings.json`, additive alongside the existing unrelated iTerm2 hook
  on that same event, across every config dir in play (same multiplicity
  caveat the skill already documents for `statusLine.command`).
- **Empty case**: no cache file yet for this session → the segment is
  omitted, matching every other `sl-*` helper's existing degrade-to-empty
  convention.
- **Not a new security exposure**: the raw prompt text already persists
  in `~/.claude/projects/*.jsonl` transcripts regardless of this feature;
  caching a truncated copy under `~/.claude/state/` doesn't meaningfully
  change the exposure surface.
- **Behavior under `/autopilot`**: the slug stays pinned to whatever was
  last typed before the unattended run started — correct, not a bug, since
  that genuinely is the last human input.
- **Out of scope**: real LLM-generated summarization — confirmed the
  script stays pure bash/jq, no model call at render time; "slug" means
  mechanical truncation only.

Estimation revised from 1h to 2h: the accepted design needs a new hook
script, a settings.json-wiring step folded into the existing deploy
skill, a self-pruning mechanism, and BATS coverage across three surfaces
(hook write, statusline read, pruning) instead of a single-script change.

### Test Plan

- Hook script: writes a sanitized, truncated, single-line file to
  `LAST_INPUT_STATE_DIR/<session_id>` for a synthetic `UserPromptSubmit`
  stdin payload; multi-line/huge input collapses to one line capped at
  ~40 chars; a write past the 30-day prune window removes stale sibling
  files.
- `statusline-command.sh`: a new helper reads the cache file keyed by the
  stdin payload's `session_id` and emits it as a joined segment; emits
  nothing when no cache file exists yet for that session.
- Deploy workflow: `/statusline-setup` (no argument) confirms
  `settings.json`'s `hooks.UserPromptSubmit` includes the new entry
  across every config dir, without disturbing the existing iTerm2 hook
  entry.
