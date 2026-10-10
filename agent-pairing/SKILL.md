---
name: agent-pairing
description: Use when the user explicitly asks to toggle the dispatcher main-session agent on/off for this Claude Code profile, or check its status
disable-model-invocation: true
argument-hint: on | off | status
---

# Agent Pairing

Pairing, XP-style, but with subagents as the drivers:

- You stay the navigator — steering, prioritizing, deciding what's
  worth doing, authorizing anything risky.
- The "dispatcher" main-session agent persona hands every request
  straight to a background subagent and replies immediately, so you're
  never kept waiting on one thread to work on the next.
- One navigator, potentially several concurrent driver-agents at once —
  not literal 1:1 pairing, but the same spirit: tight visibility into
  what each driver is doing, consent before anything hard to undo,
  never blind batch automation running unsupervised.

`on`/`off` toggle whether a Claude Code profile (`~/.claude` by default)
boots into this mode by default. `status` shows whether it's on right
now, plus what your own session's driver-agents are currently doing.

## Argument

- `on` — turn dispatcher mode on for this profile. Idempotent.
- `off` — turn it back off. Idempotent. Doesn't uninstall the agent
  definition, just stops it being the default.
- `status` (default) — report on/off, plus the current session's running
  subagents.

## Workflow

### `on`

```bash
bash agent-pairing/scripts/agent-pairing.sh on
```

- Installs `~/.claude/agents/dispatcher.md` (from this skill's bundled
  `assets/dispatcher.md`) if nothing is there yet — never overwrites an
  existing one, even a stale one, since it might be hand-edited; a
  mismatch is reported, not silently replaced.
- Flips `~/.claude/settings.json`'s `"agent"` key to `"dispatcher"` via
  a key-level `jq` edit, never a text replace — that file carries
  hooks, permissions, and plugin config that must survive untouched.

**This takes effect at the next session start, not the current one.**
Say so plainly when reporting the result — don't imply the invoking
session itself just became a dispatcher.

### `off`

```bash
bash agent-pairing/scripts/agent-pairing.sh off
```

Removes the `"agent"` key only when it's currently `"dispatcher"` — if
the user has since set a *different* custom agent as their default, this
leaves it alone rather than clobbering it. `agents/dispatcher.md` stays
installed either way, so `claude --agent dispatcher` keeps working
on-demand even with the default off.

### `status`

```bash
bash agent-pairing/scripts/agent-pairing.sh status
```

Reports on/off (and names the other agent if a non-dispatcher one is
set). Then call the `ListAgents` tool and show its output alongside —
that tool is already scoped to the invoking session's own spawned
subagents, so no extra filtering is needed to answer "what are my
drivers doing right now."

## Important Notes

- `--claude-dir DIR` overrides the profile directory for testing or a
  non-default profile (e.g. `~/.claude-personal`) — omit it for the
  normal case.
- `jq` is required; the script hard-fails with a clear message if it's
  missing rather than falling back to a fragile text edit.
- Never invoked autonomously (`disable-model-invocation: true`) — this
  changes a profile's default behavior for every future session, which
  is squarely the user's call to make explicitly, never a model
  judgment call mid-task.

## Cross-references

- `assets/dispatcher.md` — the bundled agent definition this installs
- `superpowers:dispatching-parallel-agents` — the general pattern this
  profile-level toggle is built on
