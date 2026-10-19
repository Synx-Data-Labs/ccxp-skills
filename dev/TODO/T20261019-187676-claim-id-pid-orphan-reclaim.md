---
status: Open
estimation: 1
source: this conversation, 2026-10-19 (machine restart left a task claimed by a dead session)
related: T20261012-342180
description: Evaluate PID-based claim ids; recommend keeping the clone-stable id and adding a local liveness record so orphaned claims reclaim immediately
---

# T20261019-187676: Change claim-id from host-hash:path-hash to host-hash:PID so orphaned claims can be reclaimed

## Problem

- **Type**: feature (research done at filing; design to be confirmed at `/incept`)
- Incident: a machine restart left a task `In Progress` under a dead session's `claimed_by`. It had to be reclaimed by hand.
- The claim is "heartbeat-free by design" (`ccxp/SKILL.md:92`): a dead session's claim is only freed by a staleness window, so a restart can strand work for days.
- Done looks like: a claim whose owning session is provably gone (same host) is reclaimable at the next sweep or pick, not after the window. Foreign-host claims and live-but-idle sessions behave as today, with no auto-steal.
- User proposal (as stated): change `claimed_by` from `cc1-<machine-id>:<path-hash>` to `cc1-<machine-id>:<PID>` (no hash). Reasoning: same host + different PID means a different session; if the PID is gone the claim is an orphan and can be reclaimed.
- **Recommendation: adopt with modifications.** Keep the clone-stable id and add a machine-local liveness record. Sections 1 to 4 below follow: current behavior, the detection question, options, design.

## 1. Current behavior of `/claim` (and `task_claim.sh`)

### What the skill does

- `/claim` (`claim/SKILL.md`) lands the durable `claimed_by` lock on one task as its own claim PR to `main`. It does not implement or merge the task's work (`/drive` does).
- Three forms:
  - `/claim T<id>`: release everything this clone holds, then claim `T<id>`.
  - `/claim release T<id>`: release one claim, acquire nothing.
  - `/claim status`: read-only; loops `task_claim.sh read` over `dev/TODO` and `dev/PARKING` and prints tasks whose `claimed_by` equals this clone's id.

### `/claim T<id>` step by step (peer/CI mode, `claim/SKILL.md` §1)

1. Clone-locality guard: `_taskid/in-this-repo.sh T<id>`; a non-zero exit means wrong clone, stop.
2. Free and claimable checks:
   - `task_claim.sh read T<id>`. If `claimed_by` is set and is not `task_claim.sh claimant-id`, another agent holds it.
   - Then `task_claim.sh reclaimable T<id>`: `live` means stop and report the holder; `reclaimable` means take it over.
   - `lint_frozen.sh is-frozen`: a frozen (lint-failing) task file cannot merge a claim PR, so stop.
3. `git checkout -b t<id>-claim` off `main`, then `release-others T<id>`, then `acquire T<id>`.
4. Commit (pure frontmatter change), push, open a PR, hand off to `/address-pr`, which auto-merges under the status-change tier.
5. A merge conflict on the `claimed_by:` line means another session got there first. The conflict is the lock (`task_claim.sh:8`); do not retry.
6. Report the claimed task, anything released, and the PR URL.

### Solo-repo mode (`claim/SKILL.md`, "Solo-repo mode")

- Detected by a repo's `dev/guidelines.md` or `CLAUDE.md` declaring "no CI" and "direct-to-main".
- Replaces steps 3 to 6: branch `t<id>-<slug>`, `release-others` plus `acquire`, commit, `git merge --ff-only` into `main` and push immediately, then go back to the branch so the statusline shows `branch:` and `TASK:`.
- Close: `release T<id> <final-status>`, fast-forward merge, delete the branch.

### The verbs in `_session/task_claim.sh` (line numbers as of this commit)

