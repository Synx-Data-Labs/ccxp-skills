---
status: Open
estimation: 1
source: this conversation, 2026-10-20 (user: "refactor the skill to automate the entire lifecycle of addressing the customer issue from triage to deliver")
related: [T20261012-333879, T20261012-373882, T20261012-949870, T20261012-383399]
description: Orchestrator design (inversion of control) and implementation driving a synxdb-support issue end to end, triage through deliver
---

# T20261020-131330: customer-support skill: automate the full lifecycle of a support issue (triage -> deliver)

## Problem

- **Type**: feature
- Part of epic T20261012-333879 (customer support skill track P1-P4); builds on T20261012-373882 (label lifecycle). `/customer-support` shipped in [PR #346](https://github.com/Synx-Data-Labs/ccxp-skills/pull/346); [PR #369](https://github.com/Synx-Data-Labs/ccxp-skills/pull/369) added the triage tracking-link comment and `--task`. Relates to T20261012-612044 in synxdb-build-pipeline (reconcile close-support-issue).
- Today each `/customer-support` subcommand (triage, start, deliver, links, request-confirm, accept, reject, block, needs-upstream) moves one step. The engineer chains them by hand and separately creates the task, claims, builds, verifies and publishes.
- Goal: given a support issue URL, one flow drives it end to end:
  - triage, create or link the backing task via `/new-task`, post the `--task` tracking comment
  - start (claim + label in-progress), then drive the task (e.g. `/drive`), including builds and releases when the issue is a package request
  - run the evidence gate (links/verify), deliver (label `delivered` + links comment), request-confirm
  - automatic blocked / needs-upstream handling, plus status reporting

## Design phase (merged from T20261019-311265)

T20261019-311265 ("Redesign customer-support as an orchestrator that drives /drive + /address-pr + /eta internally", research/design-only, staged in [PR #367](https://github.com/Synx-Data-Labs/ccxp-skills/pull/367), never on main) was folded into this task on 2026-10-21 (maintainer decision) so there is ONE orchestrator task. **The first deliverable is the design doc** (`repo-conventions/templates/design-doc.md`, scored by `design-score`); no implementation or edits to `customer-support/scripts/*.sh` / `SKILL.md` before it clears `/drive` Phase 2.

- **Problem (from 311265)**: `/customer-support` (T20261012-373882) is a passive label-state machine (`triage -> accepted -> in-progress -> delivered -> (closed)`, plus `blocked`/`needs-upstream`). A human or `/drive` calls its subcommands via `transition.sh` after the fact to mirror engineering milestones onto the issue. It never calls another skill and never reads `/drive` state.
- **Maintainer direction** (shine@synxdata.com, paraphrased): "the customer-support skill would call /drive and /address-pr as well as /eta when walking through the lifecycle of a given customer issue. not the other way around." Invert control: `/customer-support` is the orchestrator for an issue's whole lifecycle, not a label mirror waiting to be told what happened.
- **What surfaced it**: driving T20261016-412473 (SynxDB4 4.8.1 release, synxdb-support#30), the maintainer asked for hourly ETA updates on the issue plus immediate stall alerts. That needs cron-style scheduling (`ccxp-skills:schedule`), which was unusable from an interactive session (needs `RemoteTrigger`/`AskUserQuestion`). Bolting external scheduling onto a passive skill showed the real want: the skill should own the walk through `/drive` + `/address-pr` + `/eta`.
- **Proposed flow to design**: given `owner/repo#N`: (1) `triage`; (2) claim or require the backing task, then `/drive` it to completion; (3) `/address-pr` on the resulting PR(s), the same call pattern `/drive` Phase 5 already uses; (4) `/eta` (`eta/scripts/eta.sh T<id>`) and post progress/stall comments to the issue; (5) `deliver` through the unchanged evidence gate; (6) `request-confirm`; `accept` stays support-team-only (never automated).
- **Design scope**:
  - Inversion of control: top-level `run <issue>` that wraps the existing subcommands (alternatives rejected must be analysed), which stay callable standalone for manual walks and audits.
  - Scheduling for hourly ETAs and stall alerts via the `ccxp-skills:schedule` skill, versus milestone-triggered posting (claim, PR opened, CI green, merged), versus a hybrid. Record that interactive sessions cannot create schedules, so the design must say where the schedule is created and what runs without it.
  - Consent checkpoints: per issue and per action (builds, promotions, publishes), a dry-run first, with expiry.
  - Gate preservation: no orchestrator code path may reach `deliver_gate.sh` / `accept_gate.sh` behaviour or a label write other than through `transition.sh`; confirm explicitly and add bypass regression tests.
- **Findings so far**: none beyond the above (311265 was filed as research-only, no spike was done).

### Overlap with epic T20261012-333879 (P2 T20261012-949870, P3 T20261012-383399)

The ETA/status-reporting part of this orchestrator overlaps P2 (reporter engine in dry-run: `_support/cadence.sh`, `render-comment.sh`, `marker.sh`, `tick.sh`) and P3 (live reporting: `/customer-support report|status|stop`, scheduled tick via `actions/support-report`, consent at intake). Those phases assume the passive-mirror shape with an external cadence, so the design must reconcile them. Proposed split, to be confirmed by the design:

- **Orchestrator calls** (control flow): `/drive`, `/address-pr`, `transition.sh` subcommands, and `report`/`tick` as a step at milestones and on stall detection.
- **Orchestrator reuses, does not rebuild**: P2's cadence function, renderer with whitelist and deny-list lint, hidden marker dedup, and `tick.sh`; ETA numbers from `eta/scripts/eta.sh` as P2 already specifies; P3's per-task opt-in and first-comment human approval, and its scheduled tick (the scheduling answer for hourly updates).
- **Reshaped by this task**: P3's open "who runs the tick" question (Q7/Q8) is informed by the schedule-skill finding; if milestone-triggered posting is chosen, P2/P3 keep their engine but the scheduled tick becomes a stall-alert/heartbeat only. Update P2/P3 scope in the design PR rather than here.

## Design requirements (hard constraints)

- `accept` stays support-team-only and identity-gated; never automated.
- `deliver` stays evidence-gated, never self-reported (regression case: synxdb-support#21).
- Secrets (entitlement tokens, 1Password API keys via `op run`) are never printed, posted, or put on command lines.
- Real builds, promotions and publishes need explicit human consent per issue (consent checkpoint), and a dry-run first.
- Idempotent and resumable: re-entering resumes at the current label.
- All label writes go through `transition.sh`.

## Open questions

- Where does the orchestrator live: new subcommand (`run` / `auto`) or a new skill? Replace the current subcommands or wrap them (311265 (c); leaning wrap, keep them standalone)?
- Task existence: does the orchestrator auto-create/claim the backing task (`/new-task`) or require one to exist already (311265 (a))?
- ETA cadence: fixed (hourly via the schedule skill) or milestone-triggered, or hybrid (311265 (b))? Schedules cannot be created from an interactive session.
- How are long builds dispatched and awaited: background jobs or scheduled wakeups?
- How is consent captured (per issue, per action, expiry)?
- How is ETA reported (see `/eta`), and how does it reuse P2/P3's reporter engine (see Overlap section)?
- Cross-repo handling: hub synxdb-build-pipeline vs ccxp-skills.
- First real exercise: synxdb-support#30 (4.8.1 for i2c, delivered via manual chaining today) and #32 (PXF 4.5.4-3, T20261020-247249).

## Done criteria

- Design doc first (inversion of control, scheduling for hourly ETAs, consent checkpoints, P2/P3 reconciliation), clearing `design-score`.
- Implementation with bats tests, including gate-bypass regression tests (`accept` identity gate, `deliver` evidence gate, synxdb-support#21 case).
- Dry-run on a test issue.
- One real issue driven end to end.

## Decisions (2026-10-28)

Maintainer accepted the recommendations on the three open design questions. Design source: a private design note (not committed; it names real support issues). The content below is its sanitized summary, enough for a future `/drive` to implement.

### The three decisions

- **Home and name**: a new subcommand `/customer-support run <issue-ref>` of the existing skill, not a new skill.
  - Same `transition.sh` entrypoint, same gates; the 12 existing verbs stay standalone (manual walks, `audit`, `sweep`, `close-support-issue` depend on them).
  - Keep `SKILL.md` small: one table row plus a short pointer; orchestration prose in `customer-support/run.md`, deterministic planner in `customer-support/scripts/run_plan.sh`.
  - Do NOT name it `drive` (collides with `/drive`, which `run` calls).
- **Tracking comment**: `run` skips the `triage --task` comment by default and keeps the task link private.
  - The existing comment exposes an internal task ID, a hub repo path and a customer-bearing title in a customer-readable issue. That is a defect, tracked separately (T20261028-392844).
  - `transition.sh triage` gains `--no-task-comment`, which `run` always passes.
- **Scope of v1**: `run` does NOT automate the confirmation nudge (`request-confirm`) or ETA/stall comments.
  - The nudge is a drafted-then-approved text: v1 stops at `delivered` with NEEDS INPUT for a nudge draft.
  - ETA / status comments stay in epic phases P2/P3 (T20261012-949870, T20261012-383399).

### Design summary

- **Shape**: a stateless loop (observe, plan next step, execute or stop). State is derived from durable facts, never held by `run`:
  - lifecycle position = the single `status:*` label; backing task = `source-url:` frontmatter (dedup key)
  - work progress = task status, claim, PRs on the branch; draft approval = private draft file plus a `.sha256` sidecar
  - delivery done = `delivered` label AND a bot comment carrying a hidden `<!-- cs-delivered -->` marker
- **Steps**: intake (`/to-task`) -> triage (label only) -> claim + `start` -> `/drive T<id>` -> evidence (`links`, or `partner-download-url.sh` fallback, HTTP-verify each URL) -> draft customer reply to a private file -> STOP for approval -> post the exact approved text + `deliver --urls|--release` -> stop at `delivered`.
- **Idempotence**: every step checks "already done?" and skips; re-running on a delivered issue reports the next human action; `blocked` / `needs-upstream` report and exit.
- **Customer-visible text**: never posted directly.
  - A draft file is written, its path shown, NEEDS INPUT returned; on resume the post happens only if the file's sha256 matches the approved hash.
  - A mechanical lint fails the step on: task IDs (`T\d{8}-\d{6}`), customer org/person names, internal repo names or paths, long tokens outside evidence-step download URLs. Reuse the P2 renderer + deny-list lint (T20261012-949870) when it lands.
- **Hard gates**: each pauses with a dry-run and its own approval; the answer is scoped to (issue, action, resolved target) and expires with the session.
  - real build dispatch; tag creation/push; promote/publish to a customer-visible repo (incl. entitlement-token creation); manifest/default-version change; posting customer text
- **Never automated, no flag overrides**:
  - `accept`, `reject`, close, `sweep --apply` (support-team-only; `run` never reads `SUPPORT_TEAM_LOGINS` or passes `--actor`)
  - self-reported delivery (no `--force`; regression synxdb-support#21)
  - direct `labels.sh apply/toggle` (all label writes via `transition.sh`)
- **Background-job contract**: `run <ref> [--plan] [--until <step>]` never blocks on a prompt; last message is at most 10 lines: `OUTCOME: <step>`, issue state, then `DONE: awaiting support team` or `NEEDS INPUT: <one question>` plus the artifact path.
  - NEEDS INPUT points: reply-draft approval; each hard-gate dry-run; missing credential (never prompt for a secret); ambiguous target artifact; closed issue / PR URL.
  - Resume = re-spawn `run <ref>`; long builds exit with `OUTCOME: waiting on run <id>` instead of sleeping.
- **Edge cases to cover in tests**:
  - premature `delivered` without links (evidence gate blocks; refuse if the artifact is not in the customer-visible repo)
  - no SBOM for the package -> `partner-download-url.sh` fallback
  - `cloudsmith cp` needs the bare repo name, not `owner/repo` (detect before running)
  - customer clarification pending -> stop with `awaiting customer`
  - artifact platform tag differs from the issue's stated platform
  - customer comment after delivery -> report, do not close
  - non-support / PR URL / closed issue -> change nothing
  - task already Done -> resume from evidence
  - concurrent runs -> `claim` plus label check

### Implementation steps (about 11-12 points total; the frontmatter `estimation: 1` is revised by `/incept`, not here)

1. **Design doc** (1 pt): `repo-conventions/templates/design-doc.md` built from this section, scored by `design-score`; reconcile P2/P3 scope there.
2. **`scripts/run_plan.sh`** (2 pts): read-only planner (label + task + PR + marker -> `NEXT=<step> REASON=...`), BATS fixtures including a premature-deliver timeline; also serves `run --plan`.
3. **`scripts/draft_reply.sh` + lint** (2 pts): deny-list lint, private draft path (chmod 600), approval-hash check.
4. **`transition.sh`** (1 pt): `--no-task-comment` for `triage`; `cs-delivered` marker on `deliver`; BATS.
5. **Artifact-evidence helper** (2 pts): wraps `partner-download-url.sh`, HTTP-verifies URLs, checks the `cloudsmith cp` bare-repo form and artifact platform tag.
6. **`run.md` + `SKILL.md` row + evals** (2 pts): orchestration prose, `argument-hint` update, evals (`tool_not_called` accept/close, `command_not_ran` `gh issue close`).
7. **Bypass regression tests + dry-run + first real run** (1-2 pts): no `run` path reaches a label write outside `transition.sh`; `accept` unreachable; dry-run on a test issue, then the next real package request.

### Related

- Complementary to synxdb-build-pipeline T20261012-612044 (rewrites `close-support-issue` Phase 4 to call `deliver`/`links`/`accept`): land in parallel, do not merge. Add a cross-reference there once `run` exists (package/request issue -> `run`; bug issue -> `close-support-issue` Phases 1-3, optionally handing to `run` at evidence).
- `run` from ccxp-skills needs a hub clone for `partner-download-url.sh` (same ephemeral-clone pattern as `links.sh`).
- Defect found by this design, filed separately: `triage --task` leaks internal task details into a customer-visible comment (T20261028-392844).
