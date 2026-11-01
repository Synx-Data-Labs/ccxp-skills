---
name: autopilot
description: Use when the user explicitly asks to turn the unattended background /drive loop on or off, pause or resume it, or check its status — "/autopilot on", "/autopilot off", "/autopilot pause", "/autopilot resume", "/autopilot status"
argument-hint: "on | off | pause | resume | status"
---

While `on`, keep running `/drive` one task after another, using `ScheduleWakeup` to survive without one long turn, until `/autopilot off`. Nothing drivable → notify once, wait, try again. No standup/IPM/retro (that is `/ccxp`'s job). This skill owns the on/off/loop/pause bookkeeping, not selection, implementation or merging. Each cycle's `/drive` runs in a dispatched sub-agent, so context grows by one report per cycle.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

Exactly one of these (case-insensitive, nothing else). There is no duration argument and no resume token.

- `on` — start the loop, or (when already on) run the next cycle if one is due. See Phase 1.
- `off` — stop the loop and remove the dispatch clone. Phase 0.1.
- `pause` / `resume` — stop dispatching but keep the clone and state / continue. Phase 0.1.
- `status` — read-only report. Phase 0.

Anything else (including a leftover pre-redesign wake such as `/autopilot until <ISO> stuck=<n>` or `/autopilot 6h`): run Phase 0's report, say the command is not supported, and do nothing else. A state file from the old design (no `"schema": 2`) reads as `off`.

## Helper and files

All state arithmetic lives in `<skills-root>/autopilot/scripts/autopilot-state.sh` (unit-tested in `tests/autopilot_state.bats`); call it instead of editing JSON by hand. Run it with `bash`, one command per call.

- `dev/.autopilot-state.json` (gitignored, schema 2) — the loop's source of truth. Fields: `status` on|paused|off, `started_at`, `paused_at`, counters (`cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `*_today`), `last_outcome`/`last_task`/`last_stuck_reason`, `next_wake_at`, `busy_since`, `current_task` (the task id the busy cycle drives; set by `busy on T<id>`, cleared by `busy off`/`record`; informational only, the HUD names the cycle by its ledger job instead (`running r<n>`); optional, 5.4.0 files without it work), `dispatch_clone_path`, notify-once flags, `skip_ids`, `needs_attention` (both cleared per id by `unskip`), `notices`. Writes are atomic.
- `dev/.autopilot-history.jsonl` (gitignored, append-only) — one `{ts, outcome, merged, task}` line per `record` call (`task` is a task id or `""`; no free text, no secrets). Written by `record` itself, so nothing else logs a merge; a write failure is swallowed and never breaks `record`. It survives `off`/`start`. The state file also keeps `lifetime_started_at`, `lifetime_cycles` and `lifetime_merged`, which `start` carries over (a state from before they existed is seeded from its run counters), so `off` then `start` never resets the lifetime baseline.
- `autopilot-state.sh stats [--json]` — progress over the rolling last 24 h (merged, cycles, stuck, waiting, idle; `capped` ticks are not cycles) and the lifetime average per 24 h (`lifetime_merged / max(1, days since lifetime_started_at)`), with a trend (`up`/`down`/`flat` for 24 h merged against the average at one decimal). The 24 h figures are exact when the log reaches back over the whole window, or when no cycle ran inside it; otherwise (`approx: true`) they are the larger of the log and the state's calendar-day counters, a lower bound. Earlier work counts through the state counters, so the average is meaningful from day one. The HUD's AP band shows it as `last 24h: 8 merged ▲ / 26 loops · average 5.2/day`, green `▲` above the average, red `▼` below, no arrow when equal at one decimal (`hud/README.md`).
- `dev/.autopilot-config.json` (gitignored, optional) — `{"daily_cycle_cap": 24, "daily_merge_cap": 12, "idle_retry_minutes": 45}`. A missing file or key uses these defaults; they are not command arguments.
- This skill must run in the main session: only it can `ScheduleWakeup` and receive `pause`/`off`.

## Workflow

### Phase 0: Status (read-only)

For `status` (and for an unsupported argument): run `autopilot-state.sh report` and relay it. Then add, derived live and never from a cache:

- **Done**: `autopilot-state.sh done` (journal files added since `started_at`, one bullet each; prints "- No tasks merged this run" when empty).
- **Needs your attention**: the `needs_attention` list, plus a task whose `status:` flags a human-only condition (`SUPERVISED`, "needs a human", a sign-off) and an open PR stuck in a way no skill resolves; apply the filter in Important Notes.

No Slack post, no `ScheduleWakeup`: this phase never touches the loop.

### Phase 0.1: off / pause / resume

1. `ScheduleWakeup(stop: true)` first, always (for `off` and `pause`).
2. A sub-agent dispatched (mid-cycle)? `SendMessage` it to commit and push WIP (no PR needed, `/drive` resumes from a pushed branch) and report; wait up to 2 minutes, then `TaskStop`. When it has reported (or been stopped), run `autopilot-state.sh busy off`.
3. `off`: `autopilot-state.sh off` prints `off <clone-path>`; remove that clone directory with `rm -rf` of the literal path (it is under `/tmp`, which the rm-guard hook allows), then post the final report (Phase 5) to the user. `noop` (already off, or nothing to pause): report the current state and stop.
4. `pause`: `autopilot-state.sh pause` (`noop` if not on: report the state); keep the clone and state; report.
5. `resume`: `autopilot-state.sh resume` prints `dispatch` (go to Phase 2, the cap check, then one cycle now) or `busy` (the interrupted cycle is still finishing: do nothing, its Phase 4 re-reads `on` and arms the next wake) or `noop` (not paused: report).

### Phase 1: on

Run `autopilot-state.sh start`:

- `started` — fresh run; go to Phase 2.
- `dispatch` — already on and a cycle is due (the wake fired); go to Phase 2.
- `already-on` — a typed `on` before the next wake is due, or a cycle is running: report `already on, next cycle at <next_wake_at>` and stop. Never dispatch, never schedule.
- `busy` — a previous run's cycle is still finishing: report it and do nothing; that cycle's Phase 4 arms the next wake.
- `paused` — report "paused; use /autopilot resume" and stop.

### Phase 2: Cap check

`autopilot-state.sh cap` prints `ok` or `capped:cycles|merges`. On `capped:*`: `autopilot-state.sh record capped`, send its notice kind if not `none` (Phase 4 Notify), then `ScheduleWakeup(<delay capped>, "/autopilot on")` and end the turn. The loop stays on; it re-checks hourly and resumes after the daily rollover.

### Phase 3: Run one cycle

**Dispatch clone** (once per run, reused every cycle). Read `dispatch_clone_path`; if `null` or missing, create it and record the path in the state file:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLONE_PATH="$(bash <skills-root>/autopilot/scripts/autopilot-state.sh clone-path "$REPO_ROOT")"
[ -d "$CLONE_PATH" ] || git clone --recurse-submodules "$(git -C "$REPO_ROOT" remote get-url origin)" "$CLONE_PATH"
```

`clone-path` prints `/tmp/autopilot-clone-<repo-name>-<8 hex of sha256(repo root)>`.

A dirty or mid-rebase leftover: remove the directory and re-run the block. Full clone, never a worktree or shallow; the same path every cycle keeps the same `claimant_id` (`_session/claimant-id.sh`).

**Resolve the pick in this turn.** `git -C "$CLONE_PATH" checkout main -q && git -C "$CLONE_PATH" pull -q`, then with cwd `$CLONE_PATH` run `/todo sweep` (a Step B park ask needs a human: treat as Stuck) and walk `/todo next`'s ranking top-down. For each candidate skip it when its id is in `skip_ids`, or `autopilot-state.sh eligible <task-file>` exits non-zero (status marks `SUPERVISED`, `BLOCKED`, "needs a human", "needs manual", "sign-off"); a status-skipped task goes to `needs_attention` via `autopilot-state.sh skip <id> "<reason>"`. Task size is never a skip reason: a big or umbrella task is picked and split (see **Big tasks** below). A skipped task whose blocker is resolved (the owner decided, or a split made it workable) comes back with `autopilot-state.sh unskip <id>` (`unskip --all` clears every skip); it prints `unskipped <id>` or `noop`. No candidate left: go to Phase 4 `idle` without dispatching.

**Dispatch** `/drive T<id> --auto-selected` via the `Agent` tool (`subagent_type: general-purpose`, no `isolation`) after `autopilot-state.sh busy on T<id>` (the picked task); note the `agentId`. The cycle's ledger start line must pass `--flags autopilot` (e.g. `ledger.sh start <n> "autopilot cycle" --flags autopilot`) so the HUD shows `running r<n>` while it runs. One `/drive` at a time (16 GB machine): never start a second while one is busy. The prompt is self-contained: name the id and `$CLONE_PATH`, require `/drive` to run to completion, give Phase 4's classification rules, and add the guardrail and the big-task rule below. **Every bash command for the whole `/drive` run begins `cd "$CLONE_PATH" &&`** (a sub-agent's Bash does not keep `cd` between calls).

**Eligibility guardrail (in the prompt).** Before claiming anything, `/drive` reads the design. Build, implementation and release-engineering work is eligible and runs end to end through the normal `/drive` gates, **including real runs**: dispatching real build workflows, pushing images or packages to the team's registries or artifact stores, uploading artifacts, tagging release candidates. Real runs follow the task's own done-criteria and the repo's runbooks. If the design calls for any of the following, it must stop without claiming and answer `NEEDS-ATTENTION: <reason>`: (a) a customer-visible post or announcement, or a message sent to a third party; (b) an action or contact toward HashData or any upstream project; (c) spending money or signing up for a paid service; (d) installing software that changes the owner's machine state outside the repo/clone; (e) access to an owner account or credentials the sub-agent does not have; (f) an open owner decision the task text leaves unresolved; (g) deleting registry artifacts (the owner approves the exact list first); (h) final customer-facing release promotion or app-store submission (a push to a registry or repo that customers consume counts as (h); a tag is allowed only when the workflow it triggers stays inside the permitted runs). Task size, estimation or being an umbrella is not on this list. For (f), a sub-task may be filed for the open question, but the agent must not guess the answer. Existing merge gates stay: green CI with all required checks finished, independent review posted on the PR, `gh pr merge --rebase`, never `--admin` or a bypass.

**Big tasks (in the prompt).** There is no size limit. If the task is too big to finish in one run (e.g. estimation 5, or an umbrella), the sub-agent does not stop or skip: it breaks the task into small sub-tasks (estimation 1-2 each, a bounded number per cycle, about 5; a sub-task that is itself too big may split again only once), files them with the repo's normal task flow (`/new-task`, or the template plus `_taskid/new.sh`), enqueues them right before the original (give each sub-task `blocks: T<original-id>` in its frontmatter and run `/stage <sub-id>`, which inserts it immediately before the queued original; or, for one already queued, `/top <sub-id> --before <original-id>`; queue order is enough, so leave the original's `status:` alone, because a `Blocked by` status makes `eligible` refuse it), lands the split as one small docs-only PR through the normal gates, then `/drive`s the first sub-task end to end in the same run. It reports the split (sub-task ids and titles) before the MERGED/STUCK lines. A task claimed by another live session is still not taken over.

End the sub-agent's final message in exactly this format:

```
MERGED: T<id> (<slug>) — PR #<n>[; runs: <run/registry URLs>]      (one line per merged task; omit if none; list any real build/publish/push run URLs)
STUCK: <short reason> — last task T<id> (<slug>)[; runs: <URLs>]   (list anything already published; only if it stopped without merging or hit its own Escalation Rules)
NEEDS-ATTENTION: T<id> — <reason>     (only per the guardrail above)
WAITING: <what is pending>            (only address-pr's wait-for-approval tier, a human's formal approval; CI-in-progress is never this)
```

Wait for the completion notification; don't poll. A failed dispatch or an unparseable report is **Stuck** ("dispatch failed or report unparseable"). An `off`/`pause` arriving during the wait takes priority (Phase 0.1).

### Phase 4: Classify, notify, reschedule

First re-read `autopilot-state.sh status`: not `on` means off/pause won while the cycle ran; run `busy off`, record nothing further and schedule nothing.

Write the sub-agent's final message to a temp file and run `autopilot-state.sh classify <file>`: it prints `<outcome> <merged-count> <task-id|-> <reason>` (exit 2 = unparseable, printed as a stuck line), then run `autopilot-state.sh record <outcome> <merged-count> <task-id> "<reason>"` with those fields (id `-`: pass `""`); it prints a notice kind or `none` and sets the next wake time. `autopilot-state.sh attention <file>` lists the `NEEDS-ATTENTION` entries as `<task-id><TAB><reason>`. The rules `classify` applies, in this order:

- `NEEDS-ATTENTION` lines (`attention`): for each, `autopilot-state.sh skip <id> "<reason>"` (prints `attention` when new, which is a notice kind to send). Pass `--kind blocked|decision|external` when the reason is clear (waiting on a decision, an outside party, a blocker): the HUD's queue breakdown counts it in that bucket. Never skip for size (`epic` is a legacy kind kept for old state files). When the owner resolves a decision, run `autopilot-state.sh unskip <id>`. Then run another cycle in 60 s unless it is the only outcome, in which case record `idle`/`progress` per what else happened.
- **progress** — something merged and nothing Stuck. Wake in 60 s.
- **waiting** — nothing merged, `WAITING:` reported. Back-off ladder 5, 10, 20, 30 min (capped), using `waiting_count`.
- **stuck** — `/drive` errored, merged and advanced nothing, hit its own Escalation Rules, or its `/address-pr` stopped without merging. Same ladder, using `stuck_count`.
- **idle** — no eligible task (Phase 3 found none, or `/drive` reported none). Retry every `idle_retry_minutes` (default 45, valid range 30-60).

**Notify** for each non-`none` kind returned: `autopilot-state.sh notify <kind> "<text>"`, one concise bullet list (kind `idle` names the `needs_attention` ids and says retries are silent; `resumed` says work is flowing again; `stuck` names the task and reason; `waiting` names the PR; `capped` names the cap; `attention` names the task and reason). `notify` tries `/slack --channel dev` and, when the env vars are unset or the post fails, records the notice in the state file (shown by `status` and the HUD); it never errors, so never retry or escalate it.

Then `ScheduleWakeup(delaySeconds: <autopilot-state.sh delay <outcome>>, prompt: "/autopilot on", reason: "autopilot <outcome>")` and end the turn. Every wake carries the same prompt; the state file decides whether it dispatches (Phase 1).

### Phase 5: Final report (on `off`)

After `autopilot-state.sh off`, run `autopilot-state.sh final-report` and post its output unchanged (it also serves as the `off` notice text for `notify`). Append to "Needs your attention" any open PR stuck beyond what a skill resolves (not derivable from state). The template it prints:

```
Autopilot run: <elapsed> elapsed — stopped: user-requested

Done:
- Merged T<id> (<slug>) — PR #<n>
(one bullet per merged task this run, from the `done` journal scan; "- No tasks merged this run" if none)

Needs your attention:
- <needs_attention entries, stuck tasks, PRs stuck beyond any skill>
(or "- Nothing outstanding")
```

Every `T<id>`/`PR #<n>` carries a short slug (bare id if it cannot be recovered).

## Important Notes

- **Needs-your-attention filter**: only items no skill can resolve unattended. Exclude `Blocked by T{id}` (a dependency `/drive` recurses into) and an open PR with routine CI/review/rebase work (the next cycle's `/drive` Phase 0 drains it). Include `needs_attention` entries (the Phase 3 guardrail's stop list; a plain build task or a big task is not one), `last_outcome == "stuck"`, and tasks whose `status:` names a human-only condition.
- **Never loop inside one turn.** One cycle is exactly one `ScheduleWakeup` boundary.
- **One run per repo, best-effort.** No lock beyond `busy_since`/`next_wake_at`; the dispatch clone path is deterministic per repo.
- **Idle is not a stop.** Going idle notifies once; retries are silent; new work (`/stage`, `/todo sweep`) is picked up on the next retry.
- **A detached `claude --bg` loop** is a possible later upgrade; v1 runs in the main session.
- **Not `/ccxp`.** `/ccxp` is the ritual-aware orchestrator; this is a plain on/off `/drive` loop.

## Cross-references

- `/drive` — does the selection/implementation/merge work, one cycle per dispatch (`--auto-selected`)
- `/slack` — `notify` posts to `--channel dev` when configured
- `/todo` — `sweep` and `next` for the pick; `/address-pr` — drains and merges PRs
- `hud/` — `AP on/off` band reads `dev/.autopilot-state.json` (`hud/scripts/hud-lib.sh`)
