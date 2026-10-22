---
status: Open
estimation: 1
source: Conversation 2026-10-22 (user ask: a supported mod instead of tweakcc to make the user message stand out and render a richer autopilot/context/branch/task status line)
related: T20261002-303999
description: Build `ccxp-hud`, a Claude Code mod (supported plugin API, not a tweakcc patch) that highlights the user's prompt rows and draws a richer status band, reusing statusline-setup's data helpers
---

# T20261022-345549: ccxp-hud mod: make user messages stand out and render a richer status line (no tweakcc)

## Problem

- **Type**: feature
- **Ask**: make the user's own message visually distinct from the agent's reply, and show richer live info (autopilot state, context, branch, task, running jobs). Use a supported Claude Code **mod**, not `tweakcc`.
- **What exists today**:
  - `statusline-setup/scripts/statusline-command.sh` is wired through `settings.json` `statusLine.command`. It prints one plain line: `ap:[r] 2/6hr 0/3 | ctx: 64% left | branch: … | TASK: T…: title | last: …`.
  - Data comes from: stdin JSON (`cwd`, `session_id`, `context_window.remaining_percentage`), `dev/.autopilot-state.json`, the `claimed_by:` frontmatter matched against `_session/claimant-id.sh`, `git symbolic-ref`, and `last-input-hook.sh`'s cache.
  - Nothing styles the user's prompt row. The default is a plain gray block.
- **Done looks like**:
  - Installing or enabling the mod makes the user's prompts visibly distinct in the terminal.
  - A status band shows the fields below, color-coded, with no new data source that leaks secrets or uses the network.
  - With mods off, the existing statusline still works.
  - BATS and unit tests cover the data layer and the render functions with fixtures.
- **Do not**: patch the CLI bundle, depend on tweakcc, or remove the existing `statusLine.command` path.

## Research findings (verified 2026-10-22 against Claude Code 2.1.306's own types file and code.claude.com/docs)

### Why a mod and not tweakcc

- **How tweakcc works**: it patches Claude Code's minified `cli.js`. For native installs it unpacks the Bun binary, patches it and repacks it (github.com/Piebald-AI/tweakcc README).
- **It is fragile**:
  - Only one CLI version is verified (2.1.162 at the time of reading).
  - Every update overwrites the patch, so `npx tweakcc --apply` has to run again after each update.
  - Its "keep patched binary" option stops Claude Code from repairing its own binary.
- **Mods are the supported route**: a plugin whose `hooks/hooks.json` lists a JS/TS module under `"modules"`.
  - Mods are on by default from v2.1.287 in the terminal and v2.1.286 in Desktop.
  - They install like any plugin, from a marketplace.
  - Docs: `code.claude.com/docs/en/plugins/mods/{overview,interface,reference}`.
- **Caveat**: the types header says "EARLY ACCESS: this surface may change between releases without notice". Pin the behaviour in tests, and fall back gracefully (see Degradation).

### (a) Styling the user's message: what is possible

- **Supported, through a mod**: `ui.render` on the `UserMessage` render site, drawn in the terminal, Desktop and VS Code.
  - `e.props` holds `text`, `origin` (`kind`: `composer` | `task-notification` | `peer` | `channel` | `coordinator` | …), `isExpanded` and `onScreen`.
  - A hook can:
    - pass `next(e)` to leave the row alone
    - pass `next({...e, props})` to change details
    - return its own tree
    - wrap the engine's drawing: `const theirs = await next(e)` placed inside a `Box`
  - A rewrite changes only the drawing. The stored message and what the model reads stay as they were (types: `UserMessage` doc comment).
  - `Box` takes `borderStyle` (`round`, `bold`, `double`, `quote` = a `▎` bar down the left, …), `borderColor` and `backgroundColor`. `Text` takes `color`, `backgroundColor`, `bold`/`weight` and `inverse`. A color is a theme key (`suggestion`, `claude`, `success`, …) or a literal color.
  - `AssistantMessage` is a render site too (`text`, `isFirstOfReply`, `isSummary`), so the reply side can be toned down instead of, or as well as, highlighting the prompt.
- **Supported, with no code: a theme**. The custom theme tokens include:
  - `userMessageBackground`, painted in both the default and fullscreen renderers
  - `userMessageBackgroundHover`, fullscreen only
  - `briefLabelYou` / `briefLabelClaude`
  - A plugin can ship `themes/<slug>.json`, which appears in `/theme` (manifest key `experimental.themes`). The user still has to pick the theme. It recolours only; it cannot add a label or a border.
- **Not suitable**:
  - Output styles only change the model's instructions, not the rendering.
  - A `UserPromptSubmit` `additionalContext` only adds model context.
  - A `prompt.submit` rewrite changes what the model reads, which is wrong for a purely visual ask.
