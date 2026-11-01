# ccxp-hud

A Claude Code **mod** that ships inside the `ccxp-skills` plugin, **on by default**.

- **Prompt rows**: your own prompts get a colored left bar (`quote` border) and yellow text (`USER_TEXT_COLOR` in `config.ts`; the renderer honours `NO_COLOR`); the agent's replies, task notifications and peer messages are left alone.
- **Status band** above the prompt: one row, or TWO when `ci` is set (the CI cell alone on a top row, red and highlighted when failing), in one of two modes (autopilot on / off). It names the repo you are working in (following `/cd`), colours context left, and shows a READY / WORKING jobs indicator. The HUD replaces the retired `statusline-setup` skill and its `statusLine.command`; the band is the only status line.
- **`/hud`**: `on | off | status | details | config`. A bare `/hud` (no argument) or an unknown one only prints the status line and usage; it never opens a dialog or writes. Run `/hud config` (optionally `/hud config <url>`, quoted or not) to configure. `details` is a toggle: it expands the band into up to six live detail lines (run it again to collapse); `config` asks for a workflow URL, the fill colour and whether to show the version cell, and writes them (see below). `/hud pane` was retired: it was a static side pane, `details` updates with the band.

## Turn it off (without uninstalling ccxp-skills)

- `/hud off` (writes `"enabled": false` to the file below), or edit it yourself.
- Takes effect within `pollSeconds` (default 15) with no reload; `/hud off` is immediate.
- Whole mods off: `disableAllHooks`, `--safe-mode`, or an org's `allowManagedModsOnly`.

## Config

User file `~/.claude/ccxp-hud.json` (honours `CLAUDE_CONFIG_DIR`), optional per-project `<project>/.claude/ccxp-hud.json` on top. Missing or malformed means defaults (on).

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | master switch; `false` makes every hook a pass-through |
| `userMessage` | `true` | prompt-row styling |
| `band` | `true` | status band |
| `userBorder` | `quote` | `single`, `double`, `round`, `bold`, `singleDouble`, `doubleSingle`, `classic`, `quote`; else no border |
| `userColor` | `suggestion` | a theme key or a hex colour |
| `fields` | `repo,branch,task,ap,ctx,jobs,queue,ci,lastat` | switches cells on or off; the mode decides which can appear (see below). `repo` carries the branch, so `branch` only shows when `repo` is not listed. `jobs` is the READY / WORKING cell (below), not the old `jobs run N · park · tot` line. `lastat` shows `you HH:MM` (date added when not today) from the last prompt this session submitted; it needs the timestamp-only UserPromptSubmit hook `hud/scripts/last-input-hook.sh` registered (see "Last-input hook" below), otherwise it stays hidden. `queue` is the queue cell (below). Also `rate`, `cost` (opt-in extras, dropped first). The retired `last` is ignored. An old explicit `fields` list without `repo`/`jobs`/`queue`/`ci` hides those cells until you add them (and one that still names `jobs` now gets the new indicator) |
| `ci` | unset (no CI cell) | `{ "workflow": "<file or id>", "branch": "<ref>", "repo": "<owner/name>" }`; only `workflow` is required. `branch` defaults to the repo's default branch, `repo` to the current repo. A bare string is a workflow. Invalid values (spaces, shell characters, bad `owner/name`) mean no CI cell. A project file's `"ci": null` switches a user-level `ci` off for that project. `/hud config` writes it for you from one workflow URL (repo and workflow derived; `branch` only when the URL carries one) |
| `fillColor` | `gray` | colour of the always-on fill bar (see "Fill" below): `gray`, `blue`, `green`, `yellow`, `purple` or a `#rrggbb` hex; `/hud config` writes it. An old `fill` key is ignored |
| `version` | `true` | shows the ccxp-skills version cell (see "Version cell" below); `false` hides it and stops the lookup. It is its own key, not a `fields` entry, so an old explicit `fields` list still shows it. `/hud config` writes it |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `75` / `50` | context-LEFT colour thresholds, see "Colours" below. Defaults were `40` / `15`; a value you set yourself is kept, but the red boundary is now strict (red AT `ctxCrit` and below, was below) |

