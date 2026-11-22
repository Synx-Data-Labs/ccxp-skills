## overview
The band above the prompt is a row of cells, separated by `│`. Each cell answers one question; a cell with nothing to say is left out, so a short band is a quiet band. Colours are theme colours: green = fine, yellow = needs a look, red = broken or waiting for you, dim = background information. A solid red row (reverse video) is the loudest signal: something failed and nobody has taken it on. With `NO_COLOR` the colours go but the marks (`✓ ✗ ▲ ▼`) stay.

Try `/hud help <topic>` for one cell, `/hud config` for what is switched on and where each setting comes from, `/hud details` to expand the band into full lines (run it again to collapse).

Every number comes from local files or a cached, background lookup (`git`, `gh`); the band itself never waits on the network.

## repo | branch, worktree
Which repo you are working in: `owner/name @ branch*`. It follows `/cd`.
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

## stalled
Red `stalled 2d`: the autopilot should have woken up more than 10 minutes ago and has not (it is not paused and not mid-cycle). The number is how long it is overdue (largest unit). Nothing shows inside the 10 minute grace. Source: `next_wake_at` in the autopilot state.

## ctx
Context LEFT in this session, as a percent and a bar: `ctx 64% ▓▓▓▓▓▓░░░░`. Green above 75, yellow above 50, red at 50 or less (the limits `ctxWarn` / `ctxCrit` in the config). Low context means the session will soon need to be summarised or restarted. Source: the engine's own usage figure. Switch: `ctx`.

## jobs | ready, working
Background jobs from the job ledger: green `READY` = no job is running, yellow `WORKING (N)` = N jobs running now. Source: the ledger file `hud/scripts/ledger.sh` writes (`ccxp-ledger.json` in the profile dir), not the engine's agent list. No ledger, no cell. `/hud details` adds `parked N` and a 24 hour job count. Switch: `jobs`.

## queue
Where `dev/TODO/queue.md` stands: `queue 44 = 30r 6h 3x` = 30 ready to take, 6 held (blocked or waiting), 3 epics. `2c` claimed by another session, `12v` revisited without progress, `2a` auto-parked appear only when above 0. Narrow: `queue 30/44`. Read from the default branch on origin (no checkout), or from the working tree with `queue.source`. No `queue.md`, no cell. Switch: `queue`.

## nightly
The nightly build at a glance: `nightly +-++.-+ · 30d: 16✓ 14✗`. One character per UTC day, oldest to newest, last = today: `+` every nightly that day succeeded, `-` at least one failed or timed out, `.` no finished run. `30d` counts green and red days over 30 days. Source: `gh run list` for the `Nightly Orchestrator` workflow (scheduled runs), cached 30 minutes. No access or no data: no cell. Switch: `nightly`.

## issues
Customer issues, opt-in: `issues 12 open / 7 undelivered · max 18 180d / 15 30d / 12 7d` = open issues, open ones without the `status:delivered` label (yellow while above 0), and the highest open count in the last 180 / 30 / 7 days. Needs `issues.repo` in the config. Source: one cached `gh issue list`, refreshed every 15 minutes. Switch: `issues`.

## alerts
The ccxp-agent persona's Slack alert check. The persona reads the Slack failure-alert channel and records when it last did; this cell shows how long ago, so "nobody is watching Slack" is visible.
- `alerts checked 12m ago` (dim) = the persona checked 12 minutes ago, within the last 30 minutes. Past 30 minutes the same text turns yellow (`alerts checked 3h ago`).
- `alerts never checked` (yellow) = there is no record of any check: the `last-check` file (an epoch written by `agent-pairing/scripts/alerts-due.sh` each time the persona checks) is missing, empty or garbage (a future time counts as garbage). It means the check has not run on this machine, not that there are no alerts.
- `alerts held` (red) = alerts were found but held back under the per-check cap and are still waiting for a dispatch.
- Narrow: `alerts 12m` / `alerts ?`. The cell is left out when `alerts` is false in the config, `CCXP_ALERTS=0`, or this plugin version has no `alerts-due.sh`.
- Source: local files only, `${CCXP_ALERTS_DIR:-<profile>/ccxp-alerts}/last-check` and `hold`, read by `hud/scripts/hud-alerts.sh`. Switch: `alerts`.

