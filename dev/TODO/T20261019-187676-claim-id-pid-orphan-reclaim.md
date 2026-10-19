---
status: In Progress
estimation: 1
source: this conversation, 2026-10-19 (machine restart left a task claimed by a dead session)
related: T20261012-342180
description: Evaluate PID-based claim ids; recommend keeping the clone-stable id and adding a local liveness record so orphaned claims reclaim immediately
claimed_by: cc1-50ac6891:79b7bb9124eb6646
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261019-187676: Change claim-id from host-hash:path-hash to host-hash:PID so orphaned claims can be reclaimed

## Problem

- **Type**: feature (design to be confirmed at `/incept`)
- The `claimed_by` lock on `main` cannot tell that its owner is gone. A machine restart or crash leaves the task `In Progress` under a dead session, and the only remedy is the staleness window (`TASK_CLAIM_STALE_DAYS`, default 2). The incident was reclaimed by hand.
- Two sessions in one clone share one claimant id, so the lock cannot stop the second one from working the same task.
- Direction (design in section 4): keep `claimed_by` on `main` exactly as it is, and add a purely additive, host-local guard.
  - One **clone lock** (an atomic `mkdir` under a host-local state dir) records the live agent of each clone: pid, start time, boot id. One agent plus its subagents per clone; a second independent session is refused.
  - When a claim on `main` names this machine, its clone's lock tells whether the owner is alive. A dead holder or a changed boot id makes the claim reclaimable at once through the normal release plus acquire path, with no staleness-window wait.
  - Foreign-host claims, id format, `pr-owner`, `release`, `release-others` and the statusline are unchanged.
  - The lock logic lives in one shared library, `_session/clone-lock.sh`; scripts and skills are thin callers.
- Scope also includes deleting the solo-repo mode handling: the "Solo-repo mode" section of `claim/SKILL.md` and the matching bullet in `drive/SKILL.md` Phase 1 (`:137-139`).
- Done looks like: after a restart or crash, the next pick on this host reclaims the dead holder's claim immediately; a second session in the same clone is refused; cross-host behavior is unchanged.

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
| **H. Additive host-local clone lock; `claimed_by` on `main` unchanged (picked)** | one lock dir per clone under a host-local state dir (pid, start, boot id); `reclaimable` consults the claimant clone's lock for same-host claims | shared library `_session/clone-lock.sh` plus about 4 call sites; solo-repo mode deleted | state dir shared across hosts (unsupported); `$CLAUDE_PID` unset (refuse); pre-lock claims wait for the window during rollout | foreign claims keep today's staleness window | none (no new writes to `main`) | none |
| G. B plus C | local record for liveness, frontmatter hint for other hosts | B plus allowlists | the hint rots; little value because remote hosts cannot check a PID | marginal | extra line | new keys |

Rejected: A (breaks clone-stable identity, reasons below), C, D, G. B, E and F are superseded by H, which gives the same dead-session detection with a simpler mechanism and also refuses a second session in the same clone.

Why A fails, in one place:
- It breaks "same clone = same claimant". After every restart, resume or cron tick the new PID sees its own earlier claims as `other`.
  - `release-others` matches `claimed_by = mine`, so the clone's older tasks are never freed and the one-claim-per-clone invariant fails.
  - The statusline (`statusline-command.sh:38-70`) greps `claimed_by` equal to the clone id and stops finding the task.
  - Autopilot's reuse of one clone for a stable id (`autopilot/SKILL.md:107`) stops mattering.
- Every session writes a new value into git on `main`, with claim PRs and conflicts.
- A bare PID is recyclable (macOS wraps at 99999); it needs start time and boot id, which is option B's record anyway.
- One real gain of A: `_tc_is_own_cross_repo_clone` (`:860`) would be unnecessary when `/address-pr` runs in the same process. Cron or autopilot dispatches start a new process, so the path rule is still needed.

## 4. Design of the picked option (H: additive host-local clone lock)

### 4.1 Principle and scope