| verb / function | behavior |
|---|---|
| `claimant-id` / `_tc_claimant_id` (`:106`) | prints `cc1-<machine-id>:<path-hash>` from `claimant-id.sh:90-96`; machine-id is a random 8 hex cached under `~/.claude/state`, path-hash is `sha256(secret + clone toplevel)[0:16]` |
| `_tc_decide` (`:240`) | `none` (empty), `mine` (exact string equality with my id), else `other`. "Mine" therefore means same machine and same clone path, not same session |
| `acquire` / `_tc_acquire` (`:552-575`) | `mine`: prints `mine`, rc 0. `none`: sets `claimed_by`, `claimed_role`, `status: In Progress`, stamps `scheduled`, prints `acquired`. `other`: prints `claimed:<cur>` and returns **rc 3**. A legacy plaintext self-claim is re-stamped in place |
| `release` / `_tc_release` (`:582`) | clears `claimed_by` and `claimed_role`, sets the given status (default Open) |
| `release-others` (`:592-640`) | release-on-pickup: frees every task in `dev/TODO` and `dev/PARKING` whose `claimed_by` equals my id, except the kept id; `In Progress` and `Design` fall back to `Open`, other statuses are kept. Enforces at most one claim per clone |
| `read` | prints `status` and `claimed_by` |
| `reclaimable` / `_tc_reclaimable` (`:642`) | gathers `commit_days`, `pr_days`, and a CI live-run signal, then calls `_tc_reclaim_decide` |
| `_tc_reclaim_decide` (`:288-340`) | pure: `live` unless status is `In Progress` or `Review`, `claimed_by` is session-shaped (current `cc1-` form or legacy `<sid>@<machine>`; a human override like `Alex` is never reclaimable), no CI run is live, and **both** `commit_days >= stale` and `pr_days >= stale` (`TASK_CLAIM_STALE_DAYS`, default 2) |
| `pr-owner` / `_tc_pr_owner` (`:918`) | PR to task to `claimed_by` on `main`, then `_tc_decide`; yields `mine`, `free`, `new`, `owned:<by>`, `untracked`, or `unknown`. `_tc_is_own_cross_repo_clone` (`:860`) upgrades `other` to `mine` when the clone is the ephemeral `<task-id>-*-target` clone on the same machine |
| `reclaim_sweep.sh` (`:73-110`) | Phase 0.5 of `/ccxp`: for each `In Progress` or `Review` task with a claim that is not mine, ask `_tc_reclaimable`; with `--apply`, `_tc_release` it. It opens a PR and Slacks each reclaim |

### Why the restart case got `live` and `acquire` rc=3 (inferred from the code, not observed)

- After the reboot the new session's id differed from the dead one's (a different clone path hash, as the incident description says), so `_tc_decide` returned `other` and `acquire` printed `claimed:<cur>`, rc 3.
- The sweep returned `live` because the staleness test needs both signals old:
  - `_tc_days_since_last_commit` (`:384`) runs `git log -1 --grep=<id>`, which matches **any** commit mentioning the id, including the claim commit itself (`docs(claim): claim T<id>`). A claim younger than the window can never look stale.
  - `_tc_pr_activity_days` (`:474`) uses the open PR's `updatedAt`, which any comment, review, bot push or CI update bumps, even when the owner is dead.
  - `_tc_has_live_run` (`:448`) treats any in-progress CI run on the PR branch as live.
- Nothing in the decision knows the owner's process is gone. This is the design gap; the staleness window is the only mechanism.

## 2. The question: how to detect a restarted or frozen previous session on the SAME clone

### Cases to distinguish

Same clone means same path hash, therefore the same claimant id; `_tc_decide` already says `mine` for all of them.

| case | what happened | what we want |
|---|---|---|
| R1 restarted session | process exited, user started a new `claude` in the same clone | new session continues; old claim is its own |
| R2 resumed session | `claude --resume <id>`: same session id, new PID | same as R1 |
| R3 rebooted machine | all processes gone, boot id changed | claim is orphaned; anyone (any clone) may reclaim at once |
| D dead session | process crashed or was killed, no reboot | orphan after a short grace; peers may reclaim |
| F frozen or hung | process alive, not progressing | do not auto-steal; surface to a human |
| I idle but healthy | process alive, waiting for a human answer (hours is normal) | must look `live`; indistinguishable from F by activity alone |
| P parallel | two live sessions in one clone (two terminals) | each must keep its own claim; today they share one id, so `release-others` from one frees the other's task |
| X foreign host | claim from another machine | PID checks are meaningless; use the staleness window |

