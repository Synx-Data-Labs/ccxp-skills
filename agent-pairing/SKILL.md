---
name: agent-pairing
description: Use when the user explicitly asks to toggle the ccxp-agent main-session agent on/off for this Claude Code profile, or check its status
disable-model-invocation: true
argument-hint: on | off | status
---

# Agent Pairing

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Pairing, XP-style, but with subagents as the drivers:

- You stay the navigator — steering, prioritizing, deciding what's
  worth doing, authorizing anything risky.
- The "ccxp-agent" main-session agent persona (a dispatcher) hands
  requests that need real work straight to a background subagent and
  replies immediately, so you're never kept waiting on one thread to
  work on the next.
- One navigator, potentially several concurrent driver-agents at once —
  not literal 1:1 pairing, but the same spirit: tight visibility into
  what each driver is doing, consent before anything hard to undo,
  never blind batch automation running unsupervised.

`on`/`off` toggle whether a Claude Code profile (`~/.claude` by default)
boots into this mode by default. `status` shows whether it's on right
now, plus what your own session's driver-agents are currently doing.

## Argument

- `on` — turn ccxp-agent mode on for this profile. Idempotent.
- `off` — turn it back off. Idempotent. Doesn't uninstall the agent
  definition, just stops it being the default.
- `status` (default) — report on/off, plus the current session's running
  subagents.

## Workflow

### `on`

```bash
bash <skills-root>/agent-pairing/scripts/agent-pairing.sh on
```

- Installs `~/.claude/agents/ccxp-agent.md` (from this skill's bundled
  `assets/ccxp-agent.md`) if nothing is there yet — never overwrites an
  existing one, even a stale one, since it might be hand-edited; a
  mismatch is reported, not silently replaced.
- Flips `~/.claude/settings.json`'s `"agent"` key to `"ccxp-agent"` via
  a key-level `jq` edit, never a text replace — that file carries
  hooks, permissions, and plugin config that must survive untouched.

**This takes effect at the next session start, not the current one.**
Say so plainly when reporting the result — don't imply the invoking
session itself just became ccxp-agent.

### `off`

```bash
bash <skills-root>/agent-pairing/scripts/agent-pairing.sh off
```

Removes the `"agent"` key only when it's currently `"ccxp-agent"` — if
the user has since set a *different* custom agent as their default, this
leaves it alone rather than clobbering it. `agents/ccxp-agent.md` stays
installed either way, so `claude --agent ccxp-agent` keeps working
on-demand even with the default off.

### `status`

```bash
bash <skills-root>/agent-pairing/scripts/agent-pairing.sh status
```

Reports on/off (and names the other agent if a non-ccxp-agent one is
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
- **Upgrading from the old "dispatcher" name**: installations from
  before this rename have `~/.claude/agents/dispatcher.md` and possibly
  `settings.json`'s `"agent": "dispatcher"`. Just re-run `/agent-pairing
  on`: it installs `agents/ccxp-agent.md` alongside the old file (never
  touching it) and flips `"agent"` from `"dispatcher"` to `"ccxp-agent"`,
  since `"dispatcher"` no longer matches the name this script manages.
  Remove the now-unused `agents/dispatcher.md` by hand once you've
  confirmed the new one works — the script never deletes it for you.

## Cross-references

- `assets/ccxp-agent.md` — the bundled agent definition this installs
- `superpowers:dispatching-parallel-agents` — the general pattern this
  profile-level toggle is built on
