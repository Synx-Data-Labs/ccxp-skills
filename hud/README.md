# ccxp-hud

A Claude Code **mod** that ships inside the `ccxp-skills` plugin, **on by default**.

- **Prompt rows**: your own prompts get a colored left bar (`quote` border) and yellow text (`USER_TEXT_COLOR` in `config.ts`; the renderer honours `NO_COLOR`); the agent's replies, task notifications and peer messages are left alone.
- **Status band** above the prompt: one row, or TWO when `ci` is set (the CI cell alone on a top row, red and highlighted when failing), in one of two modes (autopilot on / off). It names the repo you are working in (following `/cd`), colours context left, and shows a READY / WORKING jobs indicator. The HUD replaces the retired `statusline-setup` skill and its `statusLine.command`; the band is the only status line.
- **`/hud`**: `on | off | status | details | config`. A bare `/hud` (no argument) or an unknown one only prints the status line and usage; it never opens a dialog or writes. Run `/hud config` (optionally `/hud config <url>`, quoted or not) to configure. `details` is a toggle: it expands the band into up to seven live detail lines, eight with a CI row (run it again to collapse); `config` asks for a workflow URL, the fill colour, whether to show the version cell and where the queue is read from, and writes them (see below). `/hud pane` was retired: it was a static side pane, `details` updates with the band.

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
| `fields` | `repo,branch,task,ap,ctx,jobs,queue,nightly,ci,lastat` | switches cells on or off; the mode decides which can appear (see below). `repo` carries the branch, so `branch` only shows when `repo` is not listed. `jobs` is the READY / WORKING cell (below), not the old `jobs run N · park · tot` line. `lastat` shows `you HH:MM` (date added when not today) from the last prompt this session submitted; it needs the timestamp-only UserPromptSubmit hook `hud/scripts/last-input-hook.sh` registered (see "Last-input hook" below), otherwise it stays hidden. `queue` is the queue cell (below). `nightly` is the nightly last-7-days strip and 30-day green and red day counts cell ("Nightly cell"). Also `rate`, `cost` (opt-in extras, dropped first). The retired `last` is ignored. An old explicit `fields` list without `repo`/`jobs`/`queue`/`nightly`/`ci` hides those cells until you add them (and one that still names `jobs` now gets the new indicator) |
| `ci` | unset (no CI cell) | `{ "workflow": "<file or id>", "branch": "<ref>", "repo": "<owner/name>", "eta": false }`; only `workflow` is required. `eta` (default on) shows the finish estimate on a running run, see "CI ETA" below; only an explicit `false` turns it off. `branch` defaults to the repo's default branch, `repo` to the current repo. A bare string is a workflow. Invalid values (spaces, shell characters, bad `owner/name`) mean no CI cell. A project file's `"ci": null` switches a user-level `ci` off for that project. `/hud config` writes it for you from one workflow URL (repo and workflow derived; `branch` only when the URL carries one) |
| `fillColor` | `gray` | colour of the always-on fill bar (see "Fill" below): `gray`, `blue`, `green`, `yellow`, `purple` or a `#rrggbb` hex; `/hud config` writes it. An old `fill` key is ignored |
| `version` | `true` | shows the ccxp-skills version cell (see "Version cell" below); `false` hides it and stops the lookup. It is its own key, not a `fields` entry, so an old explicit `fields` list still shows it. `/hud config` writes it |
| `queue` | unset (= `default-branch`) | `{ "source": "default-branch" \| "working-tree" }` (a bare string works too): where the queue cell and its counts read `dev/TODO` from, see "Queue cell". `default-branch` (the default) reads the repo's default branch on origin (git object reads only, after a detached fetch of that one branch), so a clone that is behind still shows what GitHub has; `working-tree` is the explicit opt-in for this clone as it is on disk (the old default). A project file's `queue` replaces the user file's; a project `"queue": null`, or an invalid value, drops the setting and means the default (`default-branch`), so the only way to force `working-tree` is to write it. An unknown value means `default-branch`. `/hud config` writes it |
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
| AP off | `acme/widgets @ main* \| T<id> <task slug> \| WORKING (2) \| queue 44 = 30r 6h 3x \| you 09:05` (no AP cell, no ctx) |
| AP on | `AP 2/6h 3 loops ✓2 merged \| last 24h: 8 merged ▲ / 26 loops · average 5.2/day \| queue 44 = 30r 6h 3x \| ctx 64% ▓▓▓▓▓▓░░░░ \| WORKING (2) \| you 09:05` (no repo or task); paused reads `AP ⏸ paused 2/6h ...` |

With `ci` set, the band is two rows, CI alone on top (AP on, red CI shown; the mock is drawn with `[ ]` where the row is reverse video):

```text
[ CI (nightly.yml) ✗ failing 10-28 (2h ago)                                                    ]
 AP 2/6h 3 loops ✓2 merged │ last 24h: 8 merged ▲ / 26 loops · average 5.2/day │ queue 30/44 │ ctx 64% │ WORKING (2)
```

