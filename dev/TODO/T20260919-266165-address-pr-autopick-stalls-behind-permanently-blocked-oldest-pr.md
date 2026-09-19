---
status: Open
estimation: 2h
source: Discovered 2026-09-19 during a synxdb-build-pipeline autopilot run — bare /address-pr auto-pick never reached any of that session's own open PRs
related: T20260622-404636 (PR ownership derivation — the mechanism this bug interacts with)
---

# T20260919-266165: `/address-pr`'s bare auto-pick silently stalls forever behind a permanently-blocked oldest PR

## Problem

`/address-pr`'s auto-pick (§1) is `sort_by(.createdAt) | .[0]` — strictly the single oldest open
PR authored by us. If that PR's task is owned by another agent (or, per this instance, by a human
via `owner: Ed` in the task frontmatter) and stays open indefinitely, auto-pick **defers silently
and exits** every single invocation — it never falls through to the next-oldest PR.

Concretely observed 2026-09-19 in `synxdb-build-pipeline`: PR
[#1841](https://github.com/Synx-Data-Labs/synxdb-build-pipeline/pull/1841) (open since 2026-06-30,
`owned:Ed`) is the oldest open PR authored by us. `/drive`'s Phase 0 (which calls bare
`/address-pr` once per cycle) checked it and deferred on 5+ separate autopilot cycles in a row
(cycles 6-11 that day) — correctly, per the ownership guard — but never once reached any of the
~10 *other* open PRs that same session opened and needed to drive to merge. Every one of those had
to be addressed by explicitly naming the PR number instead of relying on auto-pick.

**Impact**: as long as a permanently-stuck oldest PR stays open, `/drive`'s Phase 0 "make one
forward move on the PR backlog" step is a **permanent no-op** for every other open PR — an
unattended `/ccxp`/`/autopilot` loop would never merge a completed implementation PR unless a
human (or a session that happens to know the PR number) explicitly names it, since nothing in the
auto-pick path ever looks past position 0.

## Suggested fix

`/address-pr`'s auto-pick should walk the oldest-first list and pick the first PR that is **not**
deferred by the ownership/authorship gates (§1.3/§1.6), rather than stopping at the very first
entry regardless of its verdict — mirroring how `/todo next`'s walk already skips over
peer-claimed/frozen tasks instead of returning only the literal #1 queue slot. The auto-pick query
would need to check ownership for each candidate (in creation order) until it finds one that
resolves to `mine`/`free`/`untracked`, not just the first one.

## Test plan

- [ ] BATS/manual: with a fixture list of 3 open PRs where the oldest is `owned:<other>`, auto-pick
      selects the 2nd-oldest instead of deferring entirely
- [ ] Confirm the existing single-PR defer behavior is unchanged when *no* other PR is pickable

## Repo file references

| File | Purpose |
|---|---|
| `address-pr/SKILL.md` §1 | The `sort_by(.createdAt) \| .[0]` auto-pick this task changes |
| `drive/SKILL.md` Phase 0 | Calls bare `/address-pr` once per cycle — the caller most affected |
