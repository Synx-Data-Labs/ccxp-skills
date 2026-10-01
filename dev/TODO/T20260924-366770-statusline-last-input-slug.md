---
status: In Progress
scheduled: 2026-09-28
estimation: 2
source: this conversation, 2026-09-24
related: statusline-setup/SKILL.md; _session/claimant-id.sh
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
---

# T20260924-366770: Add a last-user-input slug to the statusline

## TLDR

- **Type**: feature
- **Problem**: `statusline-command.sh` (`statusline-setup/scripts/statusline-command.sh:197`)
  renders `ctx: N% left | branch: X | TASK: ...` with no way to tell *what
  the user last typed in this particular session* at a glance, which matters
  once several clones/sessions run in parallel.
- **Solution**: a new `UserPromptSubmit` hook caches the raw prompt text
  per-session under `~/.claude/state/last-input/<session_id>`;
  `statusline-command.sh` just reads that cache file and joins it in as one
  more segment.

## Problem

- `statusline-command()` (`statusline-setup/scripts/statusline-command.sh:169-198`)
  builds its line from `ap_part`/`ctx_part`/`branch_part`/`task_part` only —
  no user-input signal exists today.
- Verified: a live `~/.claude/settings.json`'s `hooks` block has no
  per-session last-input cache; the only `UserPromptSubmit` entry present is
  the unrelated iTerm2 status hook (`hooks.UserPromptSubmit[0].hooks[0].command
  == "~/.config/iterm2/cc-status"`), confirmed by reading that file
  directly.
- Impact: glancing at the terminal status bar across several parallel
  clones/sessions gives no clue which one is working on what was just typed
  — the only way to tell today is switching into each session's scrollback.

## Context

- Feature, not a regression — `statusline-command.sh` predates routine
  multi-session/multi-clone usage, so no "what did I just ask this session"
  segment was ever designed in.
- Builds directly on the existing `sl-*` helper convention in
  `statusline-setup/scripts/statusline-command.sh` (`sl-branch-name`,
  `sl-claimed-task-label`, `sl-autopilot-part`, joined via `sl-join:160-167`)
  — this feature is one more `sl-*` helper + one more `sl-join` argument, not
  a new architecture.
- Reuses the clone-stable per-session caching pattern already established by
  `_session/claimant-id.sh`'s `CLAIMANT_STATE_DIR`/`_claimant_cached`
  (`_session/claimant-id.sh:30,58-81`) — this task mirrors that convention for a
  new `LAST_INPUT_STATE_DIR` rather than inventing a new one.
- Grilled via `/incept` 2026-10-01 (see Solution below for the resulting
  design and the alternative it replaced).

## Solution

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
- **New files**: `statusline-setup/scripts/last-input-hook.sh` (the
  `UserPromptSubmit` hook script) and a new `sl-last-input-part` helper added
  to `statusline-setup/scripts/statusline-command.sh` alongside
  `sl-autopilot-part` (`statusline-setup/scripts/statusline-command.sh:99`).
- **Cache path**: `~/.claude/state/last-input/<session_id>`, one line of
  plain text, overridable via a `LAST_INPUT_STATE_DIR` env var mirroring
  `claimant-id.sh`'s existing `CLAIMANT_STATE_DIR` convention
  (`_session/claimant-id.sh:30`), for BATS isolation.
