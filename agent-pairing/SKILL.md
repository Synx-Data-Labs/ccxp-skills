---
name: agent-pairing
description: Use when the user explicitly asks to toggle the ccxp-agent main-session agent on/off for this Claude Code profile or check its status
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
- On session start the persona reconciles the HUD job ledger against
  the live agent list and resumes jobs a restart interrupted (same job
  number, saved prompt; release/publish jobs and jobs without a saved
  prompt are listed under Next instead). See `hud/scripts/ledger.md`.
- When active, the persona checks for failed nightly, release or
  default-branch CI runs at each turn and autopilot wake and starts an
  investigation job (`/rca`, `/new-task`, `/top`, `/drive`) per new
  failure, at most 3 per turn. It cannot see failures while idle.
- One navigator, potentially several concurrent driver-agents at once —
  not literal 1:1 pairing, but the same spirit: tight visibility into
  what each driver is doing, consent before anything hard to undo,
  never blind batch automation running unsupervised.

`on`/`off` toggle whether a Claude Code profile (`~/.claude` by default)
boots into this mode by default. `status` shows whether it's on right
now, plus what your own session's driver-agents are currently doing.
The installed agent definition refreshes itself after a plugin update (see `persona-refresh.md`); there is no
separate update command.

## Argument

- `on` — turn ccxp-agent mode on for this profile. Idempotent.
- `off` — turn it back off. Idempotent. Doesn't uninstall the agent
  definition, just stops it being the default.
- `status` (default) — report on/off, plus the current session's running
  subagents, plus whether the installed agent definition is current.

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

Reports:

- on/off (naming the other agent if a non-ccxp-agent one is set)
- `agent definition: up to date | OUTDATED -- refreshes automatically | not
  installed` — a read-only comparison with the bundled asset

Then call the `ListAgents` tool and show its output alongside — that
tool is already scoped to the invoking session's own spawned subagents,
so no extra filtering is needed to answer "what are my drivers doing
right now."

## Important Notes

- `--claude-dir DIR` overrides the profile directory for testing or a
  non-default profile (e.g. `~/.claude-personal`) — omit it for the
  normal case.
- `jq` is required; the script hard-fails with a clear message if it's
  missing rather than falling back to a fragile text edit.
- Overwrite rules: `on` never overwrites an existing
  `agents/ccxp-agent.md`. Only the automatic refresh replaces it, and always after
  writing a timestamped `.bak-` copy; restore by copying the backup
  over it. Backups are not pruned automatically.
- Only run when the user explicitly asks — this
  changes a profile's default behavior for every future session, which
  is squarely the user's call to make explicitly, never a model
  judgment call mid-task.
- **Upgrading from the old "dispatcher" name**: just re-run
  `/agent-pairing on`. It installs `agents/ccxp-agent.md` alongside any
  old `agents/dispatcher.md` (never touching that file) and flips
  `"agent"` forward to `"ccxp-agent"`, since `"dispatcher"` no longer
  matches the managed name. Remove the stale `dispatcher.md` by hand
  once the new one works.
- **Picking up a newer bundled definition** (e.g. the Detached jobs
  section): nothing to run; it refreshes automatically (`persona-refresh.md`).

## Cross-references

- `assets/ccxp-agent.md` — the bundled agent definition this installs
- `bg-jobs.md` — runbook for detached `claude --bg` jobs (`scripts/job-launch.sh`, `job-status.sh`, `job-resume.sh`)
- `scripts/trash.sh` — the delete-by-trash helper behind the ccxp-agent "Deleting things" rule (`/usr/bin/trash`, else `mv` into `~/.Trash/<stamp>-<label>/` with a `MANIFEST.tsv`); tests: `bats tests/trash.bats`
- `persona-refresh.md` — the persona refreshes itself after a `/plugin` update
- `terms.md` — the agent's acronym memory (`scripts/terms.sh`, `wtf.json` ("where to find"), the UserPromptSubmit `hooks/terms-hook.sh`)
- `decisions.md` — the agent's decisions log (`ledger.sh decision ...`, `ccxp-decisions.json`/`.md`)
- `superpowers:dispatching-parallel-agents` — the general pattern this
  profile-level toggle is built on
