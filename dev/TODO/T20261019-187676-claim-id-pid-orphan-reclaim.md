---
status: Open
estimation: 1
source: this conversation, 2026-10-19 (machine restart left a task claimed by a dead session)
related: T20261012-342180
description: Evaluate PID-based claim ids; recommend keeping the clone-stable id and adding a local liveness record so orphaned claims reclaim immediately
---

# T20261019-187676: Change claim-id from host-hash:path-hash to host-hash:PID so orphaned claims can be reclaimed

## Problem

- **Type**: feature (design to be confirmed at `/incept`)
- Today every claim goes through git: `claimed_by` on `main`, a claim PR, and a staleness window (`TASK_CLAIM_STALE_DAYS`, default 2) as the only way to notice a dead owner.
  - A machine restart or crash leaves the task `In Progress` under a dead session. Nothing on the host knows the owner is gone, so it was reclaimed by hand.
  - Same-host exclusion ("one agent per task") needs no git at all, yet pays the claim-PR round-trip, `main` churn, and the 2-day wait.
- Direction (design in section 4):
  - **Same-host exclusion = a host-local lock** per task (atomic `mkdir` under a host-local state dir; holder = pid + start time + boot id + session id). A dead holder or a changed boot id is taken over at once, with no git round-trip.
  - **`main` is only for cross-host visibility.** `claimed_by` is written when the work first goes public (first push or PR), not at pickup. A claim whose host-part is another machine is foreign and keeps today's staleness window; a claim whose host-part is this machine is governed by the local lock.
  - The id format stays `cc1-<machine-id>:<path-hash>`; no new frontmatter keys.
- Scope also includes deleting the solo-repo mode handling: the "Solo-repo mode" section of `claim/SKILL.md` and the matching bullet in `drive/SKILL.md` Phase 1 (`:137-139`). Without per-pickup claim PRs there is nothing for it to shortcut.
- Done looks like: two agents on one host cannot work the same task; a dead or rebooted owner is reclaimed on the next pick or sweep; cross-host behavior is unchanged.

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

### Solo-repo mode (`claim/SKILL.md`, "Solo-repo mode") - to be deleted by this task

- Today: detected via "no CI" and "direct-to-main" in `dev/guidelines.md` or `CLAUDE.md`; replaces steps 3 to 6 with a branch, `release-others` plus `acquire`, and an immediate `--ff-only` merge and push of the claim.
- Decision: remove it (and the matching `drive/SKILL.md:137-139` bullet). Under the host-local lock design a pickup no longer commits anything, so the mode has no job.

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
| F. B with E first (combination) | one record with boot check and PID check, plus idle visibility | B plus a transcript-mtime read | as B; still needs grace tables and a role exemption; F-vs-I stays a human call | same-host fast path, others unchanged | none | none |
| **H. Host-local lock; `main` only for cross-host (picked)** | atomic `mkdir` lock per task under a host-local state dir (pid, start, boot id, session); `claimed_by` committed only at first push | one helper plus about 6 call sites; claim PR and solo-repo mode deleted | state dir shared across hosts (unsupported); `$CLAUDE_PID` unset (refuse); two hosts can start the same task before a push (conflict at PR time) | foreign claims keep today's staleness window | lowest: one `claimed_by` write per task, none at pickup | none |
| G. B plus C | local record for liveness, frontmatter hint for other hosts | B plus allowlists | the hint rots; little value because remote hosts cannot check a PID | marginal | extra line | new keys |

Rejected: A (breaks clone-stable identity, reasons below), C, D, G. B, E and F are superseded by H, which gives the same dead-session detection with a simpler mechanism and also stops two agents on one host from taking the same task.

Why A fails, in one place:
- It breaks "same clone = same claimant". After every restart, resume or cron tick the new PID sees its own earlier claims as `other`.
  - `release-others` matches `claimed_by = mine`, so the clone's older tasks are never freed and the one-claim-per-clone invariant fails.
  - The statusline (`statusline-command.sh:38-70`) greps `claimed_by` equal to the clone id and stops finding the task.
  - Autopilot's reuse of one clone for a stable id (`autopilot/SKILL.md:107`) stops mattering.
- Every session writes a new value into git on `main`, with claim PRs and conflicts.
- A bare PID is recyclable (macOS wraps at 99999); it needs start time and boot id, which is option B's record anyway.
- One real gain of A: `_tc_is_own_cross_repo_clone` (`:860`) would be unnecessary when `/address-pr` runs in the same process. Cron or autopilot dispatches start a new process, so the path rule is still needed.

## 4. Design of the picked option (H: host-local lock, `main` only for cross-host)

### 4.1 Principle