- **Not possible**: restyling the permission prompt (not a render site).
- **UNVERIFIED until tried live**:
  - Whether a wrapped `next(e)` ref inside a bordered `Box` keeps mouse selection, copy, hover and the ctrl+o expanded view intact at the `UserMessage` site. The docs show the wrap pattern on `Spinner`.
  - How a background colour interacts with the theme's own `userMessageBackground`.

### (b) The status line: what is possible

- **The settings `statusLine.command` row is not a render site**, so no mod can restyle it.
  - It already supports ANSI colours, several lines, `padding` and `refreshInterval` (seconds).
  - Updates are debounced at 300 ms, and a run still in flight is cancelled when a newer update starts.
  - Its stdin carries more than we use today:
    - `workspace.git_worktree` and `workspace.repo.{owner,name}`
    - `worktree.*`
    - `context_window.{used,remaining}_percentage`, which can be null early in a session
    - `rate_limits.{five_hour,seven_day}.used_percentage`
    - `cost`
    - `model.display_name`
  - Only one `statusLine.command` is active per config dir, and a plugin cannot set it (the plugin `settings.json` accepts only `agent` and `subagentStatusLine`).
- **What a mod can draw instead**:
  - `$.ui.status(text)`: one plain-text line per plugin under the prompt, up to 2,000 characters. It holds no styling. UNVERIFIED whether it sits above or below the settings status line row.
  - The `AbovePrompt` band: a tree with colours and buttons, drawn in the terminal and Desktop only, not VS Code. Read `e.props.bodyColumns` and `maxRows`, and return `next(e)` when there is nothing to show.
  - A `Pane` (sidebar), opened by a command. It is placed unasked only from 144 columns.
  - `Spinner` `suffix`: extra text beside the working spinner.
