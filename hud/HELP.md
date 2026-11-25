## overview

The band above the prompt is a row of cells, separated by `│`. Each cell answers one question; a cell with nothing to say is left out, so a short band is a quiet band. Colours are theme colours: green = fine, yellow = needs a look, red = broken or waiting for you, dim = background information. A solid red row (reverse video) is the loudest signal: something failed and nobody has taken it on. With `NO_COLOR` the colours go but the marks (`✓ ✗ ▲ ▼`) stay.

Try `/hud help <topic>` for one cell, `/hud config` for what is switched on and where each setting comes from, `/hud details` to expand the band into labeled sections (run it again to collapse).

Every number comes from local files or a cached, background lookup (`git`, `gh`); the band itself never waits on the network.

## repo | branch, worktree

Which repo you are working in: `owner/name @ branch ↑2 ↓134*`. It follows `/cd`.

- `↓N` = commits your branch is BEHIND its remote, `↑M` = commits it is AHEAD (only shown above 0; nothing at all when level, on a detached HEAD, or outside a repo). `↓` is neutral (dim) under 20 and yellow from 20; `↑` is always neutral.
- Compared with the branch's upstream (`@{u}`); with no upstream set, with `origin/<default branch>` instead. A narrow band drops `↑` first, then the whole indicator.
- It reads the remote-tracking branch already on disk, kept fresh by one background `git fetch origin` (at most every 5 minutes per repo, 15 s limit, no prompts; it only moves remote-tracking refs, never your branch or files). A failed fetch keeps the last number. Set `HUD_BEHIND_FETCH=0` to turn the background fetch off.

- `*` (yellow) = tracked files changed in the working tree. Untracked files are not counted.
- `(wt X)` = you are in a linked git worktree; `(account)` = the `gh` account of this directory; `(root: X)` = a shell `cd` moved you out of the session root; a leading `→` = the repo changed a moment ago.
- Source: `git` in your current directory, local only. Shown when autopilot is off (AP-on rows show the AP cell instead). Switch: `repo` (and `branch` when `repo` is not listed) in `fields`.

## task

`T<id> <slug>`: the task this clone currently holds (claimed in `dev/TODO`). No claim, no cell. Source: the working tree's `dev/TODO` claim. Switch: `task`.

## ap | autopilot

The unattended `/drive` loop (`/autopilot`). Example `AP 2/6h 3 loops ✓2 merged`: running 2 hours of a 6 hour request, 3 loops done, 2 merged.

- `⏸ paused` (yellow) = paused with `/autopilot pause`. A quiet word in yellow (idle, capped) = on, but nothing to do right now or a daily cap was hit. `⚠N` (red) = N loops in a row got stuck.
- Narrow terminals shorten it to `AP 2/6h 3L ✓2`.
- Source: `dev/.autopilot-state.json` of this repo. No autopilot state or `off`: no cell. Switch: `ap`.

## ap24h | 24h, progress

The autopilot's last 24 hours (a rolling window, not a calendar day) against its lifetime average per day: `last 24h: 8 merged ▲ / 26 loops · average 5.2/day`.

- Green `▲` = more merged than the average, red `▼` = fewer, no arrow = equal at one decimal.
- `~8` = an estimate (the history log is younger than 24 hours); an estimate never gets an arrow.
- Source: `autopilot-state.sh stats` over `dev/.autopilot-history.jsonl`. Shown with AP on. Switch: `ap`.

## dop | max_dop | parallel

The autopilot's parallelism, so you can see the current config: `dop 8/16` = 8 cycles running out of `max_dop` 16.

- Neutral colour normally; yellow when the running routine cycles are at the routine limit (`max_dop` less the reserved slots, all of `max_dop` while there is no reserved key; urgent cycles run in the reserved slots and are not counted against it, though they are in the number shown) or when every slot is taken (`running` has reached `max_dop`): the cases where the autopilot can start no routine cycle. `dop 8/6` after lowering `max_dop` under live cycles stays yellow until they finish.
- `/hud details` spells it out on the first AUTOPILOT line: `max_dop 16 (14 routine + 2 reserved) · 8 running`, and `(limit lowered)` when more cycles run than `max_dop` allows. With the autopilot off but a config file present it shows the dim configured value: `max_dop 16`.
- The reserved part comes from the autopilot's `reserved_slots` setting (default 2); with an older autopilot script that does not report it, `max_dop` is shown alone, e.g. `max_dop 16`.
- A narrow terminal drops it whole (after the AP cell is at its shortest form, before the ctx cell). Silent with the autopilot off and no config file.
- Source: `autopilot-state.sh config-show --json` (the effective value, default or override, from `dev/.autopilot-config.json`) and the number of busy slots in `dev/.autopilot-state.json`. Shown with AP on. Switch: `ap`.

