---
status: Done
estimation: 1
source: Conversation 2026-10-22 (user ask: a supported mod instead of tweakcc to make the user message stand out and render a richer autopilot/context/branch/task status line)
related: T20261002-303999
description: Build `ccxp-hud`, a Claude Code mod (supported plugin API, not a tweakcc patch) shipped inside the ccxp-skills plugin, on by default with its own opt-out, that highlights the user's prompt rows and draws a richer status band, reusing statusline-setup's data helpers
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261022-345549: ccxp-hud mod: make user messages stand out and render a richer status line (no tweakcc)

## TLDR

- Ship `ccxp-hud` as a mod **inside** `ccxp-skills` (`hooks/hooks.json` gains `"modules"`), loaded and **on by default**, with its own opt-out (`~/.claude/ccxp-hud.json`, `/hud off`).
- It styles the user's own prompt rows (colored left bar) and draws a status band (autopilot, context, branch, task, jobs) fed by a new `hud-data.sh --json` bash helper that keeps the claimant secret out of the mod.
- Phase 0 verified live: `hooks` and `modules` coexist in one `hooks.json`, `$.fs.write` can toggle the config, and the opt-out and global kill switches work.
- Every hook falls back to Claude Code's own drawing; the classic `statusLine.command` stays and shrinks to `ctx | branch` while the band is live.
- Unit and BATS tests cover the data layer, render functions and every no-op path; live-UI checks (selection, copy, ctrl+o, band look) remain a manual test-plan item.

## Problem

- **Type**: feature
- **Ask**: make the user's own message visually distinct from the agent's reply, and show richer live info (autopilot state, context, branch, task, running jobs). Use a supported Claude Code **mod**, not `tweakcc`.
- **What exists today**:
  - `statusline-setup/scripts/statusline-command.sh` is wired through `settings.json` `statusLine.command`. It prints one plain line: `ap:[r] 2/6hr 0/3 | ctx: 64% left | branch: … | TASK: T…: title | last: …`.
  - Data comes from: stdin JSON (`cwd`, `session_id`, `context_window.remaining_percentage`), `dev/.autopilot-state.json`, the `claimed_by:` frontmatter matched against `_session/claimant-id.sh`, `git symbolic-ref`, and `last-input-hook.sh`'s cache.
  - Nothing styles the user's prompt row. The default is a plain gray block.
- **Done looks like**:
  - After updating `ccxp-skills`, the mod is on by default and the user's prompts are visibly distinct in the terminal.
  - It can be switched off through its own config file (and `/hud off` if the API allows) without uninstalling `ccxp-skills`.
  - A status band shows the fields below, color-coded, with no new data source that leaks secrets or uses the network.
  - With the mod off (its own switch, or mods disabled globally), the existing statusline and Claude Code's own rendering work unchanged.
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
  - They install like any plugin; here the module ships inside `ccxp-skills` itself (decision 1).
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

## Solution

### Package layout and install

**Decided (decision 1)**: the module lives **inside the root `ccxp-skills` plugin**. There is no second plugin and no second install. Users who already have `ccxp-skills` get it on update, enabled by default.

```text
hooks/hooks.json              # existing "hooks" + new "modules": ["./hud/register.tsx"]   (coexistence UNVERIFIED)
hud/
├── register.tsx              # wiring only: config → events → state → render
├── config.ts                 # pure: defaults, merge, enabled gate
├── model.ts                  # pure: HudSnapshot from inputs (no $)
├── render.tsx                # pure-ish: tree from snapshot + config + surface
├── *.test.ts(x)              # `claude plugin test` suites
└── README.md                 # what it does, how to turn it off
themes/ccxp-contrast.json     # optional zero-code layer: userMessageBackground, briefLabelYou
types/index.d.ts              # PluginState contract; plugin.json gains "types"
```

