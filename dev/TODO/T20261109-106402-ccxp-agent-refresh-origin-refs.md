---
status: In Progress
estimation: 1
source: owner request, this conversation, 2026-11-09
description: ccxp-agent persona may run one read-only git fetch origin per turn and read repo state from origin/<default>
claimed_by: cc1-9f320372:f9b2137c9918a8ee
claimed_role: interactive
scheduled: 2026-11-09
---

# T20261109-106402: ccxp-agent refreshes origin refs, never the owner's clone

## TLDR

- **Type**: feature
- **Problem**: the dispatcher answers quick repo lookups from a working tree that lags origin, and its Bash is read-only with a closed carve-out list that does not cover a fetch.
- **Solution**: add a short persona section: one read-only `git fetch origin` per session start and per wake or turn, and quick lookups read `origin/<default>`; never pull, check out, merge or reset the owner's clone.

## Problem

- Owner asked whether the ccxp-agent should always refresh the clone it works on, since a stale clone gives stale queue and task-file answers.
- The persona allows inline "read-only Bash like `git status`/`git log`/`ls`" and lists carve-outs (`agent-pairing/assets/ccxp-agent.md:19`); `git fetch` writes remote-tracking refs, so it is not obviously read-only and is in no carve-out.
- The owner's clone is often on a non-main branch with uncommitted work, so any pull, checkout, merge or reset is unsafe.

## Context

- Verified: the persona is 205 lines and about 42 KB; no test or lint in `tests/agent_pairing*.bats` or `hooks/` caps its size, and `hooks/persona-check.sh` only compares the installed file with the bundled asset by hash, so an edit refreshes by itself with the next plugin version.
- Verified: for a job on a different repo the persona already requires `git -C <clone> fetch origin` before `git worktree add` (`ccxp-agent.md:99`, "Other-repo isolation"). For the same repo as the session cwd, `isolation: "worktree"` is harness-made and not stated to fetch; the new rule says the dispatcher's own fetch keeps `origin/<default>` current for it.
- The CI-failure detection already runs one read-only `gh run list` per turn and wake (`ccxp-agent.md:43`): the same cadence is reused, no new loop.
- Assumed: the harness's worktree isolation branches from the clone's HEAD; not changed here.

## Solution

- New section "Repo freshness" in `agent-pairing/assets/ccxp-agent.md`, placed after "On session start" (about 6 bullets, no more):
  - At session start, and at a user turn or autopilot wake only when you are about to answer a repo-state lookup and the last fetch is older than about 5 minutes (no clock: judge from `FETCH_HEAD` mtime, `stat`), you may run ONE fetch: `GIT_TERMINAL_PROMPT=0 git -C <session repo> -c gc.auto=0 fetch --quiet --no-tags --no-recurse-submodules origin` (never `--prune`, no other remote, never a pull). It updates remote-tracking refs inside `.git` (and `FETCH_HEAD`); nothing in the working tree or index. Keep it short (`timeout 15` where available).
  - If the fetch fails (offline, auth), carry on, but say the answer comes from possibly stale origin refs instead of presenting it as fresh.
  - Never pull, check out, merge, rebase, reset, stash or clean the owner's clone; it is often on a non-main branch with uncommitted work.
  - Quick lookups of repo state (queue, task files, journal) read `origin/<default>` with `git show origin/<default>:<path>` or `git ls-tree`, where the default is `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), else `main`, else `master`; with no `origin`, or outside a git repo, read the working tree and say so.
  - A job for a different repo already fetches origin before creating its worktree ("Other-repo isolation"); the dispatcher's own fetch only keeps the session repo's `origin/<default>` current. Do not fetch on a job's behalf.
- Bash carve-out wording (`ccxp-agent.md:19`): add "the single `git fetch origin` of \"Repo freshness\" (writes only remote-tracking refs and `FETCH_HEAD` inside `.git`)" to the closed list; keep the phrase `Bash is read-only except this closed list of carve-outs` and the existing carve-out phrases verbatim (asserted by `tests/agent_pairing.bats` and `tests/terms.bats:575`).
- Alternatives rejected:
  - Pull or fast-forward the clone: unsafe on a dirty or non-main branch, which is the common state.
  - Fetch inside a hook or timer: no background watcher exists and the persona has no clock; the per-turn cadence matches CI detection.
  - Leave it to jobs: quick inline lookups would stay stale, which is the owner's complaint.

## Test plan

- [x] `tests/agent_pairing.bats`: new asset test asserts the section, the single fetch, the never-pull/checkout/merge/reset sentence, the `origin/<default>` lookup rule and the carve-out wording are present in `agent-pairing/assets/ccxp-agent.md`.
- [x] Existing persona tests stay green: `bats tests/agent_pairing*.bats tests/terms.bats tests/persona_check.bats`, then the full `bats tests/*.bats` in CI.
- [x] Persona frontmatter lines 1-5 unchanged (diff review).
- [x] Doc impact: `agent-pairing/persona-refresh.md` needs no change (the hash-based refresh is generic); `agent-pairing/bg-jobs.md` does not restate the carve-out list, so no change.

## Done criteria

- [x] Persona has the "Repo freshness" section with the four rules: new bats asset test.
- [x] Bash carve-out list names the fetch: `ccxp-agent.md:19` plus the same asset test.
- [x] Persona grows by under 1.5 KB (`wc -c` before 43095 and after) and persona tests pass: `bats tests/agent_pairing*.bats tests/terms.bats tests/persona_check.bats`.
- [x] No plugin version bump, tag or release in this PR: diff review.

## Closed

- Pending.

## Skills invoked

- Pending.
