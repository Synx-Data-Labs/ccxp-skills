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
- Incident: a machine restart left a task `In Progress` under a dead session's `claimed_by`.
  - Same machine, different clone-path hash, so `_tc_decide` said `other` (`_session/task_claim.sh:240`) and the reclaim sweep said `live`.
  - It had to be reclaimed by hand. The sweep waits for BOTH `commit_days` and `pr_days` to exceed `TASK_CLAIM_STALE_DAYS` (default 2; `task_claim.sh:288-340`), and it has no local liveness signal.
- The claim is "heartbeat-free by design" (`ccxp/SKILL.md:92`): a dead session's claim is only freed by that stale window, so a restart strands work for up to 2 days.
- Done looks like: a claim whose owning session is provably gone (same host) is reclaimable at the next sweep or pick, not after 2 days. Foreign-host claims behave exactly as today.

## User proposal (as stated)

- Change `claimed_by` from `cc1-<machine-id>:<path-hash>` to `cc1-<machine-id>:<PID>` (plain PID, no hash).
- Reasoning: same host + different PID means a different session. If the PID is gone, the claim is an orphan and can be reclaimed.

## Recommendation: adopt with modifications

- Keep the goal (reclaim orphans by PID) and keep the public id clone-stable.
  - Put PID liveness in a machine-local record instead of in `claimed_by`.
  - The user's inference is right in one direction only: same host + dead PID means the session is gone. A live PID does not mean the same session, and a new PID does not mean the clone is a new claimant.
- Do not make the PID the claim id. The three strongest reasons:
  - It breaks "same clone = same claimant". After every restart, resume, or `claude -p` cron tick the new PID would see its own previous claims as `other`.
    - `release-others` (`task_claim.sh:592-640`) matches `claimed_by = mine`, so it can no longer free the clone's earlier tasks and "<=1 claim per clone" fails.
    - The statusline (`statusline-command.sh:38-70`) greps `claimed_by` equal to the clone id and would stop finding the task.
    - This is the restart-recovery problem again, one level up.
  - Every session would write a new `claimed_by` value into git on `main`: churn, plus a claim PR for each takeover of an unchanged task.
  - A PID is a recyclable integer. Without a start time or boot id, a recycled PID (macOS wraps at 99999) would keep a dead claim looking alive.
- Verified on this box (2026-10-19):
  - The per-call shell PID changes on every Bash call (`$$` and `$BASHPID` differ per call); its parent is stable.
  - `$CLAUDE_PID` equals the `claude` process (`claude --resume <session-id>`).
  - A dispatched subagent sees the same `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` as its parent.
  - The session id survives `--resume`, but a resumed session has a new PID.
  - `ps -o lstart=` gives a process start time, and `sysctl kern.boottime` (macOS) or `/proc/sys/kernel/random/boot_id` (Linux) gives a boot id.
  - Nothing in the repo reads `CLAUDE_PID` yet; only `CLAUDE_CODE_SESSION_ID` is used (`_session/_lib.sh:108`).

## Evaluation of the points raised

- **(a) PID is per session, not per clone.** This is the decisive downside.
  - One real gain: a PID id would make `_tc_is_own_cross_repo_clone` (`task_claim.sh:860-890`) unnecessary, because the hub clone and the ephemeral `<task-id>-*-target` clone belong to one `claude` process.
  - That gain only holds if `/address-pr` runs in the same process. A cron or autopilot dispatch starts a new one, so the path-based recognition would still be needed.
- **(b) PID reuse.** A bare PID is unsafe. Record `pid + ps lstart` (start time), and a boot id so a reboot kills every local claim at once. The check is "pid alive AND start time equal AND boot id equal".
- **(c) Liveness is same-host only.** For a foreign `cc1-<other-machine>` claim, PID checks say nothing; the existing heuristics still apply unchanged (commit and PR staleness window, open PR activity, `_tc_has_live_run`).
  - The sweep must therefore stay two-tier: a same-host fast path from the local record, then the unchanged staleness window.
  - `reclaim_sweep.sh:73-110` only needs a new "local record says dead" input to `_tc_reclaim_decide`; its existing `live_signal` parameter is the natural slot.
- **(d) Churn on `main`.** With the PID in `claimed_by`, every new session writes a fresh value into the task file, causing git churn, claim-PR traffic and more merge-conflict surface (the conflict on that line is the lock, `task_claim.sh:8`). A local record writes nothing to git.
- **(e) Cron and autopilot.**
  - `/ccxp` hourly ticks and `/autopilot` dispatches run in short-lived `claude -p` processes, but their claims legitimately span many ticks. Autopilot deliberately reuses one clone so the id stays stable (`autopilot/SKILL.md:107`).
  - Pure PID liveness would show an in-flight cron claim as dead between ticks and let a peer steal it.
  - Mitigation: PID-dead only shortens the window to a short grace period, never to zero. Boot-id change is the exception and may reclaim at once.
- **(f) Subagents and forks.** They share the parent `CLAUDE_PID`, so they share the claim. This works for a local record and for a PID id alike.
- **(g) Alternatives:**

