---
name: agent-pairing
description: Use when the user explicitly asks to toggle the ccxp-agent main-session agent on/off for this Claude Code profile, check its status, or refresh (update) its installed agent definition
argument-hint: on | off | status | update
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
`update` refreshes the installed agent definition (and the settings it
manages) to the version bundled with this plugin, without touching
on/off state.

## Argument

- `on` — turn ccxp-agent mode on for this profile. Idempotent.
- `off` — turn it back off. Idempotent. Doesn't uninstall the agent
  definition, just stops it being the default.
- `status` (default) — report on/off, plus the current session's running
  subagents, plus whether the installed agent definition is current.
- `update [--yes]` — refresh the installed `agents/ccxp-agent.md` from
  the bundled asset and re-assert the managed settings. Dry run (diff
  only) unless `--yes` is passed. Never changes on/off state.

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
- `agent definition: up to date | OUTDATED -- run update | not
  installed` — a read-only comparison with the bundled asset

Then call the `ListAgents` tool and show its output alongside — that
tool is already scoped to the invoking session's own spawned subagents,
so no extra filtering is needed to answer "what are my drivers doing
right now."

### `update`

Run the dry run first; never start with `--yes`.

1. Dry run (writes nothing):

   ```bash
   bash <skills-root>/agent-pairing/scripts/agent-pairing.sh update
   ```

2. Show the user the diff it printed (`-` lines = what the installed file
   has now, including any hand edits; `+` lines = what the bundled
   version adds) and the re-run command. If it says `up to date`, report
   that and stop.
3. Only after the user agrees to the replacement, run the command the
   dry run printed (same script with `--yes`, plus `--claude-dir` when
   one was used):

   ```bash
   bash <skills-root>/agent-pairing/scripts/agent-pairing.sh update --yes
   ```

What `update` manages, and what it leaves alone:

- **`agents/ccxp-agent.md`** — compared with `assets/ccxp-agent.md`.
  Identical: reported, nothing written. Different: diff printed; with
  `--yes` the old file is first copied to
  `ccxp-agent.md.bak-<YYYYMMDD-HHMMSS>` beside it, then replaced
  atomically. A missing file is not installed (that is `on`).
- **`settings.json`** — the only agent-pairing-owned key is `"agent"`.
  - Re-asserted as `"ccxp-agent"` (key-level `jq`, backed up to
    `settings.json.bak-<YYYYMMDD-HHMMSS>`, only if it would change)
    **only when it is already `"ccxp-agent"`**.
  - An OFF profile, a different custom agent, or a stale `"dispatcher"`
    is left exactly as it is: `update` never turns the mode on or off.
  - In practice this step is a no-op safety net; the point of `update`
    is the agent definition.
- **Not managed, by design** — agent-pairing owns no hooks, permissions
  or `env` in the profile.
  - The plugin's own `hooks/hooks.json` belongs to the plugin and is
    refreshed by the plugin update.
  - The detached-job scripts (`scripts/job-*.sh`, `bg-jobs.md`) are read
    from the plugin install, not copied into the profile; their per-job
    `settings.json` (allow/deny, `env`, Stop hook) is generated by
    `job-launch.sh` at each launch under `$TMPDIR`.
  - So `update` only **reports** what it cannot manage: missing bundled
    helper scripts, no ccxp-skills plugin install under the profile,
    `claude` not on `PATH`, a leftover `agents/dispatcher.md`, a stale
    `"dispatcher"` default. Relay those notes; do not fix them by
    hand-editing settings.

Like `on`/`off`, **this takes effect at the next session start.** The
running session keeps the definition it booted with.

## Important Notes

- `--claude-dir DIR` overrides the profile directory for testing or a
  non-default profile (e.g. `~/.claude-personal`) — omit it for the
  normal case.
- `jq` is required; the script hard-fails with a clear message if it's
  missing rather than falling back to a fragile text edit.
- Overwrite rules: `on` never overwrites an existing
  `agents/ccxp-agent.md` (hand edits are safe). Only `update --yes`
  replaces it, and always after writing a timestamped `.bak-` copy;
  restore by copying the backup over it. `update` without `--yes`
  writes nothing. Backups are not pruned automatically.
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
  section): run `/agent-pairing update` — no hand-copying.

## Cross-references

- `assets/ccxp-agent.md` — the bundled agent definition this installs
- `bg-jobs.md` — runbook for detached `claude --bg` jobs (`scripts/job-launch.sh`, `job-status.sh`, `job-resume.sh`); `/agent-pairing update` refreshes an older installed `ccxp-agent.md` to pick up its **Detached jobs** section
- `superpowers:dispatching-parallel-agents` — the general pattern this
  profile-level toggle is built on