- Row 2 order: AP, the 24h cell, then queue (so AP and queue always share a row), then nightly, then ctx, jobs, last input, version. Queue is never on the CI row.
- No `ci` (or no answer yet): row 2 alone, exactly as before.

| Width | Tier | AP | ctx |
|---|---|---|---|
| < 70 | tiny | `AP 2/6h 3L ✓2` | `ctx 64%` |
| 70-99 | compact | `AP 2/6h 3 loops ✓2` | `ctx 64%` |
| >= 100 | wide | `AP 2/6h 3 loops ✓2 merged` | `ctx 64% ▓▓▓▓▓▓░░░░` |

- Tiers only set how detailed the AP and ctx cells start (the CI row always starts full). When the row is still wider than the terminal, cells shrink or go in this order: last input (`you`), `WORKING (N)` loses its count, task slug (the task ID stays), repo cell detail (worktree, account, then owner and long names), task ID, then the repo cell loses its branch. AP on: last input, ctx meter, jobs count, the 24h cell (spelled out, then shorter, `avg` only in the last two forms), AP words, then ctx, then the 24h cell, then the version, and last the stalled cell (below), which only exists while the loop is overdue. Repo (or AP) and jobs stay longest.
- `READY` has one form; `WORKING (N)` becomes `WORKING` when narrow.
- The AP elapsed/requested pair keeps its `h` so `2/6h` cannot read as loops.
- **24h progress cell** (AP on, next to the AP cell, switched by the `ap` field): the last 24 hours as a rolling window (not a calendar day) against the lifetime average per 24 h, so you can see whether productivity trends up. `last 24h: 8 merged ▲ / 26 loops · average 5.2/day` shrinks to `24h: 8 merged ▲/26 loops · average 5.2/day`, `24h: ✓8▲/26L average 5.2/d`, then (the last two forms, also where the terminal is under 70 columns) `24h ✓8▲/26L avg 5.2/d` and `24h ✓8▲`, and drops after the ctx cell; the ctx bar, CI and jobs cells shrink first, so the 24h merged count and the average stay visible from about 80 columns up. The arrow sits right after the 24h merged count: green `▲` = above the average, red `▼` = below, **no arrow** = the same. "Same" = equal when both are compared at one decimal (the average is shown with one decimal, so a whole-number count is the same only as an average that rounds to it, e.g. 5 vs 5.0). No average (no counters and no history) = no cell, so no arrow. The arrow uses the theme tokens `success` / `error`; with `NO_COLOR` the glyph stays and only the colour drops. Data: `autopilot-state.sh stats --json` over `dev/.autopilot-history.jsonl` and the state file's counters (one jq pass, no network). With a stats object the 24 h number always shows. It is exact when the log reaches back over the whole window, or when the state shows no cycle inside it (an exact `0`). While the log is missing or starts inside the window (a repo whose autopilot ran before the log existed, e.g. before 5.6.0, has no log until its first cycle on the new version) and a cycle ran inside the window, it falls back to the state's calendar-day counters (`merges_today` / `cycles_today`, the day of the last cycle) and shows `~8`: an estimate, not a bound (a calendar day can hold work older than the window, miss the earlier-day part of it, or have just rolled to zero), so an estimate carries no arrow until the log covers 24 h. `off`/`start` keeps the baseline. The details view repeats the cell on its AP line in full (never abbreviated; a narrow terminal cuts the line with an ellipsis).
- **Stalled cell** (AP on, on the band's main row, right after the AP and 24h cells): when the autopilot's `next_wake_at` passed more than 10 minutes ago and it is neither paused nor mid-cycle, the band shows a warn-coloured `stalled 2d` (largest unit only: `stalled 25m`, `stalled 3h`, `stalled 2d`). Within the 10-minute grace nothing shows. It is dropped last, after the version. Details spells the same state out on the AP line (`next loop overdue 2d 16h`, see "`/hud details`"). The grace is `STALL_GRACE_SEC` in `hud/model.ts`.
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

### Jobs 24h cell

- Where: the jobs line of `/hud details` (the one-row band keeps `READY` / `WORKING (N)`): `READY │ parked 2 │ last 24h: jobs 8 ▲ / average 5.2/day`. The old `total jobs N` figure is gone.
- Unit: jobs STARTED (the ledger has no finish times to count). `n` = starts in the rolling last 24 hours (not a calendar day); `m` = lifetime jobs (the ledger's `lifetime_jobs`, the highest job number ever) divided by max(1, days since the first job), one decimal.
- Same conventions as the AP 24h cell: green `▲` above the average, red `▼` below, no arrow when equal at one decimal; `~8` = the count may be too low (the start log is younger than 24 hours), no arrow then; `~5.2` = the average rests on an estimated first-job time. No stats, no cell.
- Data: `ledger.sh start` appends `epoch<TAB>n` for each NEW job to `ccxp-ledger-starts.log` next to the ledger (mode 600, append-only, no titles; a re-start of a running or already logged job adds nothing). The first time the log is created on a ledger that already counts jobs, a one-time `#seed` line records an estimated first-job time (the oldest `<ledger>.bak-<UTC stamp>` migration backup, else now), so the average is meaningful from day one. `ledger.sh stats [--json]` does the read-only math (`LEDGER_NOW` is the test clock); `hud-data.sh` adds it as `ledger.stats` = `{approx, avg_approx, jobs_24h, avg_jobs_day, trend}`, absent when the ledger has never counted a job.

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

- Source: the LAST run of the configured workflow (`ci` above), via ONE `gh run list --workflow <w> --branch <b> --limit 20 --json status,conclusion,createdAt,startedAt,updatedAt,event` in `hud/scripts/hud-ci.sh` (the newest run is the state; the older ones feed the ETA). Nothing is hard coded; no `ci` means no cell and no `gh` call.
- States: `✓ passing` (green), `✗ failing` (red; also timed out), `◐ running` (yellow; queued or in progress), `? unknown` (grey; cancelled, skipped, other). The date is the run's creation day (`MM-DD`).
- CI ETA (`ci.eta`, default on): while the newest run is `in_progress`, the running state gets an estimate. No extra call and no extra cache: it is computed in the same detached refresh.
  - History: the older runs of the same workflow and branch that completed with `success`, newest first, at most 7, duration = `updatedAt - startedAt`. Runs of the same `event` (`schedule` vs `workflow_dispatch`) are used when there are at least 3 of them, otherwise every event. Fewer than 3 usable runs: no ETA at all (the cell is as before).
  - Typical = the median duration; the spread is `max - min` of the same runs. Queued runs get no ETA (they have not started).
  - Shown after the state, in local time: `CI (nightly.yml) ◐ running ETA 18:40 10-28 (35m ago)`. Spread at most half the median: one time (start + median). Wider (a long orchestrator whose runs differ a lot): a range from the fastest to the slowest recent run, `ETA 14:20-19:05`. A time on another day carries `+1d` (`ETA 03:00 +1d`).
  - Overdue (elapsed beyond the median, or beyond the slowest run for a range): `over usual (4h)`, the median duration (`45m`, `4h`, `4.5h`); never a negative time.
  - Dropped first when the band is narrow (before the workflow name, state word, age, date). Switch off with `"ci": { "workflow": "...", "eta": false }`; `/hud config` does not ask about it, but keeps a hand-set `"eta": false` when it rewrites `ci`.
- Never blocks the band: the helper answers from an on-disk cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-ci/`) and starts one detached refresh when the cache is older than 120 s (or `pollSeconds`, whichever is larger), 5 s timeout per call. The first result can take a couple of minutes.
- No such workflow, `gh` missing, signed out or offline: the cell is silently dropped (an older cached answer is kept). Tokens and `gh` output are never shown; the JSON is untrusted and only an enumerated state plus a timestamp survive.

## Queue cell

- Shows where `dev/TODO/queue.md` stands, for a repo that has one (none, no cell; nothing is ever an error). Band: `queue 44 = 30r 6h 3x` (ready, held, epic; `2c` claimed, `12v` revisited and `2a` auto-parked are appended only when above 0), squeezed to `queue 30/44` and dropped early when the row is tight. In AP-on mode it sits right after the AP and 24h cells. `/hud details` spells it out in full on its own line right after the AP line: `queue 44 = 30 ready | 6 held | 3 epics` (plus `| 2 claimed | 12 revisited | 2 auto-parked` when above 0; it is never abbreviated there; too wide for the terminal means cut with an ellipsis). Add or remove it with `fields` (`queue`).
- Source (`queue.source`, see "Config"): by default the cell reads `queue.md`, the task files and `dev/EPICS` from the repo's default branch on origin, so a clone that is behind still shows what GitHub has (the old working-tree read showed one clone 72 commits behind with 12 claimed where origin/main had 6). With `"queue": { "source": "working-tree" }` it reads THIS clone's working tree as it is on disk instead (it then shows its own, possibly stale, numbers).
  - Git object reads only (`git archive` of `origin/<default>` into a throwaway temp dir): no checkout, no index or working-tree write, no change to your branch. The default branch is `refs/remotes/origin/HEAD`, else (only when that ref is absent) `origin/main`, else `origin/master` (no `gh`). The fetch does not rewrite `.git/FETCH_HEAD` (git 2.29+) and reads never lazy-fetch.
  - Same bucketing and counts as below (ready, held, epic, claimed, revisited, autoparked); the rule "claimed by a clone other than this one or the autopilot's clone" is unchanged, and so are the autopilot-state counts (they come from this clone's `dev/.autopilot-state.json`). The task claimed by THIS clone in the band's task cell still comes from the working tree.
  - Label: the band reads `queue@main 44 = 30r 6h 3x` (the real default branch name, `@trunk` for a `trunk` default), details `queue (main) 44 = 30 ready | ...`. Opt-in working-tree mode: `queue 44 = ...`.
  - Freshness: a `git fetch origin <default>` at most every 2 minutes, detached (never blocks the poll), 15 s timeout, no credential prompt (`GIT_TERMINAL_PROMPT=0`, ssh `BatchMode`), silent when offline. It only runs when a `dev/TODO/queue.md` exists in the working tree or in the local `origin/<default>` tree: a repo without a queue costs no fetch, no temp dir and no archive per poll, and a queue that exists only on origin and in neither local tree appears once something (your own `git fetch`) brings it in. Your own `GIT_SSH_COMMAND` or `core.sshCommand` is kept (BatchMode is appended). A narrow or `--single-branch` clone whose `remote.origin.fetch` does not map the default branch is not refreshed, and a repo that `export-ignore`s `dev/` in `.gitattributes` has no readable `dev/TODO` (both end in the marked fallback or the last fetched state). The stamp lives in `${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-queue/`; the fetch only updates `refs/remotes/origin/<default>` inside `.git`. The answer shown is always the last fetched `origin/<default>`, so the first poll after a change can be one refresh old.
  - Fallback: no `origin`, or no readable `origin/<default>` ref (or no `dev/TODO` on it): the working tree is read and the cell says so (a local-only repo with a queue, or a queue not yet pushed, therefore shows this label by default), `queue@wt 44 = ...` (details `queue (working tree, origin unavailable) 44 = ...`). A default branch that has `dev/TODO` but no `queue.md` shows no cell, like any repo without a queue.
  - Helper JSON: `queue` gains `source` + `branch` (default-branch mode) or `source: "working-tree"` + `fallback: true`; the explicit working-tree opt-in adds nothing. The mod passes `queue_source` on stdin to `hud-data.sh`; absent, unknown or malformed input means `default-branch`.
- Deterministic (no LLM): one `awk` over the queued task files plus one `jq` per poll, in `sl-queue-json` (`hud/scripts/hud-lib.sh`); helper JSON key `queue` = `{total, ready, held, epic, claimed, revisited, autoparked}`. `total` is the number of task lines (`- [T<id>](file.md)`; struck-through lines are not tasks).
- Every task is counted in exactly ONE of ready, held, epic and claimed, first match wins, so those four always add up to `total`. Everything is read from the task files; nothing is derived from any marker text and the autopilot keeps no skip list (T20261102-296642):
  1. epic: the frontmatter has a `children:` key, the task is the parent of a `dev/EPICS/E*.md` epic (opt-in: add a `Parent design task: [T<id>](...)` or `Parent: T<id>` line to the epic file; only the first id on that line counts), or it carries a deliberate uppercase marker (title starts with `EPIC` or contains `— EPIC`; status contains the uppercase word `EPIC`). Free-text `umbrella` / `epic` / `tracking task` is not a signal (it misfires on product terms and prose). Plain members of a `dev/EPICS` epic are ordinary tasks and stay takeable.
  2. held: a status the HUD counts as not takeable: `Blocked by T<id>` while that task is still in `dev/TODO/`, `BLOCKED` or `SUPERVISED` (case-sensitive), or `needs manual` / `sign-off`. This is the HUD's stricter display rule; the autopilot's own gate (`todo-gated`) also skips case-insensitive `blocked` words and a resolved `Blocked by`, so `ready` can include a task auto-pick skips. Free text such as "upstream" or "needs owner decision" is no longer a signal: those tasks count as ready, because the autopilot would take them.
  3. claimed: `claimed_by:` is set to a clone other than this one or the autopilot's dispatch clone. It is its own bucket so ready stays honest; it is shown only when above 0.
  4. ready: the rest, what the autopilot can take. A queue line whose task file is missing counts as ready.
- The autopilot's `dev/.autopilot-state.json` is read only while it is `on` or `paused`, and only for the dispatch clone path (so the dispatch clone's own claims are not counted as someone else's). From the same file it takes two extra counts that are not buckets: `revisited` (queued tasks the autopilot visited without progress, the state's `visits` above 0; a task no longer queued is not counted) and `autoparked` (tasks the autopilot parked since this run started, the state's `parked` entries at or after `run_started_at`, which a pause does not shift, else `started_at` for an older file; named `autoparked` so it is not confused with the job ledger's `parked N`). An older state file's `skip_ids`/`needs_attention` and a 5.9.0 file without `visits`/`parked` count as zero.

### Queue high watermark

- What: the largest queue length (task lines of `dev/TODO/queue.md`) ever seen, for three rolling windows: last 180 days, last 30 days, last 7 days (there is no lifetime figure any more). Band: `queue@main 44 = 30r 6h 3x · max 90 180d / 61 30d / 52 7d`; details append `max 90 180d / 61 30d / 52 7d` (after a `|`) to the queue line.
- Narrow terminals: the cell shrinks in steps before anything else is touched: `· max 90/61/52` (order 180d / 30d / 7d), then no watermark, then `queue 30/44`.
- Colour: the `max` text is dim; it turns warning-coloured while the queue is at its 180-day high. The numbers are nested (180d >= 30d >= 7d >= current length); the mod enforces that, and a watermark missing any of the three numbers is not drawn.
- No queue file, no cell, so no watermark. A repo with a queue but no history yet shows the current length in all three windows until the backfill lands.
- Two series feed it, keyed by repo root + queue path (state under `~/.claude/state/hud-queue`, honours `CLAUDE_CONFIG_DIR`, files `hist-<key>`, `samples-<key>`; a `max-<key>` file from an earlier version is ignored); `sl-queue-hwm` in `hud/scripts/hud-queue-hwm.sh`, called from `hud-data.sh`:
  - History (backfill): one `git log --first-parent -p -U0` pass over the queue file of the DEFAULT branch (`origin/<default>`, else a local `main`/`master`, else `HEAD`), regardless of `queue.source`. It counts `- [T...](` lines added and removed per commit, so every commit gives a (time, length) point and 180d, 30d and 7d are known from day one (the pass reads the whole file history, so the 180-day window is complete from the first run). Detached, at most once an hour (stamped before the attempt), incremental when the old tip is an ancestor of the new one, full rebuild otherwise; a git failure or timeout (60 s) keeps the previous series. It reads local objects only and never fetches (the existing queue fetch keeps `origin/<default>` fresh in default-branch mode).
  - Samples (live): each poll appends `epoch<TAB>length` when the length shown differs from the last sample, so peaks between commits (and unpushed working-tree edits in working-tree mode) are caught. Append-only and size-capped (20000 lines by default): past the cap, rotation first drops samples older than 180 days (keeping the newest of them, the value in force at the window start), and only when that is not enough the oldest half.
  - Window maximum: the value in force at the window start counts (a queue that was 40 until 2 days ago and is 20 now still has a 7d max of 40), plus every point inside the window, plus the current length.
- The render path is fast: the poll reads two small local files and one `sort | awk`; the git pass is detached and never blocks. Test hooks: `HUD_HWM_SYNC=1` (backfill in the foreground), `HUD_HWM_TTL`, `HUD_HWM_SAMPLE_CAP`, `HUD_HWM_NOW`.
- Helper JSON: `queue.hwm` = `{"d180","d30","d7"}`, absent when unknown.

## Nightly cell

- What: the SynxDB nightly at a glance. Band: `nightly +-++.-+ · 30d: 16✓ 14✗`. The strip is the last 7 UTC days, oldest to newest, one character per day (the last one is today): `+` green day (green), `-` red day (red), `.` a day with no completed nightly run (dim). `30d: 16✓ 14✗` counts the last 30 days (today and the 29 before): `16✓` green days (success colour), `14✗` red days (error colour); a zero count is dim. The glyphs `✓` `✗` stay with `NO_COLOR` (only the colour drops). A cache written before the green count existed has no green number and shows `30d: 14✗` until its next refresh (30 minutes). When the row is tight it shrinks, in this order, after the queue cell has shrunk: `nightly +-++.-+ 16✓ 14✗`, then `nightly +-++.-+`, and the cell is dropped only after the queue cell is dropped (the strip and the counts outlast the queue cell). It sits right after the queue cell. Add or remove it with `fields` (`nightly`). `/hud details` repeats it on its own line in full, right after the CI line: `nightly +-++.-+ (last 7 days) · last 30 days: 16 green ✓ / 14 red ✗`.
- Source: `gh run list` for the nightly orchestrator workflow, `Nightly Orchestrator` in `Synx-Data-Labs/synxdb-build-pipeline` (scheduled runs only, `--event schedule`, the latest 100), in `hud/scripts/hud-nightly.sh`. The repo and workflow can be overridden with `HUD_NIGHTLY_REPO` and `HUD_NIGHTLY_WORKFLOW`; `HUD_NIGHTLY_OFF=1` turns the lookup off. Without access to that repo `gh` fails and the cell is simply absent.
- Counting, per UTC day: a day is GREEN when every nightly run of that day concluded success (the whole 24 hours were green); a day is RED when at least one run of that day concluded `failure` or `timed_out`, even if a later run that day succeeded. Cancelled, skipped and still-running runs are ignored; a day with no counted run is neither (a `.` in the strip, in neither count). The counting is the pure function `sl-nightly-count` (a JSON list of runs in, `{red, green, strip}` out; no clock, no network).
- No data (no day of the last 30 has a counted run, `gh` missing, signed out, offline, no access): no cell, and nothing is ever shown as an error.
- Never blocks the band: like the CI cell, the helper answers from an on-disk cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-nightly/`) and starts one detached refresh when it is older than 30 minutes (`HUD_NIGHTLY_TTL`, seconds), 10 s timeout, lock dir. The strip is computed when the cache is filled, so after UTC midnight it is up to one refresh (30 minutes) behind. A failed refresh keeps the older answer and is not retried before the next 30 minutes. The JSON from `gh` is untrusted: only two counts and a 7-character `+-.` strip survive.
- Test hooks: `HUD_NIGHTLY_SYNC=1` (refresh in the foreground), `HUD_NIGHTLY_STATE_DIR`, `HUD_NIGHTLY_NOW` (fake epoch). Helper JSON: `nightly` = `{"red","green","strip"}` (`green` absent in an older cache), `null` when unknown.
- Cell missing? Check, in order: (1) an explicit `fields` list in `ccxp-hud.json` (user or project file) that does not name `nightly` hides it (the default list has it; no `fields` key = shown); add `nightly` to the list. (2) The helper has no data: `gh` cannot read `Synx-Data-Labs/synxdb-build-pipeline` or has no scheduled run in the last 30 days (`gh run list --repo Synx-Data-Labs/synxdb-build-pipeline --workflow "Nightly Orchestrator" --event schedule`), or `HUD_NIGHTLY_OFF=1` is set. (3) Width: the cell is dropped only after the queue cell, but on a very narrow terminal both are gone. (4) A plugin update needs `/reload-plugins` (or a restart of the session) before the new cell code runs; the cache file under `${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-nightly/` shows what the helper last saw.

## Version cell

- Shows the installed ccxp-skills version, last in the band, compared with the latest public release:
  - same version: `ccxp 5.1.1 (latest)`, "(latest)" in the `success` colour; narrow: `ccxp 5.1.1 ✓`, then dropped (like the plain form).
  - a newer release: `ccxp 5.1.1 (5.2.0 available)`, the new number in the `suggestion` theme colour (stands out, not loud); narrow: `ccxp ↑5.2.0`, then `↑5.2.0`. The update form is kept almost to the end.
  - latest unknown (lookup not done yet, offline, no tag) or installed newer than latest (dev/prerelease): plain `ccxp 5.1.1` (dim), dropped first when the row is tight. "latest" is never claimed without a successful comparison.
  - `/hud details` shows the same text (the full form) on its last line, next to the `you` stamp, followed by the plugin's GitHub location as a bare URL (`https://github.com/Synx-Data-Labs/ccxp-skills`) so a terminal can cmd/ctrl-click it. The URL is the `repository` (else `homepage`) of the plugin's own `plugin.json`, read by the helper; the public URL above is the fallback. It is plain text, not an OSC 8 hyperlink (the renderer draws text only). The one-row band never shows it.
- Installed: the running plugin's own `.claude-plugin/plugin.json` (the helper's install dir), a local read.
- Latest: the highest plain `ccxp-skills--vX.Y.Z` tag of the public Synx-Data-Labs/ccxp-skills repo, via `git ls-remote --tags` in `hud/scripts/hud-version.sh` (no credentials, no `gh`). Prereleases are ignored. Newer/same/older is decided by numeric semver (5.10.0 > 5.9.0), never by string compare. The helper reports the highest known tag as `latest` whatever its relation to installed; the mod picks the wording.
- Same pattern as the CI cell: answers from a cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-version/`), at most one detached refresh per 6 hours (8 s timeout, no credential prompt). Offline or git missing: the cached answer is kept, the next try is about 15 minutes later, and the cell shows the last known answer (or the installed version alone when there never was one). Only strings matching the tag pattern are ever drawn.
- Squeezing: the plain `ccxp X` goes right after the last-input cell; the update marker is kept almost to the end. `/hud details` shows it on the last line next to `you` and never abbreviates it: on a narrow terminal the URL goes first, then the line is cut at the width with an ellipsis (no `✓`/`↑` short label). A short terminal that caps the detail lines below the line count cuts the last line, which is this one.
- Turn it off: `"version": false` or `/hud config`.
- An update is picked up by `/plugin` (reinstall or update); the cell is information only and changes nothing.

## `/hud config`

- Renamed from `/hud setup` (breaking: `/hud setup` no longer exists and there is no alias). `/hud fill on|off` was removed too: the fill is always on.
- Asks (through the engine's question dialog; type values under "Other"):
  - one CI answer: "Paste a GitHub Actions workflow URL (repo and workflow are derived from it), or none to hide CI." Accepted: `https://github.com/<org>/<repo>/actions/workflows/<file>.yml` (optionally `?query=branch%3A<b>`, which then pins that branch), `https://github.com/<org>/<repo>/blob/<branch>/.github/workflows/<file>.yml`, or a bare workflow file name (repo = the session's repo). Also accepted: `tree/` and `raw/` forms of the file URL, a scheme-less `github.com/...`, and the answer wrapped in quotes, backticks or angle brackets or padded with spaces/newlines. `/hud config <url>` supplies this answer up front and skips the question (the dialog headers stay within the engine's 12-character limit). `none`, `no`, `-` or blank hides CI. A run URL (`.../actions/runs/<id>`) is refused because it does not name the workflow. No branch or repo question: the branch is the repo's default unless the URL names one
  - fill colour: gray (default), blue or green as options; yellow, purple or a `#rrggbb` hex typed under Other (the engine's dialog takes at most 4 options per question)
  - ccxp-skills version cell: show (default) or hide
  - queue source: "Queue source: default branch (the default and recommended) or working tree (opt-in)" (see "Queue cell"; header `Queue source`, 12 characters). `default branch (recommended)` writes `"queue": {"source": "default-branch"}`, `working tree` writes `"working-tree"`; any other answer leaves the key as it is
  - scope: user file or this project's `.claude/ccxp-hud.json`
- An invalid CI or colour answer never aborts the dialog: it is asked again once (naming the rejected value, with an example URL for CI); after a second invalid answer that setting is left unchanged and the dialog carries on, so the colour and scope questions are always reached.
- Shows the resulting `"ci"`, `"fillColor"`, `"version"` and `"queue"` values and the file, and writes only after you pick `write`. Only those four keys are merged in (a skipped one is not touched); other keys are kept. Nothing is written on an explicit cancel or a dismissed dialog ("ccxp-hud config cancelled; nothing written.", with the dialog's reason when it gave one); any other exception reports "ccxp-hud config failed: <reason>; nothing written."

## Fill

- Always on: the band is padded with spaces to the band's width and drawn on a background, so it reads as a solid bar apart from the rest of the output. One row, two with CI (or the detail lines under `/hud details`). A red CI row ignores the fill colour and is drawn in reverse video.
- Width: the engine's `bodyColumns` for the band (the terminal, or the transcript's column beside a docked pane, less the five columns the engine keeps for its `[-]` mark), so the bar ends just before that mark. The band is redrawn by the engine when the width changes.
- Measured in display columns (`hud/fill.ts`): emoji and CJK count 2, combining marks and joiners 0, ANSI codes 0. Content wider than the bar is cut with an ellipsis before padding, so a row never exceeds the width.
- Colour (`fillColor`, default gray) follows the `/config` theme: each named colour has a muted dark tint for `dark*` themes and a pale tint for `light*`, so the cell colours (CI, AP, jobs) stay readable on both. Any other theme (auto, unreadable) uses reverse video. A custom `#rrggbb` is drawn as given on every theme (pick one that suits your terminal). An invalid value means gray.
- Falls back to the plain unfilled row when the width is unknown or under 40 columns. `fillColor` is a plain config key: a project file's value wins over the user file's.

## `/hud details`

Toggles the band between the compact view and up to seven detail lines, eight with a CI row (this session only; a new session starts collapsed). **Details is a superset of the band**: every cell the one-row band can show (repo and branch, task, AP and its 24h cell and stalled state, ctx, jobs, queue, nightly, CI, last input, version, rate, cost, stale) has its full-form counterpart in a details line, plus the extra detail; a test (`hud/pure.test.ts`, "details is a superset of the band") pins it, so a new `fields` entry (or a band cell added to that test's list) cannot ship without one. On a narrow row the nightly cell outlasts the queue cell. It is the same band, so it refreshes live with it (the 15 s poll, each finished turn, `/cd`, and context/cost measurements) and adds no extra `git` or `gh` calls. It ignores `fields` and needs `band` on (otherwise `/hud details` says so).

| Line | Shows |
|---|---|
| 0 CI | `CI (workflow) ✓ passing 10-28 (2h ago)` first and alone (only when `ci` is set); a failing run is drawn as the red bold reverse-video row, as in the band (`✗ FAILING` with `NO_COLOR`) |
| 0b nightly | `nightly +-++.-+ (last 7 days) · last 30 days: 16 green ✓ / 14 red ✗` (the band's nightly cell with its labels in full; `16 green ✓` in the success colour, `14 red ✗` in the error colour, a zero dim; a cache from before the green count shows only `14 red ✗`). Right after the CI line (first when there is no CI row), so the two build-health signals read together. No nightly data (no `gh` access to the repo), no line; see "Nightly cell" |
| 1 where | `owner/name @ branch*` plus worktree, account and `(root: X)` as in the repo cell, then the claimed task `T<id> title` |
| 2 usage | spelled out: `context 64% left ▓▓▓▓▓▓░░░░` (same colours as the band; the band's `ctx` is context LEFT), `5-hour limit 35% left · runs out in 1.5h` (share of your Claude subscription's rolling 5-hour usage window still LEFT, from the engine's `rate_limits`; coloured red under 10% left, orange under 25%, otherwise green. The runout estimate is burn rate so far (used % / time elapsed in the window) projected to 100%, shown as `1.5h` or `40m` only when it lands before the window resets, and omitted at 100% used, with under 1% used, under 2 minutes elapsed or no reset time from the engine; hidden entirely when the engine reports no limits, e.g. API-key use. The band's `rate` cell is `5h 65% left · out 1.5h`, dropping the runout first when narrow. Only the 5-hour window is read; the 7-day window is not shown), `API-equivalent cost $693.75` (the engine's running estimate of this session's token usage at API list prices, `cost.total_cost_usd`; NOT what a subscription bills) |
| 3 jobs | `READY` / `WORKING (N)`, `parked N`, `last 24h: jobs 8 ▲ / average 5.2/day` (from the ledger; no ledger, no line; see "Jobs 24h cell"; there is no total-jobs figure). The running jobs are not listed: the status already shows them. `parked N` is the length of the ledger's `parked` array (contexts are not shown here) |
| 4 autopilot | `AP on 2h …` (`AP idle 2h …` when idle, `AP ⏸ paused 2h …` when paused, `AP off` when off or none), then the next-loop cell, then the 24h cell (which ends in the average): `AP on 2/6h 3 loops ✓2 merged │ next loop 14:32 (in 12m) │ last 24h: 8 merged ▲ / 26 loops · average 5.2/day`. The next-loop cell is `next loop 14:32 (in 12m)` from the state file's `next_wake_at`; `next loop paused` when paused; `next loop due` while the wake time has passed by no more than 10 minutes (a wake may run a little late); nothing when absent; while a cycle runs (the state file's `busy_since` is set) it shows `running r596` instead, the highest-numbered running ledger row flagged `autopilot` (the dispatcher starts the cycle with `ledger.sh start <n> "autopilot cycle" --flags autopilot`), or plain `running` when no such row exists. With parallel cycles (`max_dop` above 1; the state file's `slots`, helper field `busy_slots`) it names every running cycle, the highest-numbered flagged rows in ascending order: `running r596,r597`; with one cycle it is unchanged. Past the 10-minute grace the loop is not "due" but stalled: the cell turns warn-coloured and says how late it is, with no wake time shown as if it were upcoming (`next loop overdue 25m`, `next loop overdue 3h 5m`, `next loop overdue 2d 16h`). Paused and running are never reported as overdue, however old the stored time is |
| 5 queue | on its own line right after the AP line: `queue 44 = 30 ready \| 6 held \| 3 epics` (then `\| max 90 180d / 61 30d / 52 7d` when the watermark is known, see "Queue high watermark") (`queue (main) 44 = ...` in default-branch mode; `\| 2 claimed`, `\| 12 revisited`, `\| 2 auto-parked` appended when above 0; a count of 1 reads singular, `1 epic`; same colours as the band; see "Queue cell"). No `dev/TODO/queue.md`, no queue line. There is no `\|\|` between AP and queue any more |
| 6 you | `you HH:MM (5m ago)`, the last prompt (needs the last-input hook), then the version label and plugin URL |

- Details never abbreviate a label. Every cell is drawn in its full form (`context`, `5-hour limit`, `API-equivalent cost`, `last 24h: jobs … average`, `next loop`, `last 24h … average`, and `ready` / `held` / `epics` / `claimed` / `revisited` / `auto-parked`, never `ctx`, `5h`, `r h x` or `queue 30/44`), and a line still wider than the terminal is cut at the width with an ellipsis. The only whole-cell drop is the plugin URL on the last line (a half-cut link is useless), which goes before that line is cut. The short forms belong to the one-row band.
- Lines with nothing to say are left out and none is reserved: AP off with no queue data, no nightly data and no ledger shows only where / AP / you. The line count is therefore at most seven (nightly right after CI, then AP, queue and the others present), eight with a CI row. The height is capped at the engine's `maxRows`.
- The VS Code compact status line stays one line.
- The retired `/hud pane` is not an alias: it prints the usage line.

## Notes

- Needs Claude Code 2.1.287 or newer (mods on by default); the mod API is early access and may change.
- Data comes from `hud/scripts/hud-data.sh --json` (bash; keeps the claimant secret out of the mod). The only network use is the cached, detached CI lookup above (and only when `ci` is set), the cached, detached version lookup (`git ls-remote`, at most every 6 hours, only while `version` is on) and, unless `queue.source` is `working-tree`, and only while a queue exists, the cached, detached `git fetch origin <default>` (at most every 2 minutes); no model or MCP calls.
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
- Decisions: `ledger.sh decision add|supersede|retire|list|show` keeps the owner's standing decisions in `ccxp-decisions.json` (rendered `ccxp-decisions.md`) next to the ledger; `reply`/`render` add a `Decisions:` line before `Ledger:` when any is active (`reply --no-decisions` omits it). See `agent-pairing/decisions.md`.
- Authorization: `ledger.sh authz list|show|set` keeps a yes/no list per capability (`customer_visible_posts`, `tagging`, `pushing_artifacts`, `github_issues_update_close`, `gitlab_issues_update_close`, `delete_data`, `secret_handling`, `spend_money`, `third_party_messages`, `admin_or_bypass`, `install_software_outside_repo`, `owner_accounts_credentials`, `unlisted_other`) in `ccxp-authz.json` (mode 600, atomic) next to the ledger. Everything is `no` (ask) until the owner sets it: `ledger.sh authz set tagging yes --quote "<owner's words>"`. Once the file exists, `reply`/`render` and `ccxp-ledger.md` show an Authorization section after Parked. The ccxp-agent reads it before dispatching a job (`agent-pairing/assets/ccxp-agent.md`, "Consent comes before dispatch").
- Context: every running, next and parked item needs a context file path; `reply` shows `context: MISSING` and `next add`/`park` warn without `--context`. A Next item's file is named `n<k>-<slug>[-T<taskid>].md` (`next add` warns on stderr when it is not; see `scripts/ledger.md`, "Context file naming").

The job ledger writer is `hud/scripts/ledger.sh` (calls in `hud/scripts/ledger.md`). It also keeps what a restart needs to resume running jobs (`reconcile`, `resumed`; see the Resume section there). Tests for the bash layer: `bats tests/hud_lib.bats tests/hud_data.bats tests/hud_ci.bats tests/hud_version.bats tests/hud_queue_source.bats tests/last_input_hook.bats tests/ledger.bats`.