| option | verdict |
|---|---|
| A. PID in `claimed_by` (proposal) | rejected: breaks clone-stable identity, release-on-pickup, statusline, autopilot; adds churn; needs start-time and boot-id anyway |
| B. Keep id; machine-local record `claims/<task-id>` with `{pid, lstart, boot, session_id}`, written at `acquire`, read by sweep and pick | **recommended**: no frontmatter change, no git churn, no lint or board changes, same-host only (by design) |
| C. `claimed_pid:` / `claimed_at:` in frontmatter | rejected: published PID is meaningless off-host, stale as soon as the session restarts, more churn, and the new key needs allowlisting in `lint_tasks.py:23-26` and `sync.py:614` |
| D. Heartbeat or lease timestamp committed to `main` | rejected: contradicts "heartbeat-free by design" (`ccxp/SKILL.md:92`), commit flood, conflict flood |
| E. Boot-id only | subset of B: fixes the restart incident cheaply but not a crash or kill; build it first inside B |

## Proposed design (B, to be confirmed)

- On `acquire`/`none` (`task_claim.sh:567-573`), also write `$CLAIMANT_STATE_DIR/claims/<task-id>.json` (mode 600, never committed) with `claude_pid` (`$CLAUDE_PID`, else the `claude` ancestor via the PPID chain), its `lstart`, the boot id and `CLAUDE_CODE_SESSION_ID`. `release`/`release-others` delete it.
- New pure helper, e.g. `claimant_session_alive <task-id>`, printing `alive | dead | unknown` (`unknown` = no record, foreign host, or unreadable). It lives next to `claimant-id.sh` (side-effect free) or in `task_claim.sh`.
- `_tc_reclaimable` feeds it into `_tc_reclaim_decide`:
  - `dead` on the same machine-id: reclaimable after a short grace (open question: 30 min?), or at once when the boot id differs.
  - `alive`: `live` regardless of activity staleness.
  - `unknown`: today's behavior, unchanged.
- `_tc_acquire` on an `other` claim from the same machine-id also consults it, so a pick does not need the sweep to run first.
- Reclaim stays a normal `release` through the existing sweep PR flow (`ccxp/scripts/reclaim-sweep-pr.sh`), never a silent edit.
- No new frontmatter key, so `lint_tasks.py` ALLOWED needs no change (only option C would add one). Format and shape arms (`claimant_is_current_shape`, `cc1-` one-way-door arm at `task_claim.sh:310-322`) stay untouched.

## Change surface if the proposal were adopted as written (for the record)

- Producers: `claimant_id` (`_session/claimant-id.sh:90-96`), `_tc_claimant_id` (`task_claim.sh:106-123`), statusline copy (`statusline-command.sh:24-70`).
- Parsers and comparers: `claimant_is_current_shape` (`claimant-id.sh:102`), `claimant_display` (`:114`), `_tc_decide` (`task_claim.sh:240`), `_tc_reclaim_decide` (`:288-340`), `_tc_is_legacy_self_claim` (`:493-517`), `_tc_acquire` (`:552-575`), `_tc_release_others` (`:592-640`), `_tc_is_own_cross_repo_clone` (`:860-890`), `_tc_pr_owner` (`:918-947`), `reclaim_sweep.sh:73-110`, `claim_gap.sh`, `task-state.sh:78-158`, `attribution.sh:106-160,218-241`, `todo/scripts/_lib.sh:33-66`, `epic/scripts/epic.sh`, `ccxp/scripts/epic-status.sh:151-167`, `retro/scripts/compute-velocity.sh:78-108`, `_ipm/ipm-iteration-drain-check.sh`, `migrate-task/scripts/migrate.sh`, `actions/sync-tasks/sync.py:614-636,790-795`.
- Docs: `lifecycle.md:93`, `glossary.md:23,29`, `_session/README.md:95-103`, `drive/SKILL.md:123-133`, `claim/SKILL.md:42-122,165-189`, `address-pr/SKILL.md:99-167`, `todo/SKILL.md:105,141`, `ccxp/SKILL.md:92-107,317,403`, `autopilot/SKILL.md:107`, `statusline-setup/SKILL.md:13`, `eta/SKILL.md:43-74`, `ipm/SKILL.md:66`.
- Tests: `tests/task_claim.bats` (~100 matches), `tests/claimant_id.bats` (~48), `tests/statusline_setup.bats`, `tests/attribution.bats`, `tests/todo-next.bats`, `tests/reclaim_sweep.bats`, `tests/claim_gap.bats`, `tests/task-state.bats`, `actions/sync-tasks/test_sync.py`.
- Prior decision to respect: `T20260911-698434` journal ("Format alternatives considered") chose the two-field `cc1-<mid>:<hash>` shape because the value is parsed by YAML, grepped as a regex by the statusline, and split on the first `:`; a new shape must pass the same constraints and keep a one-way-door reader arm for old values.

## Open questions

- Grace period for "dead PID, same host": 0 (boot change only), 30 min, or 2 h? It must exceed the gap between cron ticks when the claimant is a `claude -p` run.
- Should `claimed_role: ccxp` claims (cron or autopilot) be exempt from the dead-PID fast path, and rely only on boot-id change?
- Where does the local record live given `CLAUDE_CONFIG_DIR` (`~/.claude/state` is the default today; see `T20261002-303999`)? Share one machine-local store with `T20261012-342180` (claimant reverse lookup).
- Two live sessions in one clone share one claimant id: is a per-task record enough, or must "alive" mean any recorded session alive?
- Is `CLAUDE_PID` set in every launch mode (`claude -p`, SDK, dispatched agents)? Fall back to the PPID chain and test it.
- Does a human-override or legacy `<sid>@<machine>` claim ever get a record? Proposed: no, keep today's rules.
- Do we still want the original ask (id literally `host:PID`) after reading the above? If yes, record the decision to drop clone-stable ids and the release-on-pickup invariant explicitly.