## ci
The newest run of the configured workflow (normally the Nightly Orchestrator), alone on a top row: `CI (Nightly Orchestrator) ✗ failing 10-28 (2h ago)`. Owner decision d143 (job r1356) is making the HUD show ONE CI only, with a link to the failed run when red; this section describes that CI cell.
- Green `✓ passing`, yellow `◐ running` (with `ETA 18:40` when enough history exists, or `over usual (4h)` when it runs long), grey `? unknown` (cancelled, skipped), red `✗ failing` (also timed out): the whole row turns into a solid red bar.
- Date = the run's day (`MM-DD`), then its age.
- Set it with `/hud config edit` (a workflow URL) or the `ci` key; no `ci`, no row and no `gh` call. Source: one cached `gh run list --workflow` (refreshed about every 2 minutes). The first result can take a couple of minutes. Switch: `ci`.

## redci | unhandled, unhandled-ci, red-ci
`✗ 2 unhandled CI (Nightly Orchestrator 11-20, Upstream Sync 11-20)`: failed CI that nobody is investigating. NOTE: decision d143 (job r1356) removes this cell; this section stays only while the code still draws it, and goes away with it.
- "Unhandled CI" = a failed run, in the last 7 days, on the repo's default branch or from a schedule, of ANY workflow (not only the one in `ci`), whose run id appears in no open task (`dev/TODO`), no job context file (`ccxp-context/`) and no job ledger entry. Nothing mentions the run, so nobody is on it. Failures on PR branches do not count.
- Also dropped when a later run of the same workflow on the same branch succeeded (superseded). Manual runs (`workflow_dispatch`) on the default branch count.
- It disappears once somebody takes the failure on: the dispatcher writes the run id into the job's context file or the task. To see which runs, run `bash hud/scripts/hud-redci.sh list`: one line per run (id, workflow, event, branch, age, URL).
- Which repos: `redci.repos` in the config, else the repo of `ci`; never the session repo. Same red row as `ci`. Source: cached `gh run list` per repo, refreshed at most every 5 minutes. Narrow: `✗ 2 unhandled CI`. Switch: `ci` (shares its row).

## version | ver
The installed ccxp-skills version against the latest public release. `ccxp 6.4.0 (latest)` = up to date (green). `ccxp 6.4.0 (6.5.0 available)` = a newer release exists; update with `/plugin`. Plain `ccxp 6.4.0` (dim) = latest unknown (offline, not looked up yet). The cell never claims "latest" without a successful comparison. Source: the plugin's `plugin.json` and `git ls-remote --tags` of the public repo (no credentials), cached 6 hours. Hide with `"version": false`.

## lastat
`you 09:05`: when you last submitted a prompt in this session (the date is added when not today). Needs the small UserPromptSubmit hook `hud/scripts/last-input-hook.sh`; without it the cell stays hidden. Switch: `lastat`.

## rate
Opt-in: the 5 hour usage limit, used percent and when it would run out at the current pace. Dropped first when the band is tight. Switch: `rate` in `fields` (not on by default).

## cost
Opt-in: the session cost in dollars. Switch: `cost` in `fields` (not on by default).

## colors | colours, markers
- Green = fine (`success`), yellow = look at it (`warning`), red = broken or waiting for you (`error`), grey or dim = background information.
- Solid red row (bold, reverse video) = failed CI (`ci`), the one thing meant to catch your eye.
- `▲` green / `▼` red = above / below your own average; `~` before a number = an estimate; `*` yellow after a branch = uncommitted changes; `✓` / `✗` = ok / failed; `⏸` = paused; `⚠N` = N stuck loops.
- Theme colours only, so your theme and `NO_COLOR` keep working.

## details
`/hud details` toggles an expanded band: up to seven live lines, eight with a CI row, spelling out the cells in full (never abbreviated) plus the plugin URL. Run it again to collapse. It updates live like the band.

## config
`/hud config` prints the effective configuration (read-only): the files read, each setting with its value, default and source, what is switched on or off, watched repos, refresh intervals and the cache and state folders. `/hud config edit` (or `/hud config <workflow url>`) opens the dialog that writes the `ci`, `fillColor`, `version` and `queue` keys. Settings live in `~/.claude/ccxp-hud.json` (honours `CLAUDE_CONFIG_DIR`) with an optional `<project>/.claude/ccxp-hud.json` on top; a missing or malformed file means defaults.