## stalled

Red `stalled 2d`: the autopilot should have woken up more than 10 minutes ago and has not (it is not paused and not mid-cycle). The number is how long it is overdue (largest unit). Nothing shows inside the 10 minute grace. Source: `next_wake_at` in the autopilot state.

## ctx

Context LEFT in this session, as a percent and a bar: `ctx 64% ▓▓▓▓▓▓░░░░`. Green above 75, yellow above 50, red at 50 or less (the limits `ctxWarn` / `ctxCrit` in the config). Low context means the session will soon need to be summarised or restarted. Source: the engine's own usage figure. Switch: `ctx`.

## jobs | ready, working

Background jobs from the job ledger: green `READY` = no job is running, yellow `WORKING (N)` = N jobs running now. Source: the ledger file `hud/scripts/ledger.sh` writes (`ccxp-ledger.json` in the profile dir), not the engine's agent list. No ledger, no cell. `/hud details` adds `parked N` and a 24 hour job count. Switch: `jobs`.

## queue

Where `dev/TODO/queue.md` stands: `queue 44 = 30r 6b 3x` = 30 ready to take, 6 blocked (`Blocked by` an open task), 3 epics. `2c` claimed by another session appears only when above 0. Tasks the autopilot holds are not counted here: the AUTOPILOT row in `/hud details` shows `2 held by autopilot`. After it, `max 61/74/83 ▲` is the largest queue length in the 4 weeks before last week (14 to 42 days ago), last week (7 to 14 days ago) and this week (the last 7 days); `▲`/`▼` compares this week with last week, `-` means no history that old, and it turns yellow while the queue sits at the highest of the three. Narrow: the max drops first, then `queue 30/44`. Read from the default branch on origin (no checkout), or from the working tree with `queue.source`. No `queue.md`, no cell. Switch: `queue`.

## nightly

The nightly build at a glance: `nightly +-++.-+ · 30d: 16✓ 14✗`. One character per UTC day, oldest to newest, last = today: `+` every nightly that day succeeded, `-` at least one failed or timed out, `.` no finished run. `30d` counts green and red days over 30 days. Source: `gh run list` for the `Nightly Orchestrator` workflow (scheduled runs), cached 30 minutes. No access or no data: no cell. Switch: `nightly`.

## issues

Customer issues, opt-in: `issues 12 open / 7 undelivered · max 18 180d / 15 30d / 12 7d` = open issues, open ones without the `status:delivered` label (yellow while above 0), and the highest open count in the last 180 / 30 / 7 days. Needs `issues.repo` in the config. Source: one cached `gh issue list`, refreshed every 15 minutes. Switch: `issues`.

## ci | red-ci, unhandled, unhandled-ci

The one CI the HUD shows: the newest run of the configured workflow (normally the Nightly Orchestrator), alone on a top row: `CI (Nightly Orchestrator) ✗ failing 10-28 (2h ago)`. No other workflow is shown (owner decision d143: "we only need one CI"; drill down manually for more).

- Green `✓ passing`, yellow `◐ running` (with `ETA 18:40` when enough history exists, or `over usual (4h)` when it runs long), grey `? unknown` (cancelled, skipped), red `✗ failing` (also timed out): the whole row becomes a solid red bar that ends with the address of the failed run.
- Red means the configured workflow's newest run failed, whichever stage or job inside it broke.
- Date = the run's day (`MM-DD`), then its age.
- The old cell `✗ N unhandled CI (names)` is gone. It counted failed runs of any workflow on the default branch or a schedule whose run id was in no open task, no job context file and no ledger entry (so nobody was investigating it). Its list is still available by hand: `bash hud/scripts/hud-redci.sh list [owner/name ...]`.
- Set it with `/hud config edit` (a workflow URL) or the `ci` key; no `ci`, no row and no `gh` call. Source: one cached `gh run list --workflow` (refreshed about every 2 minutes). The first result can take a couple of minutes. Switch: `ci`.

## bus | notes