- **Manifest**: `.claude-plugin/plugin.json` gains `"types": "./types/index.d.ts"` and, if the themes ship, `experimental.themes`. This is a MINOR bump (a new backward-compatible capability), per `dev/guidelines.md`.
- **Coexistence of `hooks` and `modules`** is UNVERIFIED (phase 0).
  - Fallback 1: a second hooks file for the module, if the manifest accepts a list.
  - Fallback 2: the separate plugin under "Alternatives considered".
- **Data helper**: add a `--json` mode to `statusline-setup/scripts/statusline-command.sh`, or a sibling `hud-data.sh`.
  - It emits `{task_id, task_title, branch, autopilot:{status,prefix,elapsed_hr,requested_hr,stuck,cycle,last_outcome,last_task}, last_input}` from the same `sl-*` functions. That keeps one source of truth, and the claimant secret stays in bash.
  - **Helper path**: with the module in the root plugin, `$.plugin.root` is the repo root, so the module reaches `statusline-setup/scripts/` directly. No vendoring and no drift test are needed.
  - The mod calls `$.process.run(["bash", <$.plugin.root>/statusline-setup/scripts/<helper>, "--json"], {stdin: <synthetic statusLine JSON>, timeoutMs: 2000})`. Check in phase 0 that the cached plugin copy contains that directory (it should, as the whole repo is the plugin).
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

### Alternatives considered

- **Separate `ccxp-hud` plugin in the same marketplace** (`mods/ccxp-hud`, `{ "name": "ccxp-hud", "source": "./mods/ccxp-hud" }`, install with `/plugin install ccxp-hud@ccxp-skills`).
  - Pro: opt-in by installing, and the mod API risk stays away from other users.
  - Con: the marketplace cache may not include sibling repo directories, so the helper would need vendoring plus a drift test (the `cmp -s` pattern from `tests/agent_pairing.bats`).
  - Rejected by the user (decision 1). It remains the fallback only if `hooks` and `modules` cannot coexist (phase 0).
- **A custom `statusLine.command` only**: cannot restyle the prompt row and is not a render site; rejected in the research findings.

### Config

The module is **loaded and enabled by default**. It has its own opt-out, separate from installing or disabling the whole `ccxp-skills` plugin.

- **Location**: a small JSON file at `~/.claude/ccxp-hud.json` (honour `CLAUDE_CONFIG_DIR`, per T20261002-303999), with an optional per-project override at `<project>/.claude/ccxp-hud.json`. The module reads them with `$.fs.read`.
- **Precedence**: project file, then user file, then the built-in defaults. A missing or malformed file means the defaults, so on.
- **Default**: `enabled: true`, with every feature on.
- **When off** (`enabled: false`): draws nothing, writes no heartbeat, and leaves Claude Code's own rendering and the existing `statusLine.command` alone.
- **Slash command**: `/hud on|off|status`, registered with `$.command.register`, if the mod API allows it. It writes `enabled` into the user file. UNVERIFIED: whether a plugin may write that file from the module (`$.fs` may be read-only), and whether toggling is live or needs a reload. If not writable, `/hud` only prints the file path and the line to edit.
- **Why a file, not `userConfig`**: the module must be switchable without a plugin reinstall, and the file is readable by the BATS and unit tests. `userConfig` in `plugin.json` (rows in `/config`) can mirror it later if it proves worthwhile.

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | master switch; `false` makes the whole module a no-op |
| `userMessage` | `true` | prompt-row styling on/off |
| `band` | `true` | status band on/off |
| `userBorder` | `quote` | one of the terminal's border styles; anything else draws no border |
| `userColor` | `suggestion` | a theme key or a hex colour |
| `fields` | `ap,ctx,branch,task,jobs` | comma list, in order |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `40` / `15` | thresholds for the context colour |

### Degradation

- **Opt-out and kill switches** (the module is on by default, so these must always work):
  - `enabled: false` in the config file: every hook returns `next(e)` and the heartbeat is not written, so the classic statusline prints in full.
  - Global: `disableAllHooks`, `--safe-mode`, an org's `allowManagedModsOnly`, or a CLI older than 2.1.287 stop the module entirely.
