---
status: In Progress
scheduled: 2026-10-12
estimation: 2
source: this conversation, 2026-10-10
claimed_by: cc1-50ac6891:ccfce931e6835f9b
claimed_role: interactive
---

# T20261010-736699: New `/agent-pairing on|off|status` skill — toggle a dispatcher main-session agent

## Problem

- **Type**: feature
- User already runs a working "dispatcher" pattern in `~/.claude-personal`:
  a custom main-session agent (`agents/dispatcher.md`, tools restricted to
  `Agent, SendMessage, ListAgents, TaskStop, AskUserQuestion, ToolSearch`)
  set as the profile default via `"agent": "dispatcher"` in
  `settings.json`. It hands every request to a background subagent and
  replies immediately, so the user is never kept waiting.
- Wants this available in the `~/.claude` profile (the one this
  conversation runs in) too, but as an explicit, reversible toggle rather
  than a silent one-time edit — flipping it changes every *future*
  session's behavior for this profile (no file reads, no grepping, no
  pushing back on a subagent's claims — just dispatch-and-relay), so it
  needs to be visible and undoable, not baked in quietly.
- Wants it shared with the team via `ccxp-skills` ("share with people on
  how they handle daily activities with CC"), not kept as a personal-only
  `~/.claude/skills/` file.
- Framing: this should read as XP pairing (ccxp's own namesake spirit),
  not blind batch automation — the human stays the navigator (steering,
  prioritizing, consent-before-dispatch), subagents are the drivers. One
  navigator + several concurrent driver-agents, not literal 1:1 pairing —
  the SKILL.md should say so plainly rather than overclaim the analogy.

## Design (negotiated via `superpowers:brainstorming`, bounded path — approved)

- **Location**: `ccxp-skills/agent-pairing/SKILL.md`.
- **Bundled asset**: `agent-pairing/assets/dispatcher.md` — a copy of the
  already-working `~/.claude-personal/agents/dispatcher.md` content, so
  `on` doesn't depend on that profile existing on whoever adopts this.
- **`on`** (idempotent): copy the bundled `dispatcher.md` to
  `~/.claude/agents/dispatcher.md` if not already present, then a
  key-level `jq` edit of `~/.claude/settings.json` setting
  `"agent": "dispatcher"` — never a text-replace, since that file already
  carries hooks/permissions/plugin config that must survive untouched.
  Report plainly that this takes effect on the *next* session, not the
  current one.
- **`off`** (idempotent): same `jq`-based edit, removes the `"agent"`
  key. Leaves the installed `dispatcher.md` file in place — this toggles
  the *default*, not an uninstall (`claude --agent dispatcher` still
  works explicitly afterward).
- **`status`**: reads `.agent` from `settings.json` to report on/off,
  then calls `ListAgents` — already scoped to the invoking session's own
  spawned subagents by the tool itself, so no extra filtering logic is
  needed to satisfy "only list what this dispatcher started."
- **Testing**: a BATS suite over the `jq` edit logic (on/off, idempotent
  re-entry, preserves unrelated keys) — same pattern as
  `repo-conventions`'s `tests/mode.bats`.
- Done = `/agent-pairing on`, `off`, and `status` all work against a
  real `~/.claude/settings.json`-shaped fixture, BATS green, and the
  SKILL.md explains the XP-pairing framing for a teammate reading it
  cold.