Unread notes from another Claude Code session (another account or profile) on this machine: `bus 2 · home` (yellow) = 2 unread, newest from agent `home`. Narrow: `bus 2`. Nothing shows while nothing is unread, or when no bus is set up for this profile. Source: local files only (`_bus/bus.sh status --json`: the inbox size against your saved read position). Read them with `/bus`. Switch: `bus`.

## version | ver

The installed ccxp-skills version against the latest public release. `ccxp 6.4.0 (latest)` = up to date (green). `ccxp 6.4.0 (6.5.0 available)` = a newer release exists; update with `/plugin`. Plain `ccxp 6.4.0` (dim) = latest unknown (offline, not looked up yet). The cell never claims "latest" without a successful comparison. Source: the plugin's `plugin.json` and `git ls-remote --tags` of the public repo (no credentials), cached 6 hours. Hide with `"version": false`.

In `/hud details` the RELEASE row shows the plugin's GitHub address first (clickable), then the version label, then how many commits `main` has after the release you run: `5 unreleased` (a number only, never the commit titles). Nothing shows when there are none, the release tag is unknown, or you are offline. Source: one anonymous GitHub request, cached 1 hour.

## lastat

`you 09:05`: when you last submitted a prompt in this session (the date is added when not today). Needs the small UserPromptSubmit hook `hud/scripts/last-input-hook.sh`; without it the cell stays hidden. Switch: `lastat`.

## rate

Opt-in: how much of your Claude subscription's usage window is left, when it would run out at your pace, and when it resets, e.g. `20% left · runs out in 28m · reset 13:55 CST`. It shows the window that runs out first (the 5 hour or the 7 day one), without saying which; a window that would not run out before its own reset ranks last, and when neither runs out it shows the one with less left. `runs out in` shows only when you would use it all up before the reset; otherwise it is left out. The colour follows the gap to the runout, in whole minutes rounded down (10m20s reads `10m`; from an hour up the text shows hours): green above 30 minutes (or when it will not run out), yellow above 10, red at 10 minutes or less. A limit Claude does not report (API-key use, older versions) is left out. When the band is tight it drops the reset time first, then the runout, then goes entirely before any other cell. `/hud details` shows the full text on the SESSION row. The HUD also saves the latest numbers, both windows, to a small file for the autopilot (`rate-limits.json` in the HUD cache folder). Switch: `rate` in `fields` (not on by default).

## colors | colours, markers

- Green = fine (`success`), yellow = look at it (`warning`), red = broken or waiting for you (`error`), grey or dim = background information.
- Solid red row (bold, reverse video) = failed CI (`ci`), the one thing meant to catch your eye.
- `▲` green / `▼` red = above / below your own average; `~` before a number = an estimate; `*` yellow after a branch = uncommitted changes; `✓` / `✗` = ok / failed; `⏸` = paused; `⚠N` = N stuck loops.
- Theme colours only, so your theme and `NO_COLOR` keep working.

## details

`/hud details` toggles an expanded view: one labeled row per section, spelling the cells out in full (never abbreviated). Run it again to collapse. It updates live like the band.

- `SESSION` context left, subscription limit left with its reset time, unread bus notes, your last prompt time
- `CLONE` the clone you work in: repo, branch, claimed task
- `BUILD` CI (red when failing), nightly
- `SUPPORT` customer issues (when configured)
- `AUTOPILOT` two lines: status (on / paused / off, `max_dop` use with running cycles, next loop or overdue), then progress (24h merged and loops, average per day, `N held by autopilot`)
- `WORK` everything the autopilot does not run: READY / WORKING counts only jobs without the `autopilot` flag, then parked and the 24 hour job count (all jobs started, autopilot cycles included). The one-row band's READY / WORKING still counts every running job
- `QUEUE` the task queue breakdown
- `RELEASE` the plugin's GitHub address, the version, and the count of unreleased commits

A row too long for the terminal wraps onto an indented line; nothing is cut. A section with nothing to say is left out.

## config

`/hud config` prints the effective configuration (read-only): the files read, each setting with its value, default and source, what is switched on or off, watched repos, refresh intervals and the cache and state folders. `/hud config edit` (or `/hud config <workflow url>`) opens the dialog that writes the `ci`, `fillColor`, `version` and `queue` keys. Settings live in `~/.claude/ccxp-hud.json` (honours `CLAUDE_CONFIG_DIR`) with an optional `<project>/.claude/ccxp-hud.json` on top; a missing or malformed file means defaults.