- Two layers, each answering one question:
  - **Host-local lock** (new): "which agent on THIS host is working task T?" Atomic, instant, no git.
  - **`claimed_by` on `main`** (kept): "is some OTHER host working task T?" Written once the work is cross-host-visible; read with today's rules.
- Decision: a same-host claim is **not** written to `main` at pickup. `claimed_by` (and `status: In Progress`) is committed with the task's first push, as part of the implementation branch and PR; there is no separate claim PR.
  - Why: the claim PR existed to arbitrate agents, and the lock now does that for the same host. Other hosts only need to see a claim once there is something to collide with (a pushed branch or PR).
  - Cost: two hosts can both start the same task before either pushes; the loser hits the `claimed_by` merge conflict at PR time (the existing lock rule, just later). Accepted because cross-host overlap is rare; the alternative (write at pickup, as today) is listed under open questions.
- Id format unchanged: `cc1-<machine-id>:<path-hash>` is still what lands on `main`; it is only used there for host-part comparison and display.

### 4.2 The lock

- Location: `$CLAIMANT_STATE_DIR/locks/<task-id>/` (default `~/.claude/state/locks/`), outside every repo, never committed. Keyed by task id, so a hub clone and a cross-repo target clone share it.
- Atomicity: `mkdir` of the lock dir. Success means acquired; `EEXIST` means held.
- Contents: `holder.json` written right after `mkdir`:

```json
{"v":1,"pid":2217,"pid_start":"Mon Oct 19 12:30:28 2026","boot_id":"1792430967",
 "session_id":"b4e03d23-...","clone":"5e1f014a92f728aa","acquired_at":"2026-10-19T13:00:00Z"}
```

- Holder pid is `$CLAUDE_PID` (verified to be the `claude` process, shared by subagents); fallback is the first `claude` ancestor in the PPID chain; if none is found, acquire refuses with a clear message (fail closed, like `claimant-id.sh`).
- Holder states, computed by one pure helper `lock_holder_state`:

| holder.json | boot id | pid | state |
|---|---|---|---|
| session id equals mine | any | any | `mine` (re-entrant; refresh pid and start for a resumed session) |
| other session | differs | any | `stale` (rebooted) |
| other session | same | dead, or alive with a different start time (PID reuse) | `stale` (dead) |
| other session | same | alive, start matches | `held` |
| missing or unparsable, dir mtime older than 10 s | | | `stale` (crash between `mkdir` and write) |
| missing or unparsable, dir mtime within 10 s | | | `held` (writer still in progress) |

### 4.3 Lifecycle

- **Acquire** (`task_claim.sh acquire T`): `mkdir`; on success write `holder.json`, print `acquired`. On `EEXIST` evaluate the holder state: `mine` prints `mine`, rc 0; `held` prints `claimed:local:<session>`, rc 3; `stale` takes over.
- **Takeover**: `mv` the stale dir to `locks/.stale-<task>-<rand>`; only the process whose `mv` succeeds retries `mkdir`, so two racing takers cannot both win. The old dir is deleted afterwards. A takeover also clears any `claimed_by` on the task file that names this host (it is now orphaned) before the new holder re-stamps it at push time.
- **Release** (`release T`, at close): `rm -r` the lock dir and clear `claimed_by` and `claimed_role` in the task file as today.
- **Switching tasks** (`release-others T`): now means "release every lock whose holder session is mine, except T". It no longer scans task files by clone id. The old "at most one claim per clone" rule becomes "one active lock per session"; it is kept only as hygiene so a session that moves on frees its previous task. It can be dropped later without correctness loss, because a dead session's lock is taken over lazily.
- **Session exit without release** (crash, kill, reboot): the lock dir remains and is `stale` the next time anyone looks. No cleanup daemon.

### 4.4 Decision tables

Pick or acquire on the same host, then the `main` claim, evaluated in this order:

| local lock | `claimed_by` on `main` | result |
|---|---|---|
| free, or `stale` (taken over) | empty | acquire, proceed |
| `mine` | any | proceed |
| `held` by another session | any | `owned:local`, stop (same-host exclusion, even for a second agent in the same clone) |
| free or `stale` | host-part is this machine | orphaned claim of a dead or rebooted session: take over, clear, proceed |
| free or `stale` | host-part is another machine | foreign: today's `reclaimable` rules (staleness window, CI live run, human overrides never reclaimable); otherwise `owned:<by>` |
| any | legacy or non-session shape | unchanged |

`_tc_reclaim_decide` change (the sweep and `reclaimable`):

| claim on `main` | local lock | verdict |
|---|---|---|
| host-part is this machine | `held` | `live` (never auto-steal a live pid) |
| host-part is this machine | free or `stale` | `reclaimable` at once (restarted, dead, or never locked after the migration window) |
| host-part is another machine | not consulted | today's window rules unchanged |

