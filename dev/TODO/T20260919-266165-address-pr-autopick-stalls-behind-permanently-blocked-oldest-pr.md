---
status: Design
estimation: 2h
source: Discovered 2026-09-19 during a build-pipeline-repo autopilot run — bare /address-pr auto-pick never reached any of that session's own open PRs
related: T20260622-404636 (PR ownership derivation — the mechanism this bug interacts with)
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260919-266165: `/address-pr`'s bare auto-pick silently stalls forever behind a permanently-blocked oldest PR

## TLDR

- **Type**: bug
- **Problem**: `/address-pr`'s bare auto-pick (`sort_by(.createdAt) | .[0]`) only ever looks at
  the single oldest open PR — if its task is owned by someone else, auto-pick defers and exits,
  and never reaches any *other* open PR, forever, as long as that one PR stays open.
- **Solution**: walk the oldest-first list and pick the first PR whose ownership verdict is
  `mine`/`free`/`untracked`/`new` (per `task_claim.sh pr-owner`), skipping `owned:*`/`unknown`
  candidates instead of stopping at position 0 — mirroring `/todo next`'s existing walk-and-skip
  pattern. Extracted into a bundled, BATS-tested script per the `skill-conventions` §9 convention
  (deterministic logic → bundled scripts), since the walk itself is a pure read/transform with no
  judgment call.

## Problem

`/address-pr`'s auto-pick (§1) is `sort_by(.createdAt) | .[0]` — strictly the single oldest open
PR authored by us. If that PR's task is owned by another agent (or, per this instance, by a human
via `owner: Ed` in the task frontmatter) and stays open indefinitely, auto-pick **defers silently
and exits** every single invocation — it never falls through to the next-oldest PR.