- **API drift**:
  - Every `ui.render` hook gets `.catch(($, e, next) => next(e))`, so a throw draws the engine's own row.
  - A tree that does not validate is drawn by the engine anyway, with a debug-log line.
  - Wrap field reads (`e.props.origin?.kind`) defensively.
  - A throw while loading the config or registering hooks leaves the module inert, never the session broken.
- **Helper failure or timeout**: show the last good snapshot, dimmed with a `stale` tag; never block a turn. The helper must still never exit non-zero.
- **VS Code**: there is no band, so mirror a compact line through `$.ui.status`.

### Security

- No `$.http`, no `$.model` and no `$.mcp` calls.
  - CI asserts this with `claude plugin validate --json .`: the `calls` list must contain no `http.fetch`, `model.*` or `mcp.*`.
  - Gate this on the CLI being installable in CI (open decision 4).
- The mod never reads `~/.claude/state/<claimant secret>` or `.env`. The claimant id comes only from the bash helper's output, and only the task id and title are shown, never the `claimed_by` value.
- `last_input` is already sanitised and truncated by `last-input-hook.sh`. Keep it behind a `fields` opt-in, since a prompt can contain a pasted secret.
- `$.process.run` takes only a fixed argv (bash plus the helper path inside `$.plugin.root`). No values typed by the user go into argv.

## Test plan

- [x] **BATS** (`tests/statusline_setup.bats` plus a new `tests/hud_data.bats`):
  - `--json` output for fixture repos covering autopilot running, backoff, stopped, paused, missing and malformed
  - claimed and unclaimed tasks, a detached HEAD, a worktree, and null `context_window`
  - the heartbeat-driven minimal mode
- [x] **Mod unit tests** (`claude plugin test .`, `hud/pure.test.ts`, `hud/hooks.test.tsx`):
  - pure `model.ts`/`render.tsx` with fixture snapshots
  - `UserMessage` render on `['terminal','desktop']`: a composer row is wrapped and a task-notification row is passed through
  - the band, at 140 and 80 `bodyColumns`, and empty when there is no data
  - `session.measure` updates the context atom, and a mocked `process.run` failure produces the stale tag
- [x] **No-op tests (required, from decision 1)**:
  - With `enabled: false`, every hook returns `next(e)`, no band or status text is drawn, and no heartbeat is written.
  - With each feature toggled off singly (`userMessage`, `band`), only that feature is inert.
  - With a missing, empty or malformed config file, the module uses the defaults (on) and does not throw.
  - When the helper fails or times out, the render falls back to the stale tag or to `next(e)`, and never throws.
- [x] **CI**: the `claude` CLI is not installed in GitHub Actions, so the mod tests run locally (`claude plugin test .`, `claude plugin validate .`); the BATS suite runs in CI as before (decision 4).
- [ ] **Manual smoke** (a human, live UI; this cannot run in CI; NOT ticked by the implementer):
  - Run `claude --plugin-dir .`.
  - Check the user row style, selection and copy, ctrl+o, the band under `/autopilot`, and the narrow terminal.

### Phased plan

0. **Verify first (estimate 1; before any feature code)**:
   - **Coexistence**: a single `hooks/hooks.json` holding both `"hooks"` (the existing `PreToolUse` skill-ask entry) and `"modules"` loads both. UNVERIFIED. Check with `claude --plugin-dir .` and `claude plugin validate`.
   - **Disable path**: with `enabled: false` in the config file, the module draws nothing, registers no heartbeat and leaves `statusLine.command` alone. Also check the global safe mode and `disableAllHooks`.
   - **Reload**: whether editing the config file or `/hud on|off` takes effect live or needs a reload. UNVERIFIED.
   - **Fallback if coexistence fails**: a second hooks file for the module (if the manifest allows a list), else the separate-plugin option under "Alternatives considered". Record the outcome in the task before continuing.