- **Truncation/sanitization**: happens in the hook at write-time (~40
  chars + `…` if truncated, newlines replaced with spaces) — the hook
  fires once per submitted prompt, vs. `statusline-command.sh` which can
  render far more often, so keeping that already perf-sensitive path
  (`statusline-setup/SKILL.md`'s "never let it hang" rule) to a bare file
  read.
- **Stale-cache cleanup**: the hook self-prunes files older than 30 days
  from `last-input/` on each write — not tied to `SessionEnd`, since
  `/clear` or a crashed session can skip that hook.
- **Deploy wiring**: `statusline-setup/SKILL.md`'s deploy workflow gets a
  new step verifying/adding the `UserPromptSubmit` hook entry in
  `settings.json`, additive alongside the existing unrelated iTerm2 hook
  confirmed above, across every config dir in play (same multiplicity
  caveat the skill already documents for `statusLine.command`,
  `statusline-setup/SKILL.md:49-68`).
- **Empty case**: no cache file yet for this session → the segment is
  omitted, matching every other `sl-*` helper's existing degrade-to-empty
  convention (e.g. `sl-autopilot-part`'s own early `return 0`s,
  `statusline-setup/scripts/statusline-command.sh:102,111`).
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

**Alternatives considered and rejected:**

- Parse `transcript_path`'s JSONL at render time (original candidate) —
  rejected: `statusline-command.sh` runs on every prompt render, so
  re-reading and filtering a growing JSONL transcript file on every render
  is unnecessary I/O for data a one-shot hook can cache instead; it also
  requires distinguishing genuine human turns from tool-result entries that
  also carry `role: user`, which the `UserPromptSubmit` hook sidesteps
  entirely (it never sees anything but real human input).
- Generate a real LLM summary of the last input — rejected: the statusline
  path has no model call today and adding one would mean a network round
  trip on every render; mechanical truncation is instant and matches the
  existing pure bash/jq architecture.
- Tie cache cleanup to `SessionEnd` — rejected: `/clear` or a crashed
  session can skip that hook, leaving stale files to accumulate forever;
  self-pruning on write is unconditional instead.

Estimation revised from 1h to 2h: the accepted design needs a new hook
script, a settings.json-wiring step folded into the existing deploy
skill, a self-pruning mechanism, and BATS coverage across three surfaces
(hook write, statusline read, pruning) instead of a single-script change.

## Test plan

- [ ] Unit: `tests/last_input_hook.bats` — hook writes a sanitized,
      truncated, single-line file to `LAST_INPUT_STATE_DIR/<session_id>`
      for a synthetic `UserPromptSubmit` stdin payload.
- [ ] Unit: `tests/last_input_hook.bats` — multi-line/huge input collapses
      to one line capped at ~40 chars with a trailing `…`.
- [ ] Unit: `tests/last_input_hook.bats` — a write past the 30-day prune
      window removes stale sibling files.
- [ ] Unit: `tests/statusline_setup.bats` — `sl-last-input-part` reads the
      cache file keyed by the stdin payload's `session_id` and emits it as
      a joined segment; emits nothing when no cache file exists yet.
- [ ] Local: `/statusline-setup` (no argument) confirms `settings.json`'s
      `hooks.UserPromptSubmit` includes the new entry across every config
      dir, without disturbing the existing iTerm2 hook entry.
- [ ] CI: `bats tests/last_input_hook.bats tests/statusline_setup.bats`
      green.

## Done criteria

- [ ] Hook writes a sanitized, truncated, single-line cache file — pinned by `tests/last_input_hook.bats`.
- [ ] Stale cache files (>30 days) are pruned on write — pinned by `tests/last_input_hook.bats`.
- [ ] `statusline-command.sh` renders the last-input segment when present and omits it when absent — pinned by `tests/statusline_setup.bats`.
- [ ] `settings.json`'s `UserPromptSubmit` hook array gains the new entry without disturbing the iTerm2 entry — pinned by `tests/statusline_setup.bats` and `statusline-setup/SKILL.md:46-68`.
- [ ] Ships in PR #0 (placeholder until raised) — `statusline-setup/scripts/last-input-hook.sh`.

## Root cause

Not a bug — this is a gap-analysis, not a regression root cause:

- `statusline-command.sh` (introduced before routine multi-session/
  multi-clone usage) was written around three signals only — context
  budget, branch, claimed task (`sl-autopilot-part`/`sl-branch-name`/
  `sl-claimed-task-label`, `statusline-setup/scripts/statusline-command.sh:49-156`).
  No per-session "what did the human just type" signal was ever in scope,
  so its absence isn't an oversight to fix so much as a capability to add.
- The `UserPromptSubmit` hook event already exists in Claude Code's hook
  schema and is already wired for an unrelated purpose
  (a live `~/.claude/settings.json`'s iTerm2 `cc-status` entry, verified
  directly) — this task adds a second, independent hook entry on the same
  event rather than introducing new hook machinery.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `statusline-setup/scripts/statusline-command.sh` | `99-167` | existing `sl-*` helper + `sl-join` convention this feature extends |
| `statusline-setup/scripts/statusline-command.sh` | `169-198` | `statusline-command()` — wires the new `sl-last-input-part` into the joined line |
| `statusline-setup/scripts/last-input-hook.sh` | new file | the `UserPromptSubmit` hook: sanitize, truncate, write, prune |
| `_session/claimant-id.sh` | `30,58-81` | `CLAIMANT_STATE_DIR`/`_claimant_cached` convention mirrored for `LAST_INPUT_STATE_DIR` |
| `statusline-setup/SKILL.md` | `46-68` | deploy workflow — multi-config-dir wiring convention to extend for the new hook |
| `tests/statusline_setup.bats` | existing | add coverage for `sl-last-input-part` |
| `tests/last_input_hook.bats` | new file | hook write/truncate/prune coverage |

## Closed

_(pending)_

## Skills invoked

_(pending — recorded at Phase 7.0)_