### Signals and what they tell apart

| signal | how obtained | verified here? | separates |
|---|---|---|---|
| boot id | macOS `sysctl -n kern.boottime`; Linux `/proc/sys/kernel/random/boot_id` | verified (macOS value printed; Linux file not available here, assumed) | R3 from everything else |
| `CLAUDE_PID` | env var set by Claude Code; equals the `claude` process; subagents share it | verified (value 2217 matched `claude --resume ...`; subagent saw the same) | session identity for liveness |
| PID alive plus start time | `kill -0 <pid>` and `ps -o lstart= -p <pid>` | verified (`lstart` printed) | D (dead) and PID reuse |
| session id | `CLAUDE_CODE_SESSION_ID`; stable across `--resume`, equals the resume argument | verified | R2 vs a fresh session |
| transcript mtime | `$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-id>.jsonl`, updated while the session works | verified (file exists, mtime tracked this run); layout is undocumented, assumed stable | F or I (idle) vs working; **not** F vs I |
| `~/.claude/sessions/<pid>.json` | per-PID file next to the config | seen in a listing only, contents not read; undocumented, assumed | possible cheaper registry; do not rely on it |
| statusline state | `last-input-hook.sh` writes per-session state on every prompt | assumed usable; it only changes when the user types | I vs F weakly |
| git / PR activity | `_tc_days_since_last_commit`, `_tc_pr_activity_days`, `_tc_has_live_run` | verified in code | work progressing; polluted by the claim commit, bots, and reviewers |

### What can and cannot be decided

- R1, R2: same id, so already `mine`. The gap is only knowing a prior process is dead so a second live session in the clone is not clobbered (case P).
- R3, D: decidable on the same host with boot id plus PID plus start time.
- F vs I: **not decidable automatically.** An alive process with an old transcript is either hung or waiting on a person. Any rule that steals from it risks destroying live work, so it needs a human decision or a long timeout.
- X: not decidable by PID; keep the staleness window.

## 3. Options and trade-offs