Example, in a repo whose nightly orchestrator workflow is `nightly-orchestrator.yml` (`<project>/.claude/ccxp-hud.json`):

```json
{ "ci": { "workflow": "nightly-orchestrator.yml" } }
```

## Modes and layout

The mode is picked automatically: **AP on** while autopilot is on (working, backing off, idle or capped all count; paused counts and is marked), **AP off** otherwise (`/autopilot off`, an old-format state file, or none). The band is ONE row at every width, or TWO when `ci` is configured and answered: CI is alone on the top row, everything else on the second (see "CI cell"). Cells with nothing to say are dropped, never padded.

| Mode | Row |
|---|---|
| AP off | `acme/widgets @ main* \| T<id> <task slug> \| WORKING (2) \| queue 44 = 30r 6b 3d 2e 3x \| you 09:05` (no AP cell, no ctx) |
| AP on | `AP 2/6h 3 loops ✓2 merged \| last 24h: 8 merged ▲ / 26 loops · average 5.2/day \| queue 44 = 30r 6b 3d 2e 3x \| ctx 64% ▓▓▓▓▓▓░░░░ \| WORKING (2) \| you 09:05` (no repo or task); paused reads `AP ⏸ paused 2/6h ...` |

With `ci` set, the band is two rows, CI alone on top (AP on, red CI shown; the mock is drawn with `[ ]` where the row is reverse video):

```text
[ CI (nightly.yml) ✗ failing 10-28 (2h ago)                                                    ]
 AP 2/6h 3 loops ✓2 merged │ last 24h: 8 merged ▲ / 26 loops · average 5.2/day │ queue 30/44 │ ctx 64% │ WORKING (2)
```

- Row 2 order: AP, the 24h cell, then queue (so AP and queue always share a row), then ctx, jobs, last input, version. Queue is never on the CI row.
- No `ci` (or no answer yet): row 2 alone, exactly as before.

| Width | Tier | AP | ctx |
|---|---|---|---|
| < 70 | tiny | `AP 2/6h 3L ✓2` | `ctx 64%` |
| 70-99 | compact | `AP 2/6h 3 loops ✓2` | `ctx 64%` |
| >= 100 | wide | `AP 2/6h 3 loops ✓2 merged` | `ctx 64% ▓▓▓▓▓▓░░░░` |

- Tiers only set how detailed the AP and ctx cells start (the CI row always starts full). When the row is still wider than the terminal, cells shrink or go in this order: last input (`you`), `WORKING (N)` loses its count, task slug (the task ID stays), repo cell detail (worktree, account, then owner and long names), task ID, then the repo cell loses its branch. AP on: last input, ctx meter, jobs count, the 24h cell (spelled out, then shorter, `avg` only in the last two forms), AP words, then ctx, then the 24h cell, then the version. Repo (or AP) and jobs stay longest.
- `READY` has one form; `WORKING (N)` becomes `WORKING` when narrow.
- The AP elapsed/requested pair keeps its `h` so `2/6h` cannot read as loops.
- **24h progress cell** (AP on, next to the AP cell, switched by the `ap` field): the last 24 hours as a rolling window (not a calendar day) against the lifetime average per 24 h, so you can see whether productivity trends up. `last 24h: 8 merged ▲ / 26 loops · average 5.2/day` shrinks to `24h: 8 merged ▲/26 loops · average 5.2/day`, `24h: ✓8▲/26L average 5.2/d`, then (the last two forms, also where the terminal is under 70 columns) `24h ✓8▲/26L avg 5.2/d` and `24h ✓8▲`, and drops after the ctx cell; the ctx bar, CI and jobs cells shrink first, so the 24h merged count and the average stay visible from about 80 columns up. The arrow sits right after the 24h merged count: green `▲` = above the average, red `▼` = below, **no arrow** = the same. "Same" = equal when both are compared at one decimal (the average is shown with one decimal, so a whole-number count is the same only as an average that rounds to it, e.g. 5 vs 5.0). No average (no counters and no history) = no cell, so no arrow. The arrow uses the theme tokens `success` / `error`; with `NO_COLOR` the glyph stays and only the colour drops. Data: `autopilot-state.sh stats --json` over `dev/.autopilot-history.jsonl` and the state file's counters (one jq pass, no network). With a stats object the 24 h number always shows. It is exact when the log reaches back over the whole window, or when the state shows no cycle inside it (an exact `0`). While the log is missing or starts inside the window (a repo whose autopilot ran before the log existed, e.g. before 5.6.0, has no log until its first cycle on the new version) and a cycle ran inside the window, it falls back to the state's calendar-day counters (`merges_today` / `cycles_today`, the day of the last cycle) and shows `~8`: an estimate, not a bound (a calendar day can hold work older than the window, miss the earlier-day part of it, or have just rolled to zero), so an estimate carries no arrow until the log covers 24 h. `off`/`start` keeps the baseline. The details view repeats the cell on its AP line, where it is dropped last (after the next-loop and queue cells have shrunk).
- `stale` (the helper failed) is a dim tail cell that goes first.