- **Data a mod can read**:
  - `$.session.usage()` → `context.{tokens,window,percent}` (the same figures as the status line's `context_window`), `rateLimits[]` and `cost.usd`.
  - The `session.measure` event fires after each turn, so it pushes updates without polling.
  - `$.session.cwd()`, `root()`, `id()` and `repo()` (`root`, `remote`; no branch field), `$.agent.list()` (subagents and teammates with a `status` of `pending`, `running`, `waiting`, `idle`, `completed`, `failed` or `killed`; this gives the **job counts**).
  - `$.fs.read` (4 MiB cap), `$.process.run(argv, {cwd, stdin, timeoutMs})` with no shell and git repo hooks off, `$.clock.every`, `$.store` and `$.state`.
- **Not readable from a mod without help**: the claimant id. It is salted with a secret kept in `~/.claude/state`, and only `_session/claimant-id.sh` may compute it (see that file's header). Shell out to the bash helper; never reimplement it or read the secret into the mod.

### (c) The optional band or pane

- **Band (`AbovePrompt`)**: right for an always-visible HUD, with buttons such as `[ autopilot status ]` that run `$.prompt.fill` or `$.command.run`.
- **Pane**: right for a detail view (`/hud` opens it), for example the full autopilot state, the job list and the last stuck reason.

## Design

### Package layout and install

Recommended (open decision 1): a **separate plugin in the same marketplace**, so installing `ccxp-skills` does not force a mod on every user.

```text
mods/ccxp-hud/
├── .claude-plugin/plugin.json   # name ccxp-hud, version, "types": "./types/index.d.ts", userConfig
├── hooks/hooks.json             # { "modules": ["./register.tsx"] }
├── hooks/register.tsx           # wiring only: events → state → render
├── hooks/model.ts               # pure: HudSnapshot from inputs (no $)
├── hooks/render.tsx             # pure-ish: tree from snapshot + config + surface
├── themes/ccxp-contrast.json    # optional zero-code layer: userMessageBackground, briefLabelYou
├── types/index.d.ts             # PluginState contract for $.state values
├── hooks/*.test.ts(x)           # `claude plugin test` suites
└── README.md                    # install line
```

- **Marketplace**: add `{ "name": "ccxp-hud", "source": "./mods/ccxp-hud" }` to `.claude-plugin/marketplace.json`. Install with `/plugin install ccxp-hud@ccxp-skills`.
- **Data helper**: add a `--json` mode to `statusline-setup/scripts/statusline-command.sh`, or a sibling `hud-data.sh`.
  - It emits `{task_id, task_title, branch, autopilot:{status,prefix,elapsed_hr,requested_hr,stuck,cycle,last_outcome,last_task}, last_input}` from the same `sl-*` functions. That keeps one source of truth, and the claimant secret stays in bash.
  - The mod calls `$.process.run(["bash", <helper>, "--json"], {stdin: <synthetic statusLine JSON>, timeoutMs: 2000})`.
  - **Path problem** (UNVERIFIED): does a marketplace cache of `./mods/ccxp-hud` include sibling repo directories?
    - If not, either vendor the helper into the mod with a BATS drift test that diffs it against the source (same `cmp -s` copy-vs-source pattern as `tests/agent_pairing.bats`), or
    - take open decision 1's alternative: put the module in the root plugin's `hooks/hooks.json` (`"modules"` beside the existing `"hooks"`), so `$.plugin.root` is the repo root.
- **Coexistence with statusline-setup**: keep `statusLine.command` as the fallback that always works.
  - When the mod is active it writes a heartbeat at `~/.claude/state/hud-active/<session_id>` (the same state root as `last-input`; honour `CLAUDE_CONFIG_DIR` per T20261002-303999).
  - `statusline-command.sh` can then shrink to a minimal `ctx | branch` line while the heartbeat is fresh (under 2 minutes old), so the info is not shown twice. This is Phase 3.

### Feature 1: user-message styling

- **Hook**: `on('ui.render', { component: 'UserMessage', props: { origin: { kind: 'composer' } } }, …)`.
  - Rows from task notifications or peers keep the engine's drawing, or get a separate dimmer style (`config.styleNotifications`).
  - The first version wraps the engine drawing: `<Box borderStyle={cfg.border} borderColor={cfg.color} paddingX={1}>{await next(e)}</Box>`. This keeps the engine's text, wrapping and expansion.
  - If the live test shows the wrap breaks selection or copy, fall back to `next({...e, props:{...e.props, text: cfg.prefix + e.props.text}})`, a label only.
- **Surfaces**: `e.surface` is checked. `vscode` and `desktop` get their own frames, so apply only a colour there, or nothing, if the frame looks doubled.
- **Optional**: dim the `AssistantMessage` bullet, kept off by default.

```text
Before (default)                         After (ccxp-hud, border "quote", color "suggestion")

> fix the nightly orchestrator           ▎ YOU  fix the nightly orchestrator
                                         ▎      so Cloud runs after a SynxDB4 failure
● I'll look at the workflow first…
                                         ● I'll look at the workflow first…
  Read(.github/workflows/nightly.yml)      Read(.github/workflows/nightly.yml)
```

### Feature 2: status line v2 (the band)

- **Snapshot fields**:
  - autopilot `[r]/[b]/[s]`, elapsed/requested hours and stuck/cycle, plus `paused` (the state file has `paused`; the current script drops it)
  - context % left, with colour thresholds (green above 40, yellow 15–40, red below 15)
  - branch, with the worktree name when `workspace.git_worktree` is set
  - task id and title, truncated to `bodyColumns`
  - jobs `running/waiting/failed` from `$.agent.list()`
  - optional: 5-hour rate limit % and session cost
- **Refresh**:
  - `session.measure` covers context and rate limits.
  - `turn.complete` and `$.clock.every(cfg.pollSeconds*1000)` (default 15) re-run the data helper for autopilot, task and branch, which change outside turns.
  - Values live in `$.state` atoms, so a write redraws the band. There are no manual invalidates.
- **Render**: one row, falling to two rows when `bodyColumns` is under ~100. When the band would be empty, return `next(e)`. When `e.props.hasSurvey` is set, return `next(e)` too.

```text
┌ band above the prompt (terminal, 140 cols) ─────────────────────────────────────────────────────────┐
 AP ● run 2/6h  stuck 0/3 │ ctx 64% ▓▓▓▓▓▓░░░░ │  t20261021-354035-decouple │ T20261021-354035 Decouple… │ jobs 2▶ 1⏸ 0✗
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
 > _
 ctx: 64% left | branch: t20261021-354035-decouple            ← settings statusLine, minimal while hud is active

 narrow (<100 cols):
 AP ◐ backoff 3/6h stuck 2/9 │ ctx 12% ▓░░░
  main │ no claimed task │ jobs 0
```

- **Colours**: `[r]` success, `[b]` warning, `[s]` inactive. Context follows the thresholds above. Theme keys keep it readable under light and dark themes.

### Feature 3 (optional): `/hud` pane

- `$.command.register({ name: 'hud' })` opens a `Pane` holding:
  - the full autopilot state (`last_task`, `last_stuck_reason`, `stop_reason`, `end_time`)
  - the job list with their statuses
  - the context breakdown (`$.session.usage({ breakdown: 'summary' })`)
- Opened by the user only; it never opens itself.

### Config

`userConfig` in `plugin.json` gives rows in `/config` and `pluginConfigs` in settings. The defaults:

| Key | Default | Notes |
|---|---|---|
| `userMessage` | `on` | `on` / `off` |
| `userBorder` | `quote` | one of the terminal's border styles; anything else draws no border |
| `userColor` | `suggestion` | a theme key or a hex colour |
| `band` | `on` | `on` / `off` |
| `fields` | `ap,ctx,branch,task,jobs` | comma list, in order |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `40` / `15` | thresholds for the context colour |

### Degradation

- **Mods off** (`disableAllHooks`, `--safe-mode`, an org's `allowManagedModsOnly`, a CLI older than 2.1.287): nothing in the mod runs. The settings `statusLine.command` still prints the classic line, because without a fresh heartbeat the script prints the full line.
- **API drift**:
  - Every `ui.render` hook gets `.catch(($, e, next) => next(e))`, so a throw draws the engine's own row.
  - A tree that does not validate is drawn by the engine anyway, with a debug-log line.
  - Wrap field reads (`e.props.origin?.kind`) defensively.
- **Helper failure or timeout**: show the last good snapshot, dimmed with a `stale` tag; never block a turn. The helper must still never exit non-zero.
- **VS Code**: there is no band, so mirror a compact line through `$.ui.status`.

### Security

- No `$.http`, no `$.model` and no `$.mcp` calls.
  - CI asserts this with `claude plugin validate --json mods/ccxp-hud`: the `calls` list must contain no `http.fetch`, `model.*` or `mcp.*`.
  - Gate this on the CLI being installable in CI (open decision 4).
- The mod never reads `~/.claude/state/<claimant secret>` or `.env`. The claimant id comes only from the bash helper's output, and only the task id and title are shown, never the `claimed_by` value.
- `last_input` is already sanitised and truncated by `last-input-hook.sh`. Keep it behind a `fields` opt-in, since a prompt can contain a pasted secret.
- `$.process.run` takes only a fixed argv (bash plus the helper path inside `$.plugin.root`). No values typed by the user go into argv.

### Test plan

- **BATS** (`tests/statusline_setup.bats` plus a new `tests/hud_data.bats`):
  - `--json` output for fixture repos covering autopilot running, backoff, stopped, paused, missing and malformed
  - claimed and unclaimed tasks, a detached HEAD, a worktree, and null `context_window`
  - the heartbeat-driven minimal mode
- **Mod unit tests** (`claude plugin test mods/ccxp-hud`):
  - pure `model.ts`/`render.tsx` with fixture snapshots
  - `UserMessage` render on `['terminal','desktop']`: a composer row is wrapped and a task-notification row is passed through
  - the band, at 140 and 80 `bodyColumns`, and empty when there is no data
  - `session.measure` updates the context atom, and a mocked `process.run` failure produces the stale tag
- **CI**: add the mod tests to `tests.yml` if the `claude` CLI can be installed there. Otherwise run them locally under `/statusline-setup test` and say so in the PR.
- **Manual smoke** (a human, live UI; this cannot run in CI):
  - Run `claude --plugin-dir mods/ccxp-hud`.
  - Check the user row style, selection and copy, ctrl+o, the band under `/autopilot`, and the narrow terminal.

### Phased plan

1. **MVP (estimate 2)**:
   - `mods/ccxp-hud` with Feature 1 only, plus `themes/ccxp-contrast.json`, the marketplace entry and tests.
   - It proves the install path and the UNVERIFIED wrap behaviour.
2. **Statusline v2 (estimate 3)**:
   - The helper `--json`, the band, `$.state` atoms, `session.measure` and the poll.
   - The VS Code `$.ui.status` mirror, and the fixture tests.
3. **Coexistence and polish (estimate 2)**:
   - The heartbeat-driven minimal settings statusline, the `/hud` pane, and README and `statusline-setup/SKILL.md` updates.

### Risks

- The early-access mod API changes between releases. Mitigations: `.catch` fallbacks, `claude plugin validate` in CI, and pinning a minimum CLI version in the README.
- The marketplace cache may not include sibling directories (helper path). Mitigation: decision 1, vendoring with a drift test.
- A double frame or colour clash with the theme's `userMessageBackground`. Mitigation: config switches, and default to the `quote` border only.
- The band competes with other mods' bands. Return `next(e)` inside your `Box` to keep theirs (docs: band section).

## Open decisions (for the user)

1. **Packaging**: a separate `ccxp-hud` plugin in the marketplace (recommended, opt-in), or a module in the root `ccxp-skills` plugin (simplest helper path, but on for every ccxp-skills user).
2. **Band and statusline**: shrink the settings statusline while the band is active (recommended), or show both in full.
3. **Defaults**: the default user-row style (`quote` bar plus a `YOU` label, a round box, or a colour only), and whether `last_input` shows in the band.
4. **CI**: install the `claude` CLI in GitHub Actions to run `claude plugin validate`/`test`, or keep the mod tests local-only.
