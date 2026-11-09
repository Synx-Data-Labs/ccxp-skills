---
status: Design
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
  - At session start and at each user turn or autopilot wake, you may run ONE `git -C <session repo> fetch origin` (no `--prune`, no other remote, never a pull); it only updates remote-tracking refs, then continue; a failure (offline, auth) is ignored silently.
  - Never pull, check out, merge, rebase, reset, stash or clean the owner's clone; it is often on a non-main branch with uncommitted work.
  - Quick lookups of repo state (queue, task files, journal) read `origin/<default>` with `git show origin/<default>:<path>` or `git ls-tree`, where the default is `git symbolic-ref --short refs/remotes/origin/HEAD`; say when you answer from the working tree instead.
  - Jobs already fetch origin before creating worktrees; do not fetch for them.
- Bash carve-out wording (`ccxp-agent.md:19`): add "`git fetch origin` in the session repo (remote-tracking refs only, see \"Repo freshness\")" to the closed list, and say it writes only `.git` remote-tracking refs.
- Alternatives rejected:
  - Pull or fast-forward the clone: unsafe on a dirty or non-main branch, which is the common state.
  - Fetch inside a hook or timer: no background watcher exists and the persona has no clock; the per-turn cadence matches CI detection.
  - Leave it to jobs: quick inline lookups would stay stale, which is the owner's complaint.

## Test plan

- [ ] `tests/agent_pairing.bats`: new asset test asserts the section, the single fetch, the never-pull/checkout/merge/reset sentence, the `origin/<default>` lookup rule and the carve-out wording are present in `agent-pairing/assets/ccxp-agent.md`.
- [ ] Existing persona tests (`tests/agent_pairing.bats`, `tests/agent_pairing_jobs.bats`, persona-refresh hook tests) stay green: `bats tests/agent_pairing*.bats`.
- [ ] `claude plugin validate .`-style frontmatter unchanged: the persona's `tools:` line and `description:` are not edited.
- [ ] Doc impact: `agent-pairing/persona-refresh.md` needs no change (the hash-based refresh is generic); `agent-pairing/SKILL.md` re-read for a stale "read-only Bash" statement.

## Done criteria

- [ ] Persona has the "Repo freshness" section with the four rules: new bats asset test.
- [ ] Bash carve-out list names the fetch: `ccxp-agent.md:19` plus the same asset test.
- [ ] Persona size not materially grown (under 1 KB added) and refresh tests pass: `bats tests/agent_pairing*.bats`.
- [ ] No plugin version bump, tag or release in this PR: diff review.

## Closed

- Pending.

## Skills invoked

- Pending.