Concretely observed 2026-09-19 in `build-pipeline-repo`: PR
[#1841](https://github.com/your-org/build-pipeline-repo/pull/1841) (open since 2026-06-30,
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

## Context

- `/address-pr`'s bare invocation (`/address-pr` with no arg) is the only path affected — an
  explicit `/address-pr <number>` already bypasses auto-pick entirely (§1: "If `<arg>` is a
  number, use it directly").
- The per-PR ownership verdict already exists and is authoritative: `task_claim.sh pr-owner
  <number>` (`_session/task_claim.sh:800`) returns `mine | free | new | owned:<by> | untracked |
  unknown`, derived from the implementing task's `claimed_by` on `main` (§1.6). This task does not
  change that resolution logic at all — it only changes *how many* candidates auto-pick is willing
  to check before giving up.
- `/todo next` (`todo/scripts/todo-next.sh`) already solves the analogous problem for the task
  backlog queue: it walks top-to-bottom and skips peer-claimed entries instead of returning only
  the literal #1 slot (T20260914-359646). This task ports that same shape to PR auto-pick.
- `skill-conventions/SKILL.md` §9 (T20260918-174144, merged just before this design) requires
  deterministic/mechanical skill-workflow logic (a walk + per-item classification, no judgment
  calls) to live in a bundled, tested script rather than a `jq` one-liner in prose — this is
  exactly that shape, so the fix is implemented as a new script, not a prose edit to the `jq`
  filter.

## Solution

Replace the inline `sort_by(.createdAt) | .[0]` one-liner in `address-pr/SKILL.md` §1 with a call
to a new bundled script, `address-pr/scripts/auto-pick.sh`:

- Lists open PRs authored by `@me` (`gh pr list --author @me --state open --json
  number,title,createdAt`), sorted oldest-first — same source data as today.
- Walks the sorted list in order; for each PR calls `task_claim.sh pr-owner <number>` (the
  existing, unchanged §1.6 resolver).
- Returns the **first** PR whose verdict is `mine`, `free`, `new`, or `untracked` (the same set
  §1.6 already treats as "proceed") as a single-line JSON object (`{"number":...,"title":"...",
  "createdAt":"...","reason":"<verdict>"}`), on stdout.
- Skips (does not pick) any PR whose verdict is `owned:<other>` or `unknown`, and continues to the
  next-oldest candidate — diagnostic detail (which PRs were skipped and why) goes to stderr, so
  stdout stays machine-parseable.
- **Accepted trade-off (flagged in independent review of this design):** a transient `unknown`
  (e.g. a flaky `gh`/fetch call) on an otherwise-`mine` true-oldest PR now causes the walk to skip
  past it and possibly auto-pick a lower-priority PR instead, whereas today's single-candidate
  check would defer entirely (safer but fully blocked). This is accepted as-is, not retried: §1.6
  already treats every `unknown` as fail-safe-skip with no retry today (`_tc_pr_owner`,
  `_session/task_claim.sh:834`'s `_tc_fetch_fm_field` failure path), so this task's walk inherits
  an existing, unaddressed characteristic rather than introducing a new one — adding retry logic
  here would be scope creep beyond the stalling-forever bug this task fixes. The next `/drive`
  cycle re-resolves ownership fresh, so a transient miss self-heals within one cycle.
- If every open PR is deferred (or there are none), prints nothing on stdout and exits 0 — same
  observable behavior as today's "no open PRs to address" / "defers silently" outcome, just
  reached only after actually checking every candidate instead of stopping at position 0.
- `address-pr/SKILL.md` §1's auto-pick bullet is rewritten to call this script and branch on
  whether it printed a PR object.

**Resolution order is unchanged** (oldest-first) — this only changes the *stopping rule* from
"stop at the first candidate, always" to "stop at the first *pickable* candidate, else stop at the
end of the list." A PR that's `owned:<other>` today still never gets auto-picked; it just no
longer blocks every PR behind it.

**Alternatives considered and rejected:**

- *Leave the fix as a prose-only edit to the `jq` filter in `SKILL.md`* — rejected: the walk needs
  a per-candidate side-effecting call (`task_claim.sh pr-owner`) that `jq` alone cannot express: a
  script is unavoidable to make the loop testable, and §9 requires exactly this extraction.
- *Have auto-pick fall through to interactive escalation ("ask the user which PR") when the oldest
  is blocked* — rejected: over-engineered for what's fundamentally a mechanical skip; the whole
  point of `/todo next`'s pattern (and this task's parallel) is that a deferred-but-skippable
  candidate needs no human judgment at all.
- *Re-sort by something other than `createdAt` (e.g., "oldest pickable first" computed differently)*
  — rejected: changes today's well-understood priority order (oldest wins) for no benefit; the bug
  is the *stopping rule*, not the *order*.

## Root cause

- The `sort_by(.createdAt) | .[0]` auto-pick has existed unchanged since this repo's initial
  public split (`890c1ce`, "Initial public release") — it predates this repo's own git history, so
  no finer-grained archaeology is available here.
- The PR-ownership resolver it now composes with (`task_claim.sh pr-owner`, §1.6) was designed and
  documented for the *has this specific PR been vetted* question, not *which PR should auto-pick
  choose* — the two pieces were never revisited together. This reads as an **oversight of
  composition**, not a deliberate choice: the bug report itself (`## Problem` above) is the first
  recorded instance of anyone noticing the interaction, and nothing in `address-pr/SKILL.md`'s
  history suggests the single-candidate limit was intentional once §1.6's ownership gate existed.

## Test plan

- [ ] BATS (`tests/address_pr_auto_pick.bats`, hermetic — `GH_SH`/`TASK_CLAIM_SH` overridden to
      fixture stub scripts, no network): with a fixture list of 3 open PRs where the oldest is
      `owned:<other>`, auto-pick selects the 2nd-oldest instead of deferring entirely
      (`auto-pick.sh` prints the 2nd-oldest PR's JSON object).
- [ ] BATS: existing single-PR defer behavior is unchanged when *no* other PR is pickable (all
      candidates `owned:*`/`unknown` → script prints nothing, exit 0).
- [ ] BATS: an `unknown` verdict candidate is skipped (fail-safe — never picked), same as
      `owned:*`.
- [ ] BATS: with zero open PRs, script prints nothing, exit 0 (unchanged from today).
- [ ] Manual: `bash address-pr/scripts/auto-pick.sh` against this repo's real open PRs after
      implementation — confirms the real `GH_SH`/`TASK_CLAIM_SH` default resolution works (not
      just the stubbed test path).

## Done criteria

- [ ] `address-pr/scripts/auto-pick.sh` walks oldest-first and skips `owned:*`/`unknown`, picking the first `mine`/`free`/`new`/`untracked` candidate — `tests/address_pr_auto_pick.bats`.
- [ ] `address-pr/SKILL.md:27`'s auto-pick bullet calls `auto-pick.sh` instead of the inline `sort_by(.createdAt) | .[0]` jq filter — diff review in the implementation PR.
- [ ] Behavior-parity gate (skill-conventions §9): `tests/address_pr_auto_pick.bats` proves the new script's stopping rule is a strict superset of today's (still defers, exit 0, empty stdout, when nothing is pickable).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `address-pr/SKILL.md` §1 | auto-pick bullet | The `sort_by(.createdAt) \| .[0]` one-liner this task replaces with a script call |
| `address-pr/scripts/auto-pick.sh` | new | The walk-and-skip auto-pick script this task adds |
| `_session/task_claim.sh:800` (`_tc_pr_owner`) | 800-845 | The unchanged per-PR ownership resolver the new script calls once per candidate |
| `todo/scripts/todo-next.sh` | whole file | The worked-example walk-and-skip pattern this task ports (T20260914-359646) |
| `drive/SKILL.md` Phase 0 | | Calls bare `/address-pr` once per cycle — the caller most affected by this fix |