| option | idea | cost | failure modes | cross-host | churn on `main` | lint impact |
|---|---|---|---|---|---|---|
| A. `host:PID` as the id (user's proposal) | `claimed_by = cc1-<mid>:<pid>` | rewrite every producer, parser, doc and test (see Appendix); breaks `release-others`, statusline, autopilot clone reuse | new id every restart, so own claims look `other`; PID reuse needs start time and boot id anyway; cron `claude -p` ticks look dead between ticks | useless off-host | high: new value per session, claim PR per takeover | shape regex changes; one-way-door reader needed |
| B. Keep id plus local liveness record | machine-local file per claimed task (pid, start, boot, session) | one new sourceable helper plus about 5 call sites | no record (old claims, other host) falls back to today; record lost with state dir | falls back to staleness window | none | none |
| C. Frontmatter `claimed_pid:` / `claimed_at:` | annotate claim in git | small code; two new keys | stale as soon as the session restarts; PID meaningless off-host | same | one extra line per claim; rewritten on takeover | new keys in `lint_tasks.py:23-26` and `sync.py:614` allowlists |
| D. Heartbeat or lease timestamp on `main` | owner commits `claimed_at` every N minutes | owner loop, auth, CI per heartbeat | commit flood; conflicts with the lock line; contradicts `ccxp/SKILL.md:92`; stalls if owner is frozen but pushes | works everywhere | very high | new key |
| E. Boot id only | record `boot_id` at acquire; differs now means orphan | smallest | misses crash or kill; misses a dead session after the user restarted only the CLI | same-host only | none | none |
| F. B with E first (combination, **picked**) | ship E's boot check and the PID check in one record; add idle visibility | B plus a transcript-mtime read | as B; F-vs-I stays a human call | same-host fast path, others unchanged | none | none |
| G. B plus C | local record for liveness, frontmatter hint for other hosts | B plus allowlists | the hint rots; little value because remote hosts cannot check a PID | marginal | extra line | new keys |

Rejected: A (breaks clone-stable identity, the three strongest reasons below), C, D, G. E alone is kept only as the first slice of F.

Why A fails, in one place:
- It breaks "same clone = same claimant". After every restart, resume or cron tick the new PID sees its own earlier claims as `other`.
  - `release-others` matches `claimed_by = mine`, so the clone's older tasks are never freed and the one-claim-per-clone invariant fails.
  - The statusline (`statusline-command.sh:38-70`) greps `claimed_by` equal to the clone id and stops finding the task.
  - Autopilot's reuse of one clone for a stable id (`autopilot/SKILL.md:107`) stops mattering.
- Every session writes a new value into git on `main`, with claim PRs and conflicts.
- A bare PID is recyclable (macOS wraps at 99999); it needs start time and boot id, which is option B's record anyway.
- One real gain of A: `_tc_is_own_cross_repo_clone` (`:860`) would be unnecessary when `/address-pr` runs in the same process. Cron or autopilot dispatches start a new process, so the path rule is still needed.

## 4. Design of the picked option (F: local liveness record)

### 4.1 Liveness record

- Location: `$CLAIMANT_STATE_DIR/claims/<task-id>.json` (default `~/.claude/state/claims/`; honors `CLAIMANT_STATE_DIR` and, via `T20261002-303999`, `CLAUDE_CONFIG_DIR`). Mode 600, never committed, written with temp file plus rename.
- Keyed by task id, machine-wide, so the hub clone and an ephemeral cross-repo target clone see the same record.
- Format:

```json
{"v":1,"task":"T20261019-187676","claimant":"cc1-50ac6891:5e1f014a92f728aa",
 "claude_pid":2217,"pid_start":"Mon Oct 19 12:30:28 2026",
 "boot_id":"1792430967","session_id":"b4e03d23-...","role":"interactive",
 "transcript":"<abs path or empty>","acquired_at":"2026-10-19T13:00:00Z"}
```

- No heartbeat writes. "Last activity" is read from the transcript file's mtime, so nothing writes on a timer.
- PID source: `$CLAUDE_PID`; fallback is the first `claude` ancestor in the PPID chain; if neither is found, write no record (state `unknown`, today's behavior).

### 4.2 Who writes and reads

| actor | action |
|---|---|
| `_tc_acquire` (`none` and `mine` branches) | write or refresh the record (takeover by a resumed session updates `claude_pid` and `pid_start`) |
| `_tc_release`, `_tc_release_others` | remove the record for each freed task |
| `_tc_reclaimable` | compute the state (4.3) and pass it to `_tc_reclaim_decide` as a new 7th argument |
| `_tc_release_others` | skip, and warn about, a task whose record shows another **live** session in this clone (case P) |
| `reclaim_sweep.sh` | prints the reason (`restarted-host`, `dead`) in its reclaimed line and Slack summary; also reports `idle` claims it did not touch |
| `/claim`, `/drive`, `/todo` | no flow change; their `reclaimable` check now returns `reclaimable` sooner |

### 4.3 State computed from the record (`claim_liveness_state`, pure helper, prints one word)

| record | boot id | PID | transcript idle | state |
|---|---|---|---|---|
| none, unreadable, or claimant machine-id differs from this host | | | | `unknown` |
| present | differs | any | any | `rebooted` |
| present | same | dead, or alive with a different start time (PID reuse) | any | `dead` |
| present | same | alive, start matches | below `IDLE_MIN` | `alive` |
| present | same | alive, start matches | at or above `IDLE_MIN` | `alive-idle` |

### 4.4 Decision table for `_tc_reclaim_decide` (new rows run after the existing status and shape pre-checks, before the staleness window)

| state | role | extra condition | verdict |
|---|---|---|---|
| `unknown` | any | | today's rules unchanged (foreign host, old claims, missing record) |
| `rebooted` | any | `live_signal` not set | `reclaimable` immediately (restarted host, case R3) |
| `dead` | `interactive` | time since the record's `acquired_at` and transcript mtime both at least `GRACE_DEAD` (default 15 min) | `reclaimable` (case D) |
| `dead` | `ccxp` | same, but `GRACE_DEAD_CCXP` (default 3 h, longer than the hourly tick) | `reclaimable` |
| `dead` | any | grace not elapsed | `live` |
| `alive` | any | | `live`, skip the window (healthy session) |
| `alive-idle` | any | | falls through to today's staleness window; nothing new auto-steals (case F or I) |
| any | any | CI run live | `live` (existing `live_signal` precedence kept) |

- Same-host `rebooted` and `dead` skip the commit and PR windows on purpose: those signals are polluted by the claim commit and by bots (section 1).
- `human override` and non-session shapes remain never reclaimable (existing pre-check).

### 4.5 Frozen and idle handling

- No rule auto-steals from a live process; a hung and a waiting-for-human session look identical.
- Visibility: the sweep lists `idle <task> <hours>` for `alive-idle` claims past `IDLE_NOTIFY` (default 24 h) in the same Slack message, so a human decides.
- Human path: a documented manual step (`/claim release T<id>` run by whoever confirms the session is gone, or killing the hung process, which turns the state into `dead`). No new verb is needed in the first slice.
- Existing staleness window still reclaims a claim whose PID is alive but whose commits and PR have been quiet for the full window; unchanged behavior, now explicitly the only path for frozen sessions.
- Defaults to confirm at `/incept`: `IDLE_MIN` 30 min, `GRACE_DEAD` 15 min, `GRACE_DEAD_CCXP` 3 h, `IDLE_NOTIFY` 24 h.

### 4.6 Edits per file (no scripts change in this task; list for the implementation task)

- New `_session/claim_liveness.sh` (side-effect-free, sourceable, like `claimant-id.sh`): `claim_live_write`, `claim_live_rm`, `claim_live_read`, `claim_liveness_state`, `claim_boot_id`, `claim_pid_start`.
- `_session/task_claim.sh`: `_tc_acquire` (`:552-575`) writes the record; `_tc_release` (`:582`) and `_tc_release_others` (`:592-640`) remove it, the latter also skips live foreign sessions; `_tc_reclaimable` (`:642`) computes the state; `_tc_reclaim_decide` (`:288-340`) gets the 7th argument and the new rows; header comment `:12-39` and usage text updated.
- `_session/reclaim_sweep.sh` (`:73-110`): print reason; list `alive-idle` claims.
- Docs: `claim/SKILL.md` (note under §1.2 that `reclaimable` is now liveness-aware), `_session/README.md:93-109`, `ccxp/SKILL.md:92-107` (retire "heartbeat-free by design" wording: still no heartbeat, but local liveness), `glossary.md:23,29`, `lifecycle.md` if it names the window.
- No change: `claimant-id.sh` (id format), `lint_tasks.py`, `sync.py`, statusline, attribution, `todo/scripts/_lib.sh`.

### 4.7 Tests to add (`tests/claim_liveness.bats`, plus rows in `tests/task_claim.bats`)

- Helper, with injectable `CLAIM_BOOT_ID` and `CLAIM_PS` overrides: `rebooted`, `dead` (spawn and kill a `sleep`), PID reuse (same PID, different start), `alive`, `alive-idle` (`touch -t` on a fake transcript), `unknown` for no record and for another machine-id.
- `_tc_reclaim_decide` truth table: every row of 4.4, including `live_signal` precedence and the ccxp grace; existing tests must pass untouched (7th argument defaults empty).
- `acquire` writes the record; `release` and `release-others` remove it; a resumed session (same session id, new PID) refreshes it.
- `release-others` skips a task held by another live session in the same clone and prints a warning.
- `reclaim_sweep` end to end: rebooted claim is freed with the reason in its output; `alive-idle` claim is listed, not freed; foreign-host claim behaves as before.
- Doc lint and the `cc1-` shape tests stay green (no format change).

### 4.8 Migration and compatibility

- No frontmatter or id change, so no migration of task files and no one-way-door reader needed.
- Claims acquired before the change have no record, so they read `unknown` and keep today's behavior. The incident's own claim would not have been fixed by this change; only future claims are covered. An optional one-time `task_claim.sh adopt` could stamp a record for currently held claims; not planned in the first slice.
- Rollback is deleting the helper call sites; the record files are inert.
- Cross-platform: boot id and `ps lstart` differ on macOS and Linux; the helper must handle both and fall back to `unknown` on any error (fail toward today's behavior, never toward a steal).

## Open questions

- Confirm the default timings (`IDLE_MIN`, `GRACE_DEAD`, `GRACE_DEAD_CCXP`, `IDLE_NOTIFY`).
- Is `CLAUDE_PID` set in every launch mode (`claude -p`, SDK, dispatched agents)? Verified only for an interactive session and its subagent; the PPID fallback needs a test.
- Is the transcript path layout (`projects/<cwd-slug>/<session-id>.jsonl`) stable enough, or should the record store the resolved path at acquire (as drafted)?
- Should `claimed_role: ccxp` claims also be exempt from the `dead` fast path (rely on `rebooted` only)?
- Share the machine-local store with `T20261012-342180` (claimant reverse lookup), including its `CLAUDE_CONFIG_DIR` handling (`T20261002-303999`)?
- Do we still want the original ask (id literally `host:PID`) after reading section 3? If yes, record the decision to drop clone-stable ids and the one-claim-per-clone invariant explicitly.

## Appendix: change surface if option A were adopted as written (for the record)

- Producers: `claimant_id` (`_session/claimant-id.sh:90-96`), `_tc_claimant_id` (`task_claim.sh:106-123`), statusline copy (`statusline-command.sh:24-70`).
- Parsers and comparers: `claimant_is_current_shape` (`claimant-id.sh:102`), `claimant_display` (`:114`), `_tc_decide` (`task_claim.sh:240`), `_tc_reclaim_decide` (`:288-340`), `_tc_is_legacy_self_claim` (`:493-517`), `_tc_acquire`, `_tc_release_others`, `_tc_is_own_cross_repo_clone` (`:860-890`), `_tc_pr_owner` (`:918-947`), `reclaim_sweep.sh:73-110`, `claim_gap.sh`, `task-state.sh:78-158`, `attribution.sh:106-160,218-241`, `todo/scripts/_lib.sh:33-66`, `epic/scripts/epic.sh`, `ccxp/scripts/epic-status.sh:151-167`, `retro/scripts/compute-velocity.sh:78-108`, `_ipm/ipm-iteration-drain-check.sh`, `migrate-task/scripts/migrate.sh`, `actions/sync-tasks/sync.py:614-636,790-795`.
- Docs: `lifecycle.md:93`, `glossary.md:23,29`, `_session/README.md:95-103`, `drive/SKILL.md:123-133`, `claim/SKILL.md:42-122,165-189`, `address-pr/SKILL.md:99-167`, `todo/SKILL.md:105,141`, `ccxp/SKILL.md:92-107,317,403`, `autopilot/SKILL.md:107`, `statusline-setup/SKILL.md:13`, `eta/SKILL.md:43-74`, `ipm/SKILL.md:66`.
- Tests: `tests/task_claim.bats` (~100 matches), `tests/claimant_id.bats` (~48), `tests/statusline_setup.bats`, `tests/attribution.bats`, `tests/todo-next.bats`, `tests/reclaim_sweep.bats`, `tests/claim_gap.bats`, `tests/task-state.bats`, `actions/sync-tasks/test_sync.py`.
- Prior decision to respect: the `T20260911-698434` journal ("Format alternatives considered") chose the two-field `cc1-<mid>:<hash>` shape because the value is parsed by YAML, grepped as a regex by the statusline, and split on the first `:`.