- `claimed_by` on `main` is unchanged: acquired at pickup through the existing claim PR flow, same `cc1-<machine-id>:<path-hash>` format, same `_tc_decide`, `release`, `release-others` and `pr-owner` semantics, same staleness window for foreign hosts.
- The new **clone lock** answers one question: "is the agent of clone K on this host alive?" Key K is the path-hash half of the claimant id, so a claim's owner clone is always derivable from `claimed_by` itself (`${claimed_by#*:}`).
- Scope per clone: exactly one agent plus its subagents. Subagents share `CLAUDE_PID` and the session id with the parent (verified), so the holder is the parent `claude` process and subagents are covered. A second independent session in the same clone is unsupported: the lock refuses it, it does not coordinate it. "At most one claim per clone" keeps its meaning (it is still enforced by `release-others`); the lock adds "at most one live agent per clone".
- Out of scope: the statusline (interactive-only, unchanged); any cron hand-off protocol (a new tick takes over when the previous holder's pid is dead, or boot id changed, and never steals from a live holder).
- Solo-repo mode is deleted (scope item above); nothing here accommodates it.

### 4.2 Lock format

- Location: `$LOCK_STATE_DIR/<clone-key>/` where `LOCK_STATE_DIR` defaults to `$CLAIMANT_STATE_DIR/locks` (`~/.claude/state/locks`). Host-local, outside every repo, never committed.
- Contents: a `holder` file of `key=value` lines (no jq dependency), versioned:

```
v=1
pid=2217
pid_start=Mon Oct 19 12:30:28 2026
boot_id=1792430967
session_id=b4e03d23-0d6c-44ea-84a9-0082d4ad28ce
acquired_at=2026-10-19T13:00:00Z
```

- `session_id` is informational (shown to a human). Identity for "mine" is `pid` plus `pid_start`, so a new conversation inside the same `claude` process still counts as the same holder, and a resumed session (new pid, same session id) is a different holder that takes over a dead one.
- Cross-platform:
  - Boot id: macOS `sysctl -n kern.boottime` (seconds field); Linux `/proc/sys/kernel/random/boot_id`; both verified/assumed as noted in section 2. Any failure yields an empty boot id and the lock treats boot id as unknown (never as "changed").
  - Process start time: `LC_ALL=C ps -o lstart= -p <pid>` (works on macOS and procps), whitespace-squeezed; compared as strings.
  - mtime for the crash grace: `stat -f %m` (BSD) or `stat -c %Y` (GNU).
- State dir must be host-local. On a home directory shared by several hosts the lock is unsupported (documented; pid and boot id are meaningless across hosts).

### 4.3 Shared library `_session/clone-lock.sh`

- Placement follows `skill-conventions` §4: a helper needed by several callers lives in a `_<prefix>/` directory. `_session/` already holds `claimant-id.sh`, which `task_claim.sh` sources with `source "$_TC_DIR/claimant-id.sh"`; `clone-lock.sh` is sourced the same way, is side-effect-free at source time (no `set`, no I/O), and is the only place that knows the lock format and the platform differences. Nothing else reads or writes the lock directory.
- Public API (all take `<clone-key>`, 16 hex; `lock_key_of <claimed_by-or-id>` derives it):

| function | purpose | output | exit codes |
|---|---|---|---|
| `lock_key_of <id>` | clone key from a claimant id (`${id#*:}`); empty for non-`cc1-` shapes | key | 0, 1 if not current shape |
| `lock_self` | resolve this holder: pid (`$LOCK_SELF_PID`, else `$CLAUDE_PID`, else first `claude` ancestor), its start time, boot id, session id | `pid<TAB>start<TAB>boot<TAB>session` | 0, 2 if no pid can be found |
| `lock_acquire <key>` | take or re-enter the lock; takes over a stale one | `acquired`, `mine`, `took-over:dead`, `took-over:rebooted`, or `held:<pid>:<session>` | 0 acquired or mine, 3 held by another live holder, 2 no identity, 1 I/O error |
| `lock_state <key>` | classify the lock | one of `none`, `mine`, `held`, `stale:dead`, `stale:rebooted`, `stale:incomplete` | always 0 |
| `lock_is_stale <key>` | convenience over `lock_state` | none | 0 if state starts with `stale:` |
| `lock_holder <key>` | print the holder file | `holder` lines | 0, 1 if none |
| `lock_release <key>` | remove the lock if it is mine | `released` or `not-mine` | 0, 3 if held by another |
| `lock_force_unlock <key>` | remove regardless (human override) | holder lines, then `unlocked` | 0 |
| `lock_gc` | delete leftover `.stale-*` directories | none | 0 |

- Semantics:
  - `lock_state`: no dir is `none`; holder pid and start equal mine is `mine`; boot id known on both sides and different is `stale:rebooted`; pid dead, or alive with a different start time (PID reuse), is `stale:dead`; otherwise `held`. A dir with no readable `holder` whose mtime is older than 10 s is `stale:incomplete` (crash between `mkdir` and write); within 10 s it reads `held`.
  - `lock_acquire`: `mkdir` is the arbiter. On `EEXIST`, a `mine` state returns `mine` and refreshes nothing; `held` returns rc 3; `stale:*` takes over by `mv`-ing the directory to `.stale-<key>-<rand>` (atomic rename; only the winner of the rename retries `mkdir`), so two racing takers cannot both win. The leftover directory is removed by the winner or by `lock_gc`.
  - A live holder is never stolen; only a human using `lock_force_unlock` can remove it.
- Env overrides for tests: `LOCK_STATE_DIR`, `LOCK_SELF_PID`, `LOCK_SELF_SESSION`, `LOCK_BOOT_ID`, `LOCK_NOW` (epoch used for the crash grace). `LOCK_SELF_PID` may name a live `sleep` process the test spawns, so pid-alive and start-time checks run for real.

### 4.4 Callers (each a thin caller; skills only ever call `task_claim.sh` verbs)

| caller | what it does | library function |
|---|---|---|
| `task_claim.sh acquire` (`:552-575`) | before touching the claim, take this clone's lock; new rc 4 `seat-held:<pid>:<session>` when another live session holds this clone | `lock_acquire` |
| `task_claim.sh release`, `release-others` | unchanged; the lock is the clone's seat and persists while the agent lives | none |
| `task_claim.sh reclaimable` (`:642`) and `_tc_reclaim_decide` (`:288-340`) | when `claimed_by`'s host-part is this machine, ask the claimant clone's lock and pass the result as a new 7th argument | `lock_key_of`, `lock_state` |
| `reclaim_sweep.sh` (`:73-110`) | unchanged code path through `reclaimable`; its output line adds the reason (`dead`, `rebooted`) | via `reclaimable` |
| `task_claim.sh unlock <T<id>\|key>` (new verb) | human override for a frozen live holder | `lock_force_unlock` |
| `task_claim.sh pr-owner`, `_tc_decide`, `claim-state` in `todo/scripts/_lib.sh` | no change; `/todo next` already uses `reclaimable`, so it benefits automatically | none |
| `claim/SKILL.md` | delete Solo-repo mode; §1.2 note that `reclaimable` is now liveness-aware; document rc 4 and `unlock` | none |
| `drive/SKILL.md` Phase 1 (`:123-139`) | delete the solo bullet; same note and rc 4 handling | none |
| `address-pr` (`free` and `new` claim paths), `ccxp`, `autopilot` | call `acquire`, `release-others`, and the sweep as today and inherit the behavior | none |
| statusline | unchanged, out of scope | none |

### 4.5 How the lock result feeds acquire and reclaim (the incident)

- `acquire` is still strict. In the incident a new session in clone Y found `claimed_by` naming dead clone X on the same machine; `_tc_decide` returned `other`, so `acquire` printed `claimed:<cur>` and returned rc 3. That behavior stays; what changes is the `reclaimable` verdict the caller consults next.
- `_tc_reclaim_decide` gets a 7th argument `lock_state` (empty when not applicable). After the existing status and shape pre-checks, and keeping `live_signal` precedence:

| claim on `main` | `lock_state` of the claimant clone | verdict |
|---|---|---|
| empty | any | `live` (nothing to reclaim; existing rule) |
| human or legacy shape | any | unchanged (never reclaimable, or window) |
| host-part is another machine | not consulted | today's window rules |
| host-part is this machine | `held` or `mine` | `live` |
| host-part is this machine | `stale:dead`, `stale:rebooted`, `stale:incomplete` | `reclaimable` at once, skipping the commit and PR windows |
| host-part is this machine | `none` | migration rule: window rules until the rollout marker is older than `TASK_CLAIM_STALE_DAYS`, then `reclaimable` |

- The takeover is the existing flow: `/claim` §1.2 and `/drive` Phase 1 step 1 see `reclaimable`, then `release T<id> <status>` plus `acquire` in the claim PR. The sweep applies the same release. Only the waiting time changes.
- "host-part is this machine" is `claim_host == my_host` as in `_tc_is_own_cross_repo_clone` (`:893`).

### 4.6 Frozen and second sessions

- Live holder: never auto-stolen. A hung and a waiting-for-human session look identical. Human override: `task_claim.sh unlock T<id>` prints the holder and, with `--force`, removes the lock; killing the hung process instead turns the lock `stale:dead` with no override.
- Second independent session in a clone: `acquire` returns rc 4 and prints holder pid and session. Read-only verbs (`read`, `reclaimable`, `claimant-id`) are not guarded.
- Cron or autopilot tick: previous tick's pid is dead, so the new tick takes over silently. A tick that finds a live holder gets rc 4 and skips the clone, like any second session.

### 4.7 Failure modes

| failure | handling |
|---|---|
| crash between `mkdir` and writing `holder` | `stale:incomplete` after 10 s |
| PID reuse after wrap | start time differs, so `stale:dead` |
| `$CLAUDE_PID` unset and no `claude` ancestor | `lock_self` rc 2; `acquire` refuses to claim (fail closed, like `claimant-id.sh`) |
| boot id unreadable | treated as unknown, not changed; pid check still applies |
| lock directory removed by hand | next `acquire` simply creates it |
| two clones racing | different keys, no contention; `main` claim arbitrates the task as today |
| state dir on a shared network home | unsupported, documented |
| interrupted takeover | leftover `.stale-*` dirs are ignored and collected by `lock_gc` |

### 4.8 Tests

- New `tests/clone_lock.bats` for the library, with the env overrides in 4.3:
  - acquire with no lock; re-entrant `mine`; `held` by a live spawned process (rc 3); `lock_release` of mine and of another's.
  - dead-holder takeover (spawn, kill, acquire); PID reuse (same pid, injected different start); boot-id change (`LOCK_BOOT_ID`); boot id unknown does not count as changed.
  - two racing acquires from two background shells with distinct live `LOCK_SELF_PID`s: exactly one wins.
  - crash-before-write: empty dir, aged with `touch -t` or `LOCK_NOW`; `stale:incomplete` versus the 10 s grace.
  - `lock_force_unlock` output and effect; `lock_gc` removes `.stale-*`.
  - subagent same-pid case: a child process reusing the parent's `LOCK_SELF_PID` and session id gets `mine`.
  - `lock_key_of` for current, legacy, and human shapes.
- Existing files to update:
  - `tests/task_claim.bats`: `_tc_reclaim_decide` rows from 4.5; `acquire` rc 4; `reclaimable` end to end with a rebooted holder; `unlock`. Existing cases need a default `LOCK_SELF_PID` from `tests/test_helper.bash` so `acquire` does not refuse.
  - `tests/test_helper.bash`: a helper that sets `LOCK_STATE_DIR` and `LOCK_SELF_PID` per test, next to the existing `CLAIMANT_STATE_DIR` helper (`:62-68`).
  - `tests/reclaim_sweep.bats`: reason text, rebooted claim freed at once, foreign-host claim unchanged.
  - `tests/todo-next.bats`: `reclaimable` stub rows still pass; add one for a locally dead claimant.
  - Unchanged: `claimant_id.bats`, `statusline_setup.bats`, `attribution.bats`.

### 4.9 Migration

- No id, frontmatter, or `main` change. The first run creates `$LOCK_STATE_DIR/.v1` (marker). A same-host claim without a lock (made by a pre-lock version) keeps the window rules until the marker is older than `TASK_CLAIM_STALE_DAYS`; afterwards a missing lock means reclaimable. A clone's own claims are `mine` and need nothing; its first `acquire` creates its lock.
- The incident's own claim (no lock) would still wait for the window, so the fix covers claims made after rollout.
- Rollback: remove the `clone-lock.sh` calls; lock directories are inert.

### 4.10 Dropped

- Per-task locks, `claimed_by` at first push, no-claim-PR pickup, multiple sessions per clone, grace-period tables, ccxp-role exemption, idle thresholds, transcript-mtime reads, cron hand-off, and any statusline change.

## Open questions

- Interpretation chosen: lock key is the clone path-hash, so the guard answers "is this clone's agent alive" rather than "who holds task T"; this relies on "at most one claim per clone" staying enforced by `release-others`.
- Interpretation chosen: the lock persists for the life of the agent (no release at task close), because there is no session-end hook; a dead pid cleans it up lazily.
- Interpretation chosen: `live_signal` (in-progress CI run) still wins over a stale-holder verdict, to keep existing precedence.
- Is `CLAUDE_PID` set in every launch mode (`claude -p`, SDK, dispatched agents)? Verified only for an interactive session and its subagent; the PPID fallback needs a test per mode.
- Library name: `_session/clone-lock.sh` with `lock_*` functions (hyphenated like `claimant-id.sh`); rename if a different convention is preferred.
- Rollout marker window length: `TASK_CLAIM_STALE_DAYS` assumed.
- Share the host-local state dir and `CLAUDE_CONFIG_DIR` handling with `T20261012-342180` and `T20261002-303999`.

## Appendix: change surface if option A were adopted as written (for the record)

- Producers: `claimant_id` (`_session/claimant-id.sh:90-96`), `_tc_claimant_id` (`task_claim.sh:106-123`), statusline copy (`statusline-command.sh:24-70`).
- Parsers and comparers: `claimant_is_current_shape` (`claimant-id.sh:102`), `claimant_display` (`:114`), `_tc_decide` (`task_claim.sh:240`), `_tc_reclaim_decide` (`:288-340`), `_tc_is_legacy_self_claim` (`:493-517`), `_tc_acquire`, `_tc_release_others`, `_tc_is_own_cross_repo_clone` (`:860-890`), `_tc_pr_owner` (`:918-947`), `reclaim_sweep.sh:73-110`, `claim_gap.sh`, `task-state.sh:78-158`, `attribution.sh:106-160,218-241`, `todo/scripts/_lib.sh:33-66`, `epic/scripts/epic.sh`, `ccxp/scripts/epic-status.sh:151-167`, `retro/scripts/compute-velocity.sh:78-108`, `_ipm/ipm-iteration-drain-check.sh`, `migrate-task/scripts/migrate.sh`, `actions/sync-tasks/sync.py:614-636,790-795`.
- Docs: `lifecycle.md:93`, `glossary.md:23,29`, `_session/README.md:95-103`, `drive/SKILL.md:123-133`, `claim/SKILL.md:42-122,165-189`, `address-pr/SKILL.md:99-167`, `todo/SKILL.md:105,141`, `ccxp/SKILL.md:92-107,317,403`, `autopilot/SKILL.md:107`, `statusline-setup/SKILL.md:13`, `eta/SKILL.md:43-74`, `ipm/SKILL.md:66`.
- Tests: `tests/task_claim.bats` (~100 matches), `tests/claimant_id.bats` (~48), `tests/statusline_setup.bats`, `tests/attribution.bats`, `tests/todo-next.bats`, `tests/reclaim_sweep.bats`, `tests/claim_gap.bats`, `tests/task-state.bats`, `actions/sync-tasks/test_sync.py`.
- Prior decision to respect: the `T20260911-698434` journal ("Format alternatives considered") chose the two-field `cc1-<mid>:<hash>` shape because the value is parsed by YAML, grepped as a regex by the statusline, and split on the first `:`.