## Repo cell (AP off)

- Shape: `[→ ]owner/name @ branch* (wt X) (account) (root: X)`, following the CURRENT session cwd, not the directory Claude was launched in. Outside git it is just the folder name.
  - `owner/name` comes from `origin` (a repo with no remote shows its folder name); `branch` is `detached <sha>` on a detached HEAD.
  - `*` (yellow) = changed tracked files; untracked files are not scanned (slow on big trees). The helper reports the count (capped at 99); the band only shows the mark.
  - `(wt X)` = a linked git worktree; `(account)` = the `gh` account of that directory.
  - `→` leads for about two refreshes after the working tree changed; `(root: X)` (yellow) shows when a shell `cd` left the session root.
- gh account: from the session cwd, never the helper's inherited environment. `direnv exec <root> printenv GH_CONFIG_DIR`, else the nearest `.envrc` (`export GH_CONFIG_DIR=...` with `~`, `$HOME`, quotes, `source_up`), else the default gh config; then the `user:` line of `hosts.yml`. The token is never read. Cached 60 s per repo in `${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-cache/` (the helper's only write besides the CI and version caches); no network. It is what direnv says, not necessarily what a Bash tool call will use.
- Following `/cd`: the mod reads `$.session.cwd()` on every refresh (falling back to the session root), and a 5 s tick refreshes at once when cwd or root changed. A `command.run` hook for `cd` refreshes right after `/cd`; the 15 s poll is the backstop.
- Unverified in a real session: that `session.cwd()` moves on `/cd`, and that `command.run` fires for the built-in `/cd` (the tick covers latency, but not a `cwd()` that never moves; then use `root()`).
- Helper JSON (`hud-data.sh --json`): `repo` is unchanged (name only, always present); `cwd`, `repo_slug`, `repo_root`, `head`, `dirty`, `gh_account` (null outside a repo); `plugin` = `{installed, latest}` plus `url` when the manifest names a plain `https://github.com/<owner>/<repo>` (null when `version` is off; `latest` = highest known release or null when unknown; the mod compares).
- AP-on rows have no repo cell, same as before.

## Colours

