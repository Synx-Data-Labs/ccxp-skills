---
status: Done
estimation: 1
source: conversation with Shine Zhang, 2026-10-06
related: T20260919-266165
claimed_by:
claimed_role:
---

# T20261006-227360: /autopilot must dispatch /drive at an explicit task, and /drive's own PR must always be addressed by explicit PR number

## TLDR

- **Type**: feature
- **Problem**: `/autopilot` dispatches `/drive` bare every cycle (task choice opaque to the
  orchestrator), and three `drive/SKILL.md` steps tell the reader to "run `/address-pr` on it"
  for a PR `/drive` itself just opened — without reiterating the explicit-number convention, so
  the instruction reads ambiguously close to a bare (auto-pick) call.
- **Solution**: `/autopilot` Phase 3 resolves `/todo next`'s #1 task itself and dispatches
  `/drive T<id> --auto-selected`; the new `--auto-selected` flag tells `/drive` the id is an
  orchestrator pick (not a human's deliberate single-task request), so Phase 0's PR-drain still
  runs even though an explicit id was given. The three ambiguous `/address-pr` call sites are
  reworded to capture and pass the PR number explicitly.

## Problem

- `autopilot/SKILL.md` Phase 3 (`autopilot/SKILL.md:109`) dispatches `/drive` bare (auto-pick)
  every cycle. Task selection happens inside the dispatched sub-agent's own `/todo next` call,
  invisible to `/autopilot` until the cycle's final report.
- `drive/SKILL.md` Phase 0's skip rule (`drive/SKILL.md:42`) is: "Skip Phase 0 when: the user gave
  an explicit task ID — they want that specific task worked on, not a PR sweep." If `/autopilot`
  starts passing an explicit id every cycle to fix the bullet above, this rule — unchanged —
  would **also** skip Phase 0's backlog PR-drain every cycle, which is a regression: today's bare
  dispatch gets PR-drain for free on every cycle via Phase 0's own unconditional run. The two
  behaviors (task-selection visibility, PR-drain-every-cycle) must both hold; the skip rule is
  the only thing standing between them because it conflates "an explicit id was given" with "a
  human deliberately wants to skip the backlog."
- Three sites in `drive/SKILL.md` instruct the reader to invoke `/address-pr` for a PR `/drive`
  itself just created, phrased as "run `/address-pr` on it" with no explicit number restated at
  the call site (unlike Phase 5's canonical `Use /address-pr <PR number>`, `drive/SKILL.md:430`):
  - `drive/SKILL.md:104` — the Phase 1 claim PR
  - `drive/SKILL.md:195` — the Phase 2 design PR
  - `drive/SKILL.md:566` — the Phase 7 cross-repo journal-move/close PR
  A bare `/address-pr` call auto-picks oldest-first across the **whole** backlog
  (`address-pr/SKILL.md` §1) — a different PR than the one the current step just opened. This
  matters more now that a GitHub-App bot gates PR approval (`pr-approve.yml`,
  `address-pr/SKILL.md` §2.d) — `/address-pr` must work the exact PR the current step owns.
- Context: surfaced during `/autopilot`'s first 24h run in `synxdb-build-pipeline` on 2026-10-06.
  That cycle's bare `/address-pr` call turned out to be Phase 0's documented backlog-drain
  (correctly handling PR #2499 and its claim-PR #3690) — not a live bug — but the user wants both
  gaps hardened given the new bot-gated approval flow.

## Context

- `/autopilot`'s `resume` path (`autopilot/SKILL.md` Phase 0.1, step 3) already dispatches
  `/drive T<last_task.id>` for one resumed cycle. This task generalizes that to every cycle.
- `drive/SKILL.md` already has precedent for a combinable boolean flag altering one phase's
  behavior without touching the others: `--dispatch-blockers` (`drive/SKILL.md:24-27`) changes
  only Phase 6 step 3's blocker-recursion mechanics.
- `/todo next` (`todo/SKILL.md` "Workflow: next") is a **read-only** deterministic scorer over
  `queue.md` + task frontmatter — it does not flip any task's status or write anything. Resolving
  the #1 pick in `/autopilot`'s own turn (before dispatch) does not race the dispatched `/drive`'s
  own claim mechanics — `/drive` Phase 1 still does the actual status flip + claim-PR, and its
  existing "claim-PR conflict = you lost the race" handling (`drive/SKILL.md:115`) already covers
  a peer grabbing the same task between `/autopilot`'s read and the dispatched `/drive`'s claim.
  `/todo sweep` is **not** read-only — its Step B (park recommendation, `todo/SKILL.md:194-209`)
  "always gets user sign-off first" before moving anything to `dev/PARKING/`. This is a
  **pre-existing** hazard, not introduced here: bare `/drive`'s own Phase 1 auto-pick already runs
  `/todo sweep` unconditionally today, including from an unattended dispatched sub-agent
  (`/autopilot`'s current bare-dispatch cycle, or a `/ccxp` cron run) — this task does not change
  who runs `sweep` or when, only which caller's turn computes the #1 pick. Out of scope here;
  worth its own follow-up if it proves to actually stall an unattended run in practice.

## Solution

1. **`drive/SKILL.md` Argument section** — add a new combinable flag:
   `--auto-selected` (combinable with the explicit-task-id form only — meaningless with bare
   `/drive`) — marks the given id as resolved by an orchestrating skill via the same
   `/todo sweep` + `/todo next` logic Phase 1's own auto-pick runs, not a human's deliberate
   single-task request.
2. **`drive/SKILL.md` Phase 0 skip rule** — change the condition from "the user gave an explicit
   task ID" to "a human gave an explicit task ID **without** `--auto-selected`". Explicitly state
   that `--auto-selected` does **not** skip Phase 0 — it only tells Phase 1 to skip re-deriving
   the pick, Phase 0's PR-drain is unrelated and still runs.
   - Alternative rejected: making Phase 0 run unconditionally always, and adding an opt-out flag
     instead. Rejected because a human's existing `/drive T<id>` muscle-memory (today's
     documented behavior: explicit id skips the sweep) must not silently change for every current
     caller — only the new orchestrator caller opts into the different behavior.
3. **`autopilot/SKILL.md` Phase 3** — before dispatching, resolve the next task id in-turn:
   invoke `/todo sweep` then the `/todo next` read-only scoring logic, take the #1 pick's task id,
   and dispatch `/drive T<id> --auto-selected` (instead of bare `/drive`). Update the
   self-contained dispatch-prompt text accordingly. No change to Phase 4's classification logic
   or the state-file schema — `last_task` continues to be populated the same way it is today.
   - Alternative rejected: having `/autopilot` dispatch a *second* sub-agent just to run
     `/todo next` and report back the id. Rejected — `/todo next`'s logic is a deterministic,
     read-only file read; running it inline in `/autopilot`'s own turn costs nothing extra and
     keeps the selection visible/loggable in the orchestrator's own transcript, which is the
     actual goal.
4. **Reword the three ambiguous `/address-pr` call sites** (`drive/SKILL.md:104`, `:195`, `:566`)
   to capture the PR number `gh pr create` just returned and say `` /address-pr <number> ``
   explicitly, with a short parenthetical: "never a bare call — a bare call re-triggers Phase 0's
   oldest-first backlog auto-pick, not this step's own PR."

## Test plan

- [x] `drive/SKILL.md` renders clean (`bash ../_docs/lint-docs.sh drive/SKILL.md`)
- [x] `autopilot/SKILL.md` renders clean (`bash ../_docs/lint-docs.sh autopilot/SKILL.md`)
- [x] Manual re-read of all 14 lines mentioning `/address-pr` in `drive/SKILL.md`
      (`grep -c /address-pr drive/SKILL.md` → 14, unchanged by this PR) confirming the 3 ambiguous
      sites now name an explicit number and the already-correct ones (Phase 0's intentional bare
      call, Phase 5's `<PR number>`) are untouched
- [x] Manual re-read confirming the Phase 0 skip-rule wording is unambiguous for both the
      pre-existing human-explicit-id caller and the new `--auto-selected` orchestrator caller
- [x] CI green on the implementation PR (`skill-quality`, `Markdown Lint`, `lint-tasks`)

## Done criteria

- [x] `autopilot/SKILL.md` Phase 3 resolves and passes an explicit `T<id>` (with
      `--auto-selected`) to every dispatched `/drive` cycle, not just on resume —
      `autopilot/SKILL.md:109-122`
- [x] `drive/SKILL.md` Phase 0 cannot be silently skipped by an orchestrator-resolved id —
      `drive/SKILL.md:28-31` (Argument section) + `:47` (skip-rule wording)
- [x] None of the three audited `/address-pr` call sites in `drive/SKILL.md` can be read as a bare
      (unscoped) call for `/drive`'s own just-created PR — `drive/SKILL.md:109,200,572` reworded

## Closed (2026-10-06)

Shipped in **PR #278** (implementation PR; design in PR #277, claim in PR #276).

- All three done criteria met — see `file:line` anchors above, verified against the committed
  diff (not just the edited-in-memory draft) before opening the PR.
- Independent review (dispatched agent, `superpowers:receiving-code-review`) on the design PR
  caught two real issues before implementation: a mischaracterization of `/todo sweep` as
  read-only (fixed — it has an interactive park-approval step, called out as a pre-existing,
  out-of-scope hazard) and a stale grep-count in the test plan (13 → 14 lines). Both fixed in
  PR #277 before merge.
- While implementing, found and fixed two stale `drive/SKILL.md:426,636` line-number citations in
  `autopilot/SKILL.md` that this change's own line-count shift would have broken — replaced with
  phase-name anchors (Phase 5's wait instruction + its "Background waits are not blockers" note)
  so they don't rot on the next `drive/SKILL.md` edit.
- No follow-up tasks filed — the `/todo sweep` interactive-gate hazard noted in Context is
  pre-existing (not introduced by this change) and only worth a follow-up if it's actually
  observed to stall an unattended run in practice.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (SKILL.md prose only, no code)
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6, re-grepped the
  committed diff for all three done-criteria before opening the PR
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes — design PR #277's independent
  review surfaced 2 real findings (see Closed above), both fixed before merge