### 4.5 Who reads it

| consumer | change |
|---|---|
| `/claim`, `/drive` Phase 1 | `acquire` is local and instant; no claim PR, no solo-repo branch; `claimed_by` is committed with the first push (a small `task_claim.sh stamp T` step run before that push) |
| `/address-pr` (`pr-owner`) | PR to task to `claimed_by` on `main`: same-host host-part is checked against the local lock (`mine`, `owned:local`, or free); another host's claim is `owned:<by>` as today. The cross-repo path special case (`_tc_is_own_cross_repo_clone`) becomes unnecessary when the target clone runs in the same session; keep it until verified for dispatched `address-pr` runs |
| `release-others` | see 4.3 |
| statusline | finds the task by the lock whose holder `clone` equals this clone's path-hash and whose pid is alive (assumed: the statusline process cannot rely on `CLAUDE_CODE_SESSION_ID`, so use the clone hash); falls back to the old `claimed_by` grep |
| `/todo next`, `todo/scripts/_lib.sh:33-66` | claim state adds `peer-local` when a live lock is held by another session; foreign hosts as today |
| `reclaim_sweep.sh` | uses the second table above; no longer waits for the window on this host |

### 4.6 Frozen sessions

- A live holder pid is never auto-stolen. A hung and a waiting-for-human session look identical, so no timeout steals from it.
- Human override: `task_claim.sh unlock T<id> --force`. It prints the holder (pid, start, session, acquired time) and takes over only when run with `--force`; killing the hung process instead turns the lock `stale` and needs no override.

### 4.7 Failure modes

| failure | handling |
|---|---|
| state dir on a network home shared by several hosts | unsupported: pid and boot id are host-local and `machine-id` is shared too; the state dir must be host-local. Documented; helper refuses to run if `CLAIMANT_STATE_DIR` is not writable |
| lock dir on another filesystem than the clone | irrelevant; the lock is keyed by task id, not path |
| two clones on one host racing | same lock dir, `mkdir` arbitrates; the loser gets `owned:local` |
| crash between `mkdir` and `holder.json` | 10 s grace by dir mtime, then `stale` |
| PID reuse after wrap | pid alive but start time differs, so `stale` |
| `$CLAUDE_PID` missing (unknown launch mode) | acquire refuses; test the PPID fallback per launch mode |
| lock deleted by hand | next acquire simply succeeds; same as a release |
| `mv` takeover interrupted | leftover `.stale-*` dirs are ignored and swept on the next acquire |

### 4.8 Edits per file (no scripts change in this task; list for the implementation task)

- New `_session/claim_lock.sh` (sourceable, side-effect-free): `lock_acquire`, `lock_release`, `lock_holder_state`, `lock_force`, `claim_boot_id`, `claim_pid_start`.
- `_session/task_claim.sh`: `_tc_acquire` (`:552-575`) takes the lock first and stops writing `claimed_by` at pickup; new `stamp` verb writes `claimed_by` and `status` at first push; `_tc_release` (`:582`) releases the lock; `_tc_release_others` (`:592-640`) rewritten around lock holders; `_tc_decide` (`:240`) gains the local-lock input; `_tc_reclaim_decide` (`:288-340`) gets the host-part rows; `_tc_pr_owner` (`:918-947`) reads the lock for same-host claims; new `unlock` verb; usage and header comment (`:12-39`).
- `_session/reclaim_sweep.sh` (`:73-110`): report reason (`rebooted`, `dead`).
- Skills: `claim/SKILL.md` (delete Solo-repo mode, drop the claim-PR steps, document `unlock`), `drive/SKILL.md` Phase 1 (`:116-139`: drop claim PR and solo bullet, add the `stamp` step), `address-pr/SKILL.md` `pr-owner` flow (`:99-167`), `todo/SKILL.md` (`:105,141`), `ccxp/SKILL.md:92-107` ("heartbeat-free" wording), `_session/README.md:93-109`, `glossary.md:23,29`, `statusline-setup/scripts/statusline-command.sh:24-70`.
- No change: `claimant-id.sh` id format, `lint_tasks.py`, `sync.py` (no new frontmatter key).

### 4.9 Tests (`tests/claim_lock.bats`, plus rows in `tests/task_claim.bats`)

- Lock: acquire, re-entrant `mine`, `held` by a live second process, `stale` after the holder is killed, PID reuse (injected start time), reboot (injected `CLAIM_BOOT_ID`), crash-before-write (empty dir, aged with `touch -t`), racing takers (two background acquires, exactly one wins), release removes the dir.
- Decision tables 4.4: every row, including `owned:local` for a second agent in the same clone, and foreign-host rows matching today's results.
- `release-others` frees only my session's locks; `unlock --force` output and takeover.
- Sweep end to end: rebooted same-host claim freed at once; foreign-host claim waits for the window; live holder is `live`.
- `pr-owner` for same-host and cross-repo target clone; statusline finds the locked task.
- Existing `cc1-` shape tests stay green (no format change).