1. **MVP (estimate 2)**:
   - Module skeleton, config loader, kill switch and Feature 1 only, plus `themes/ccxp-contrast.json` and tests (including the disabled and helper-failure no-op tests).
   - It proves the wrap behaviour (UNVERIFIED) and the default-on path.
2. **Statusline v2 (estimate 3)**:
   - The helper `--json`, the band, `$.state` atoms, `session.measure` and the poll.
   - The VS Code `$.ui.status` mirror, and the fixture tests.
3. **Coexistence and polish (estimate 2)**:
   - The heartbeat-driven minimal settings statusline, the `/hud` pane, and README and `statusline-setup/SKILL.md` updates.

### Risks

- **Blast radius (raised by decision 1)**: the module is on for every `ccxp-skills` user, so an early-access mod API break reaches all of them, not only opt-in users.
  - Mitigations: `.catch` fallbacks to native drawing, a config-file kill switch, the global safe mode, `claude plugin validate` in CI, and a minimum CLI version in the README.
  - A bad release can be neutralised by users with `enabled: false`, and by us with a patch release that defaults it off.
- `hooks` and `modules` may not coexist in one `hooks.json`. Mitigation: phase 0 check and its fallback.
- A double frame or colour clash with the theme's `userMessageBackground`. Mitigation: per-feature switches, and default to the `quote` border only.
- The band competes with other mods' bands. Return `next(e)` inside your `Box` to keep theirs (docs: band section).
- Default-on changes the look of every user's terminal. Mitigation: a conservative default style, documented opt-out in the README and in the plugin's release notes (MINOR bump per `dev/guidelines.md`).

## Phase 0 results (2026-10-22, Claude Code 2.1.307, run from a fresh clone)

- **Coexistence: VERIFIED.** One `hooks/hooks.json` with the existing `"hooks"` (PreToolUse skill-ask) and `"modules": ["../hud/register.tsx"]`:
  - `claude plugin validate .` passes and lists the module's hooks.
  - `claude -p --plugin-dir .` logs `hooks module ccxp-skills@inline loaded (worker ...)`; the module ran `session.start` and `$.plugin.root` was the repo root, so the helper path resolves with no vendoring.
  - The module path is relative to `hooks/hooks.json`, so the file lives at `hud/` and is named `../hud/register.tsx`. No fallback is needed; the packaging decision stands.
- **Disable path: VERIFIED.** `--settings '{"disableAllHooks":true}'` and `--safe-mode` both stop the module (its probe file was never written). The per-feature `enabled: false` path is covered by `hud/hooks.test.tsx`.
- **Reload: live, by design.** `$.fs.write` is permitted to an absolute path (`plugin.register ... admitted`), so `/hud on|off` writes the user file. The module re-reads the config on every tick (5 s, gated by `pollSeconds`) and after `/hud`, so no reload is needed. A live-UI confirmation stays in the manual smoke item.
- **Not verifiable here**: how the wrapped `UserMessage` behaves in a real terminal (selection, copy, hover, ctrl+o) and the band's placement relative to the settings status line.

## Done criteria

- [x] The module is declared in `hooks/hooks.json` beside the existing hook, and validates: `claude plugin validate .` (no errors), `hooks/hooks.json:12`.
- [x] Data helper `hud-data.sh --json` emits task, branch, worktree and autopilot fields from the shared `sl-*` functions, never the `claimed_by` value: `tests/hud_data.bats` ("claimed task id and title, never the claimed_by value").
- [x] Prompt rows from the composer are wrapped, notifications and peers pass through: `hud/hooks.test.tsx` (default (no config file) test).
- [x] The band renders the fields at 140 and 80 columns and is empty with no data: `hud/pure.test.ts` (band tests).
- [x] `enabled: false` makes every hook a no-op with no helper run and no heartbeat: `hud/hooks.test.tsx` (enabled:false test).
- [x] Each feature switch is independent, a bad config means defaults, and helper failure never throws: `hud/hooks.test.tsx` (userMessage:false, band:false, config file, helper failure tests).
- [x] The existing statusline works unchanged without the mod and shrinks to `ctx | branch` only on a fresh `on` heartbeat: `tests/hud_data.bats` (heartbeat tests) and `tests/statusline_setup.bats`.
- [x] No network, model or MCP calls: `claude plugin validate .` call list and `tests/hud_data.bats` ("no network call").
- [ ] Live-UI check by the user (row style, selection, copy, ctrl+o, band under `/autopilot`, narrow terminal): manual smoke item, see Test plan.