- ctx is context LEFT (100 minus the engine's percent used). Green above 75, yellow above 50 up to 75, red at 50 or less; the boundaries are strict (75 is yellow, 50 is red) and compare the rounded number shown.
- Jobs cell: green `READY` when the job ledger (`hud/scripts/ledger.md`) has no running job, yellow `WORKING (N)` while N run. No ledger, no cell. It reads the ledger, not the engine's agent list.
- Theme tokens only (`success`, `warning`, `error`), no escape codes: themes and `NO_COLOR` keep working.

## CI cell

- Layout: the CI cell is not part of the second row; it has its own TOP row, only when `ci` is configured and the helper has an answer (`fields` still switches it off with `ci`). No `ci`: the band stays one row.
- Colours (state, text, row look):

| State | Text | Colour | Row highlight |
|---|---|---|---|
| passing | `✓ passing` | green | none |
| running (queued or in progress) | `◐ running` | yellow | none |
| failing (also timed out) | `✗ failing` | red | whole row: bold, red text in reverse video (a solid red bar across the width), whatever the fill colour or theme |
| unknown (cancelled, skipped, other) | `? unknown` | grey | none |

- `NO_COLOR` set: the red row loses its colour but keeps bold reverse video, and the state word is shouted: `✗ FAILING` (read through the engine's `env.get`, so the mod never touches `process.env`).
- Text: `CI (workflow) ✗ failing 10-28 (2h ago)`, shrinking by width to `CI ✗ failing 10-28 (2h ago)`, `CI ✗ 10-28 (2h ago)`, `CI ✗ 10-28`, `CI ✗` (workflow name first, then the state word, the age, the date).

- Source: the LAST run of the configured workflow (`ci` above), via `gh run list --workflow <w> --branch <b> --limit 1` in `hud/scripts/hud-ci.sh`. Nothing is hard coded; no `ci` means no cell and no `gh` call.
- States: `✓ passing` (green), `✗ failing` (red; also timed out), `◐ running` (yellow; queued or in progress), `? unknown` (grey; cancelled, skipped, other). The date is the run's creation day (`MM-DD`).
- Never blocks the band: the helper answers from an on-disk cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-ci/`) and starts one detached refresh when the cache is older than 120 s (or `pollSeconds`, whichever is larger), 5 s timeout per call. The first result can take a couple of minutes.
- No such workflow, `gh` missing, signed out or offline: the cell is silently dropped (an older cached answer is kept). Tokens and `gh` output are never shown; the JSON is untrusted and only an enumerated state plus a timestamp survive.

## Queue cell

- Shows where `dev/TODO/queue.md` stands, for a repo that has one (none, no cell; nothing is ever an error). Band: `queue 44 = 30r 6b 3d 2e 3x` (ready, blocked, decision, external, epic), squeezed to `queue 30/44` and dropped early when the row is tight. In AP-on mode it sits right after the AP and 24h cells. `/hud details` spells it out on the AP line: `queue 44 = 30 ready | 6 blocked | 3 decision | 2 external | 3 epic`. Add or remove it with `fields` (`queue`).
- Deterministic (no LLM): one `awk` over the queued task files plus one `jq` per poll, in `sl-queue-json` (`hud/scripts/hud-lib.sh`); helper JSON key `queue` = `{total, ready, blocked, decision, external, epic, claimed}`. `total` is the number of task lines (`- [T<id>](file.md)`; struck-through lines are not tasks).
- Every task is counted in exactly ONE bucket, first match wins, so the buckets always add up to `total`:
  1. epic: `kind=epic` in the autopilot's needs_attention, or the frontmatter has a `children:` key, the task is the parent of a `dev/EPICS/E*.md` epic (opt-in: add a `Parent design task: [T<id>](...)` or `Parent: T<id>` line to the epic file; only the first id on that line counts), or it carries a deliberate uppercase marker (title starts with `EPIC` or contains `— EPIC`; status contains the uppercase word `EPIC`). Free-text `umbrella` / `epic` / `tracking task` is not a signal (it misfires on product terms and prose). Plain members of a `dev/EPICS` epic are ordinary tasks and stay takeable.
  2. blocked: `kind=blocked`, or status `Blocked by T<id>` while that task is still in `dev/TODO/`, or status containing `BLOCKED` or `SUPERVISED` (case-sensitive).
  3. external: `kind=external`, or the status mentions upstream, HashData, Apache, customer or external.
  4. decision: `kind=decision`, or the status says needs/owner decision, "needs a human", "needs manual" or sign-off; also an id in `skip_ids` that has no kind and no hint.
  5. claimed: `claimed_by:` is set to a clone other than this one or the autopilot's dispatch clone. It is its own bucket so ready stays honest; it is shown only when above 0.
  6. ready: the rest, what the autopilot can take. A queue line whose task file is missing counts as ready.
- The autopilot's `dev/.autopilot-state.json` is read only while it is `on` or `paused`; its `needs_attention[].kind` (set by `autopilot-state.sh skip <id> "<reason>" --kind blocked|decision|external|epic`) wins over the frontmatter hints, and `skip_ids` (today's skips) are never ready.

## Version cell

- Shows the installed ccxp-skills version, last in the band, compared with the latest public release:
  - same version: `ccxp 5.1.1 (latest)`, "(latest)" in the `success` colour; narrow: `ccxp 5.1.1 ✓`, then dropped (like the plain form).
  - a newer release: `ccxp 5.1.1 (5.2.0 available)`, the new number in the `suggestion` theme colour (stands out, not loud); narrow: `ccxp ↑5.2.0`, then `↑5.2.0`. The update form is kept almost to the end.
  - latest unknown (lookup not done yet, offline, no tag) or installed newer than latest (dev/prerelease): plain `ccxp 5.1.1` (dim), dropped first when the row is tight. "latest" is never claimed without a successful comparison.
  - `/hud details` shows the same text (the full form) on its last line, next to the `you` stamp, followed by the plugin's GitHub location as a bare URL (`https://github.com/Synx-Data-Labs/ccxp-skills`) so a terminal can cmd/ctrl-click it. The URL is the `repository` (else `homepage`) of the plugin's own `plugin.json`, read by the helper; the public URL above is the fallback. It is plain text, not an OSC 8 hyperlink (the renderer draws text only). The one-row band never shows it.
- Installed: the running plugin's own `.claude-plugin/plugin.json` (the helper's install dir), a local read.
- Latest: the highest plain `ccxp-skills--vX.Y.Z` tag of the public Synx-Data-Labs/ccxp-skills repo, via `git ls-remote --tags` in `hud/scripts/hud-version.sh` (no credentials, no `gh`). Prereleases are ignored. Newer/same/older is decided by numeric semver (5.10.0 > 5.9.0), never by string compare. The helper reports the highest known tag as `latest` whatever its relation to installed; the mod picks the wording.
- Same pattern as the CI cell: answers from a cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-version/`), at most one detached refresh per 6 hours (8 s timeout, no credential prompt). Offline or git missing: the cached answer is kept, the next try is about 15 minutes later, and the cell shows the last known answer (or the installed version alone when there never was one). Only strings matching the tag pattern are ever drawn.
- Squeezing: the plain `ccxp X` goes right after the last-input cell; the update marker is kept almost to the end. `/hud details` shows it on the last line (6 with CI, else 5) next to `you` and never drops it: on a narrow terminal the URL goes first, then the `you` stamp shrinks, then the label narrows to `✓`/`↑`. A short terminal that caps the detail lines below the line count cuts the last line, which is this one.
- Turn it off: `"version": false` or `/hud config`.
- An update is picked up by `/plugin` (reinstall or update); the cell is information only and changes nothing.

## `/hud config`

- Renamed from `/hud setup` (breaking: `/hud setup` no longer exists and there is no alias). `/hud fill on|off` was removed too: the fill is always on.
- Asks (through the engine's question dialog; type values under "Other"):
  - one CI answer: "Paste a GitHub Actions workflow URL (repo and workflow are derived from it), or none to hide CI." Accepted: `https://github.com/<org>/<repo>/actions/workflows/<file>.yml` (optionally `?query=branch%3A<b>`, which then pins that branch), `https://github.com/<org>/<repo>/blob/<branch>/.github/workflows/<file>.yml`, or a bare workflow file name (repo = the session's repo). Also accepted: `tree/` and `raw/` forms of the file URL, a scheme-less `github.com/...`, and the answer wrapped in quotes, backticks or angle brackets or padded with spaces/newlines. `/hud config <url>` supplies this answer up front and skips the question (the dialog headers stay within the engine's 12-character limit). `none`, `no`, `-` or blank hides CI. A run URL (`.../actions/runs/<id>`) is refused because it does not name the workflow. No branch or repo question: the branch is the repo's default unless the URL names one
  - fill colour: gray (default), blue or green as options; yellow, purple or a `#rrggbb` hex typed under Other (the engine's dialog takes at most 4 options per question)
  - ccxp-skills version cell: show (default) or hide
  - scope: user file or this project's `.claude/ccxp-hud.json`
- An invalid CI or colour answer never aborts the dialog: it is asked again once (naming the rejected value, with an example URL for CI); after a second invalid answer that setting is left unchanged and the dialog carries on, so the colour and scope questions are always reached.
- Shows the resulting `"ci"`, `"fillColor"` and `"version"` values and the file, and writes only after you pick `write`. Only those three keys are merged in (a skipped one is not touched); other keys are kept. Nothing is written on an explicit cancel or a dismissed dialog ("ccxp-hud config cancelled; nothing written.", with the dialog's reason when it gave one); any other exception reports "ccxp-hud config failed: <reason>; nothing written."

## Fill

- Always on: the band is padded with spaces to the band's width and drawn on a background, so it reads as a solid bar apart from the rest of the output. One row, two with CI (or the detail lines under `/hud details`). A red CI row ignores the fill colour and is drawn in reverse video.
- Width: the engine's `bodyColumns` for the band (the terminal, or the transcript's column beside a docked pane, less the five columns the engine keeps for its `[-]` mark), so the bar ends just before that mark. The band is redrawn by the engine when the width changes.
- Measured in display columns (`hud/fill.ts`): emoji and CJK count 2, combining marks and joiners 0, ANSI codes 0. Content wider than the bar is cut with an ellipsis before padding, so a row never exceeds the width.
- Colour (`fillColor`, default gray) follows the `/config` theme: each named colour has a muted dark tint for `dark*` themes and a pale tint for `light*`, so the cell colours (CI, AP, jobs) stay readable on both. Any other theme (auto, unreadable) uses reverse video. A custom `#rrggbb` is drawn as given on every theme (pick one that suits your terminal). An invalid value means gray.
- Falls back to the plain unfilled row when the width is unknown or under 40 columns. `fillColor` is a plain config key: a project file's value wins over the user file's.

## `/hud details`

Toggles the band between the compact view and up to six detail lines (this session only; a new session starts collapsed). It is the same band, so it refreshes live with it (the 15 s poll, each finished turn, `/cd`, and context/cost measurements) and adds no extra `git` or `gh` calls. It ignores `fields` and needs `band` on (otherwise `/hud details` says so).

| Line | Shows |
|---|---|
| 0 CI | `CI (workflow) ✓ passing 10-28 (2h ago)` first and alone (only when `ci` is set); a failing run is drawn as the red bold reverse-video row, as in the band (`✗ FAILING` with `NO_COLOR`) |
| 1 where | `owner/name @ branch*` plus worktree, account and `(root: X)` as in the repo cell, then the claimed task `T<id> title` |
| 2 usage | spelled out: `context 64% left ▓▓▓▓▓▓░░░░` (same colours as the band; the band's `ctx` is context LEFT), `5-hour limit 4% used` (share of your Claude subscription's rolling 5-hour usage window, from the engine's `rate_limits`; hidden when the engine reports none, e.g. API-key use), `API-equivalent cost $693.75` (the engine's running estimate of this session's token usage at API list prices, `cost.total_cost_usd`; NOT what a subscription bills) |
| 3 jobs | `READY` / `WORKING (N)`, `parked N`, `total jobs N` (from the ledger; no ledger, no line). The running jobs are not listed: the status already shows them. `parked N` is the length of the ledger's `parked` array (contexts are not shown here) |
| 4 autopilot and queue | `AP on 2h …` (`AP idle 2h …` when idle, `AP ⏸ paused 2h …` when paused, `AP off` when off or none), then the next-loop cell, then the 24h cell (which ends in the average), then ` \|\| ` and the queue group `queue 44 = 30 ready \| 6 blocked \| 3 decision \| 2 external \| 3 epic` (`\| 2 claimed` appended when above 0; see "Queue cell"; no `dev/TODO/queue.md`, no queue part and no `\|\|`). Full line: `AP on 2/6h 3 loops ✓2 merged │ next loop 14:32 (in 12m) │ last 24h: 8 merged ▲ / 26 loops · average 5.2/day \|\| queue 44 = 30 ready \| 6 blocked …`. The next-loop cell is `next loop 14:32 (in 12m)` from the state file's `next_wake_at` (`next loop paused` when paused, `next loop due` when the time has passed between cycles, nothing when absent; while a cycle runs (the state file's `busy_since` is set) it shows `running r596` instead, the highest-numbered running ledger row flagged `autopilot` (the dispatcher starts the cycle with `ledger.sh start <n> "autopilot cycle" --flags autopilot`), or plain `running` when no such row exists) |
| 5 you | `you HH:MM (5m ago)`, the last prompt (needs the last-input hook), then the version label and plugin URL |

- Line 4 narrows in this order: the queue words (`30r 6b …`, then `queue 30/44`), the 24h cell (shorter, then dropped), the next-loop clock then its wait, then the AP words, and the next-loop cell last. The `\|\|` belongs to the queue group: it shows only when an AP cell precedes the queue (so `AP off \|\| queue …` when autopilot is off) and never dangles.
- Every line is cut to the terminal width with the band's shrinking idea: ages and labels shorten first, then labels shorten (`5h limit 4%`, `cost $693.75`, `ctx 88%`, `total 82`, `next loop in 12m`) and lower-value cells drop (`total`, parked, cost, rate limit), and only then is text cut. Lines with nothing to say are left out, so you may see fewer than six (never more: CI and queue no longer have lines of their own). The height is capped at the engine's `maxRows`.
- The VS Code compact status line stays one line.
- The retired `/hud pane` is not an alias: it prints the usage line.

## Notes

- Needs Claude Code 2.1.287 or newer (mods on by default); the mod API is early access and may change.
- Data comes from `hud/scripts/hud-data.sh --json` (bash; keeps the claimant secret out of the mod). The only network use is the cached, detached CI lookup above (and only when `ci` is set) and the cached, detached version lookup (`git ls-remote`, at most every 6 hours, only while `version` is on); no model or MCP calls.
- Any error inside a hook falls back to Claude Code's own drawing.
- Tests: `claude plugin test .` (units and hook behaviour) and the bats files under "Last-input hook" (bash layer).

## Last-input hook (optional, for `lastat`)

Plugins cannot register a `UserPromptSubmit` hook for you here, so add it once per Claude config dir in `settings.json`. Append to `hooks.UserPromptSubmit`, never replace the array. The hook is timestamp-only (it never reads or stores prompt text) and must never fail a prompt:

```json
"UserPromptSubmit": [
  { "hooks": [ { "type": "command", "command": "bash <plugin>/hud/scripts/last-input-hook.sh" } ] }
]
```

`<plugin>` is the plugin install path (`~/.claude/plugins/cache/ccxp-skills/ccxp-skills/<version>` for a marketplace install, which needs re-pointing after a version bump, or your dev checkout for a `directory` source). This path was `statusline-setup/scripts/last-input-hook.sh` before that skill was retired.

### Keeping reply, ledger and status consistent

- One source: `ccxp-ledger.json`. `ccxp-ledger.md`, the HUD band and the reply tail are all derived from it.
- Reply: the dispatcher pastes `ledger.sh reply` verbatim instead of writing the tail by hand.
- Check: `ledger.sh check <file|->` compares the refs of a draft reply with the file and fails on `MISSING`, `EXTRA` and `NO-CONTEXT` items.
- Liveness: the dispatcher runs `reconcile --alive <n,...>` each turn and `finish <n>` when a job fails or is killed, so a dead job does not stay WORKING.
- Context: every running, next and parked item needs a context file path; `reply` shows `context: MISSING` and `next add`/`park` warn without `--context`.

The job ledger writer is `hud/scripts/ledger.sh` (calls in `hud/scripts/ledger.md`). It also keeps what a restart needs to resume running jobs (`reconcile`, `resumed`; see the Resume section there). Tests for the bash layer: `bats tests/hud_lib.bats tests/hud_data.bats tests/hud_ci.bats tests/hud_version.bats tests/last_input_hook.bats tests/ledger.bats`.