### 4.10 Migration

- No id or frontmatter change. Existing `claimed_by` values on `main` keep their meaning: host-part this machine means "governed by the local lock", another machine means foreign.
- Rollout window: the first run creates `locks/.v1` (marker). A same-host claim with no lock, made by an older version, falls back to the old staleness window until the marker is older than `TASK_CLAIM_STALE_DAYS`; after that a missing lock means free. A claim whose id equals mine is adopted (lock created) on the next `acquire`.
- Legacy `<host>:<path>`, `<sid>@<machine>` and human overrides: unchanged.
- Rollback: remove the lock calls; the lock dirs are inert.

### 4.11 Dropped from the earlier design

- Grace-period tables (`GRACE_DEAD`, `GRACE_DEAD_CCXP`), the ccxp-role exemption, idle thresholds and transcript-mtime reads, the per-task liveness record with a separate decision state machine, and the claim PR for pickup: the lock plus pid-start-boot check makes them unnecessary. A cron `claude -p` tick that dies between ticks simply releases nothing and is taken over cleanly by its next tick (same clone) or by a peer after the pid is dead.

## Open questions

- Interpretation chosen from the feedback: `claimed_by` is written at first push, not at pickup (4.1). Alternative: write at pickup as today, which keeps early cross-host visibility but keeps the claim PR.
- Interpretation chosen: the lock is keyed by task id and host, so two agents in one clone are also mutually exclusive.
- Is `CLAUDE_PID` set in every launch mode (`claude -p`, SDK, dispatched agents)? Verified only for an interactive session and its subagent.
- Can the statusline get the session id, or must it use the clone hash (4.5)?
- Does a cron tick that resumes a task whose previous tick died need an explicit hand-off, or is takeover by pid-dead enough?
- Share the host-local state dir and `CLAUDE_CONFIG_DIR` handling with `T20261012-342180` (claimant reverse lookup) and `T20261002-303999`.
- Marker window length for migration: `TASK_CLAIM_STALE_DAYS` assumed.

## Appendix: change surface if option A were adopted as written (for the record)

- Producers: `claimant_id` (`_session/claimant-id.sh:90-96`), `_tc_claimant_id` (`task_claim.sh:106-123`), statusline copy (`statusline-command.sh:24-70`).
- Parsers and comparers: `claimant_is_current_shape` (`claimant-id.sh:102`), `claimant_display` (`:114`), `_tc_decide` (`task_claim.sh:240`), `_tc_reclaim_decide` (`:288-340`), `_tc_is_legacy_self_claim` (`:493-517`), `_tc_acquire`, `_tc_release_others`, `_tc_is_own_cross_repo_clone` (`:860-890`), `_tc_pr_owner` (`:918-947`), `reclaim_sweep.sh:73-110`, `claim_gap.sh`, `task-state.sh:78-158`, `attribution.sh:106-160,218-241`, `todo/scripts/_lib.sh:33-66`, `epic/scripts/epic.sh`, `ccxp/scripts/epic-status.sh:151-167`, `retro/scripts/compute-velocity.sh:78-108`, `_ipm/ipm-iteration-drain-check.sh`, `migrate-task/scripts/migrate.sh`, `actions/sync-tasks/sync.py:614-636,790-795`.
- Docs: `lifecycle.md:93`, `glossary.md:23,29`, `_session/README.md:95-103`, `drive/SKILL.md:123-133`, `claim/SKILL.md:42-122,165-189`, `address-pr/SKILL.md:99-167`, `todo/SKILL.md:105,141`, `ccxp/SKILL.md:92-107,317,403`, `autopilot/SKILL.md:107`, `statusline-setup/SKILL.md:13`, `eta/SKILL.md:43-74`, `ipm/SKILL.md:66`.
- Tests: `tests/task_claim.bats` (~100 matches), `tests/claimant_id.bats` (~48), `tests/statusline_setup.bats`, `tests/attribution.bats`, `tests/todo-next.bats`, `tests/reclaim_sweep.bats`, `tests/claim_gap.bats`, `tests/task-state.bats`, `actions/sync-tasks/test_sync.py`.
- Prior decision to respect: the `T20260911-698434` journal ("Format alternatives considered") chose the two-field `cc1-<mid>:<hash>` shape because the value is parsed by YAML, grepped as a regex by the statusline, and split on the first `:`.