## Root cause

- **Why there is a gap**: the only HUD surface was a single plain `statusLine.command` line (`statusline-setup/scripts/statusline-command.sh`, added in `8a1dacc`, 2026-10-20 as a deliberate, simple first version), and nothing styles the user's prompt row. A settings status line is not a render site, so it cannot be restyled; only a mod can.
- **Why a mod and not tweakcc**: it patches the minified CLI per version (see Research findings), where a mod uses the supported plugin API.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `hooks/hooks.json` | 1-20 | gains `"modules": ["../hud/register.tsx"]` |
| `hud/register.tsx` | all | wiring: config, events, state, render hooks, `/hud` |
| `hud/config.ts`, `hud/model.ts`, `hud/render.tsx` | all | pure config, snapshot/band layout, trees |
| `types/index.d.ts` | all | shared types and the `$.state` contract; named in `plugin.json` |
| `statusline-setup/scripts/hud-data.sh` | all | new `--json` data helper |
| `statusline-setup/scripts/statusline-command.sh` | `sl-autopilot-fields`, `sl-hud-active` | shared autopilot parser; heartbeat-driven minimal line |
| `tests/hud_data.bats`, `hud/*.test.ts(x)` | all | helper and mod tests |

## Open decisions (for the user)

1. **Packaging**: **DECIDED (2026-10-22, by the user)**: ship inside the `ccxp-skills` plugin as a module, loaded and enabled by default, with an optional off switch of its own (see Design, Config). The separate-plugin option is kept under "Alternatives considered".
2. **Band and statusline**: **DECIDED by the implementer (recommended option)**: the settings statusline shrinks to `ctx | branch` while the band's heartbeat is fresh; revisit after the live check.
3. **Defaults**: **DECIDED by the implementer**: `quote` bar in `suggestion` colour with no `YOU` label (the label would need a rewrite of `text`, which the live check should confirm first); `last_input` stays opt-in via `fields`.
4. **CI**: **DECIDED by the implementer**: mod tests stay local-only for now; the `claude` CLI install in Actions is a follow-up if the live check goes well.

## Closed (2026-10-22)

- **Shipped in** the ccxp-skills implementation PR for this task (see the PR linked from the task's merge commit); the claim was PR #414.
- **Met**: every Done-criteria box above except the live-UI check. `claude plugin validate .` passes, `claude plugin test .` runs 35 tests, and `bats tests/hud_data.bats tests/statusline_setup.bats` is green (64 tests).
- **Unverified (external)**: how the wrapped prompt row behaves in a real terminal, and the band's placement. A person must tick these; they are filed as follow-up **T20261022-287778** (next iteration, front of the queue). The Test plan's manual smoke box is left unticked on purpose.
- **Not done here, on purpose**:
  - the optional `themes/ccxp-contrast.json` (its manifest schema is unverified)
  - the plugin version bump (a maintainer-triggered MINOR bump PR per `dev/guidelines.md`)
  - the `YOU` label on prompt rows (it needs a `text` rewrite, to be decided after the live check)
- **Quality probe**: `file_loc regressed (delta 70)`, expected for a new module; shellcheck clean apart from one info note.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — tests were written alongside the code in the same pass, not red-first
- Verification (`superpowers:verification-before-completion`): yes — run commands before claiming (validate, plugin test, bats, design-score, skill score)
- Systematic debugging (`superpowers:systematic-debugging`): no — the few failures (BSD vs GNU `stat`, symlinked tmp paths) were diagnosed directly
- Receiving code review (`superpowers:receiving-code-review`): see the PR for the independent review result
