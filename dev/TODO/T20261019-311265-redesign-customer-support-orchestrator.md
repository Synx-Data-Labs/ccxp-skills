---
status: Open
estimation: 1
source: Conversation 2026-10-19, driving T20261016-412473 (SynxDB4 4.8.1 release / synxdb-support#30)
related: T20261012-373882
---

# T20261019-311265: Redesign customer-support as an orchestrator that drives /drive + /address-pr + /eta internally

## Problem

- **Type**: research (design-only; scope the architecture, do not implement)
- **Current design**: `/customer-support` (`customer-support/SKILL.md`,
  `T20261012-373882`) is a passive label-state machine for a
  `synxdb-support` issue: `triage -> accepted -> in-progress -> delivered
  -> (closed)`, plus `blocked`/`needs-upstream` modifiers. It is invoked
  **externally** — a human or `/drive` calls its subcommands (`triage`,
  `start`, `deliver`, `accept`, etc. via `transition.sh`, the single
  enforced entrypoint) to mirror real engineering milestones onto the issue
  *after the fact*. It never calls another skill itself.
- **Maintainer's explicit direction** (shine@synxdata.com, paraphrased):
  "the customer-support skill would call /drive and /address-pr as well as
  /eta when walking through the lifecycle of a given customer issue. not
  the other way around." I.e. invert control — `/customer-support` becomes
  the orchestrator for a given issue's whole lifecycle, not a label mirror
  waiting to be told what happened.
- **What surfaced this**: while driving `T20261016-412473` (SynxDB4 4.8.1
  release, tied to `synxdb-support#30`), the maintainer asked for hourly
  ETA updates posted to the issue plus immediate stall alerts. That turned
  out to need true cron-style scheduling (`ccxp-skills:schedule`), which
  was found unusable from an interactive session — it needs
  `RemoteTrigger`/`AskUserQuestion` tools not available here. The friction
  of bolting external scheduling onto a passive skill is what surfaced the
  real want: `/customer-support` should own walking the issue through
  `/drive` + `/address-pr` + `/eta` end-to-end itself, rather than needing
  an external scheduler to keep nudging it.

## Current vs. proposed control flow

- **Current** (external drive, passive mirror):
  - Human/`/drive` does real engineering work on some task.
  - Human/`/drive` separately remembers to call
    `transition.sh triage|start|deliver|...` against the `synxdb-support`
    issue to reflect that work's state.
  - `/customer-support` itself never reads `/drive`'s state, never invokes
    `/drive`, `/address-pr`, or `/eta` — it only writes labels/comments when
    told to, through the gates in `deliver_gate.sh` / `accept_gate.sh`.
- **Proposed** (orchestrator, drives others):
  - Given an issue (`owner/repo#N`), `/customer-support` itself:
    1. `triage`s the issue (`transition.sh triage`, as today).
    2. Claims (or requires — see Open Question (a)) the underlying
       engineering task, then invokes **`/drive`** on it to completion
       (claim → implement → PR → merge), instead of waiting for an
       external `/drive` session to report back.
    3. Invokes **`/address-pr`** on the resulting PR(s) — reuses `/drive`'s
       own Phase 5 call pattern (`/drive` already documents this exact
       move, e.g. `drive/SKILL.md` step "Run `/address-pr
       <claim-pr-number>`" — precedent for one skill's documented workflow
       literally naming another skill as a step).
    4. Periodically invokes **`/eta`** (`eta/scripts/eta.sh T<id>`) and
       posts progress/stall updates to the issue as comments — replacing
       the external-scheduler approach that doesn't work interactively.
    5. `deliver`s (`transition.sh deliver`, keeping the existing evidence
       gate — unchanged, still never self-reported).
    6. `accept`s (`transition.sh accept`, keeping the existing
       identity gate — unchanged, still support-team-only).
  - Net effect: `/customer-support` moves from being *told about* engineering
    milestones to *producing* them by driving `/drive`/`/address-pr`/`/eta`
    itself, then mirroring its own work onto the issue's labels.

## Open questions (maintainer raised, did not resolve — need a design decision before implementation)

- **(a) Task existence**: does the orchestrator auto-create/claim the
  backing engineering task (via `/to-task` or `/new-task`), or does it
  require one to already exist (filed separately, e.g. by `/to-task` at
  triage time today) before it will run?
- **(b) ETA cadence — fixed vs. milestone-triggered**: should ETA posting
  run on a fixed cadence (e.g. hourly), or be tied to real milestones
  (whenever `/drive` reports progress — claim, PR opened, CI green,
  merged)? **Note**: fixed-cadence hits the exact same `ccxp-skills:schedule`
  unavailability problem found this session (needs `RemoteTrigger`/
  `AskUserQuestion`, not available in an interactive session) — this alone
  may force the design toward milestone-triggered rather than
  clock-triggered, but that trade-off has not been decided.
- **(c) Replace vs. wrap the existing subcommands**: does the orchestrator
  *replace* the current label-transition subcommands, or *wrap* around
  them — e.g. a new top-level `/customer-support run <issue>` command that
  internally calls the existing `triage`/`start`/`deliver`/`accept`
  primitives (via `transition.sh`, unchanged) while keeping them callable
  standalone for the cases that don't want full orchestration (e.g. a
  human manually walking an issue, or an audit/correction)?

## Why this needs a real design pass, not a small tweak

- This is a genuine **architecture inversion**: control flow reverses from
  "driven by externally" (today: `/drive` or a human calls
  `/customer-support`'s subcommands after the fact) to "drives others"
  (proposed: `/customer-support` calls `/drive`, `/address-pr`, `/eta`
  itself). That is a different shape of skill, not a parameter or
  subcommand addition.
- It needs a full design PR with real alternatives-rejected analysis
  before implementation — per `repo-conventions/templates/design-doc.md`
  (TLDR / Problem / Context / Solution / Test plan / Done criteria), the
  same bar `/drive` Phase 2 gates on via `design-score` — not a quick
  patch to `transition.sh`.
- Touches the existing hard gates (`deliver_gate.sh` evidence gate,
  `accept_gate.sh` identity gate) only at the edges — those must remain
  intact and unbypassable under the new control flow; the design should
  explicitly confirm neither gate becomes reachable through a new
  orchestrator code path that skips `transition.sh`.
- Overlaps conceptually with the in-flight `T20261012-333879` epic
  (customer-support skill track P1-P4: status-reporter engine, dry-run,
  live reporting, CI enforcement/cadence tuning) and its children
  (`T20261012-949870`, `T20261012-383399`, `T20261012-278418`) — those
  tracks assume the current passive-mirror shape with an external
  reporting cadence; this redesign's outcome (especially Open Question
  (b)) may obsolete or reshape parts of that epic's remaining phases.
  Flagging the overlap here rather than guessing how to reconcile them —
  that reconciliation is itself part of the design work this task scopes.

## Scope note

- **Design only.** Do not implement, do not modify
  `customer-support/scripts/*.sh` or `SKILL.md` as part of filing this
  task. The next step is `/incept` or `/drive` Phase 2 (design doc), not
  code.
