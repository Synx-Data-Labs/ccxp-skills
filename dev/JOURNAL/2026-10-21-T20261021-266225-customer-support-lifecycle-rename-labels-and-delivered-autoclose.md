---
status: Done
estimation: 1
source: this conversation, 2026-10-21 (user request)
related: T20261012-373882
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261021-266225: customer-support lifecycle: rename labels (accepted->triaged, triage->new) and auto-close delivered issues after 14 days

## Problem

- **Type**: feature
- **A. Label rename** (user renamed the live labels): `accepted` -> `triaged`, `triage` -> `new`.
  - Verified 2026-10-21 via `gh label list --repo Synx-Data-Labs/synxdb-support`: `new`, `in-progress`, `triaged`, `blocked`, `needs-upstream`, `delivered` exist; `triage` and `accepted` do not.
  - Old names still hardcoded in `customer-support/SKILL.md:13`, `customer-support/scripts/{labels,audit}.sh` (`CS_PRIMARY_LABELS`), `state_machine.sh`, `transition.sh`, and `tests/customer_support_{audit,labels,transition}.bats`.
  - The `triage` subcommand keeps its name (it is the verb) but now moves `new` -> `triaged`.
  - Readers (audit, state machine) must alias old names to new so stale issues do not trip `audit`.
  - Do not rename the support-team `accept` subcommand (delivered -> closed).
  - Follow-up scan of synxdb-build-pipeline (read-only): no label-name references found, only `/customer-support` mentions in its task files; nothing to edit there.
- **B. Delivered timeout**: an issue in `delivered` for 14 days with no rejection is closed (completed) with an explanatory comment; support team or customer can reopen via the existing `start` revert path (`delivered -> in-progress`).
  - Clock starts when the `delivered` label was applied (issue timeline events API).
  - Skip `blocked` / `needs-upstream`; skip and flag issues with a comment from anyone other than the delivering account after delivery.
  - Idempotent; default dry-run, `--apply` to act; `--days` default 14.
  - New `sweep` subcommand through `transition.sh`, clearly distinct from identity-gated `accept` (marked close, comment prefix, not an acceptance).
  - Design PR decides whether a cron workflow calls it; otherwise file a follow-up task.
  - Update `SKILL.md`, lifecycle docs, and design reference T20261012-373882.
- Constraints: dry-run only against real issues (expect roughly #30, #32, #33 to be reported); no real issue is closed or relabelled; no Slack steps (escalations recorded in this file).

## TLDR

- **Type**: feature (two linked changes to `customer-support`: label rename + delivered timeout).
- Rename primary labels in code/docs/tests: `triage` -> `new`, `accepted` -> `triaged`; old names stay as read-side aliases (`cs-sm-canon`) so stale issues pass `audit` and the state machine. The `triage` subcommand keeps its name.
- New `transition.sh autoclose` + read-only-by-default `sweep.sh` (`--days 14`, `--apply`): closes `delivered` issues idle for 14 days as `completed`, with a marked "NOT an acceptance" comment.
- Timeout close is distinct from `accept`: `accept` stays identity-gated; `autoclose` is gated by its own re-verified eligibility check and keeps the `delivered` label as the signature, so a reopen routes through `start` (`delivered -> in-progress`).
- No cron in this PR (design decision below); follow-up task filed instead.

## Context

- Verified 2026-10-21 (`gh label list`): live labels are `new`, `triaged`, `in-progress`, `delivered`, `blocked`, `needs-upstream`; `triage`/`accepted` are gone (verified).
- Code sites using old names (verified by `git grep`): `customer-support/scripts/state_machine.sh:8,20,31-60`, `labels.sh:11`, `audit.sh:16`, `transition.sh` comment on `triage`, `SKILL.md:12-13,31-32`, `tests/customer_support_{audit,labels,transition}.bats`.
- No `to-task` / `close-support-issue` reference to the old label names exists in this repo (verified; `close-support-issue` lives in synxdb-build-pipeline, whose repo has no label-name references either — verified read-only, only `/customer-support` mentions in task files).
- Design reference: `dev/JOURNAL/2026-10-12-T20261012-373882-support-status-label-lifecycle-design.md` (taxonomy §1, transitions §2); this task amends both.

## Solution

- **Central label mapping** (coordinator request: another rename, e.g. `domain:value`, is being proposed but is NOT decided — do not implement it): new `customer-support/scripts/label_names.sh` is the ONLY place label names appear: `CS_L_NEW`, `CS_L_TRIAGED`, `CS_L_IN_PROGRESS`, `CS_L_DELIVERED`, `CS_L_BLOCKED`, `CS_L_NEEDS_UPSTREAM`, reject labels, the alias list and `CS_PRIMARY_LABELS`. `state_machine.sh`, `labels.sh`, `transition.sh`, `audit.sh`, `sweep.sh` source it; tests read the same variables where practical. A future rename = edit that one file (plus adding the previous names to the alias list).
- **A. Rename.** `CS_PRIMARY_LABELS="new triaged in-progress delivered"` defined in `label_names.sh`; `CS_LABEL_ALIASES="triage=new accepted=triaged"`.
  - `cs-sm-canon <label>` (state_machine.sh) maps an old name to the new one; `cs-sm-next` canonicalises `current` first, so `triage` on an issue still labelled `triage` works.
  - Readers (`cs-labels-primary`, `cs-audit-check`) recognise old names as primaries; `cs-labels-primary` prints the label actually present (so `--remove-label` hits the real label) and the state machine canonicalises it. Writers only ever add new names.
  - Alternative rejected: one-shot relabel script (would touch real issues; aliases are enough for stale ones).
- **B. Timeout rule.** Eligible iff all hold, evaluated by the pure `cs-sweep-eval` (jq over the timeline JSON, no I/O):
  - issue open with `delivered`; none of `blocked` / `needs-upstream`;
  - clock = `created_at` of the LAST `labeled delivered` timeline event (events API, not issue `updated_at`); age >= `--days` (default 14, floor 1: `--days` < 1 is rejected by `autoclose` itself, so neither `sweep --apply` nor a direct call can close a fresh delivery);
  - no `reopened` event after that label event; no comment after it from anyone other than the label's actor (our delivering account) -> `FLAG needs human`, never closed. Comments carrying the `<!-- cs-autoclose -->` marker are ignored by this check (our own sweep comment must not flag the issue after a failed close).
  - Timeline is fetched with `gh api --paginate --slurp` and flattened, so a long thread cannot hide the last `labeled delivered` event; author = `.actor.login // .user.login`.
  - Output lines: `#N: WOULD CLOSE (delivered Xd ago)`, `#N: SKIP <reason>`, `#N: FLAG <reason>`. Default dry-run; `--apply` calls `transition.sh autoclose` per eligible issue.
- **Single entrypoint.** `transition.sh autoclose <repo> <issue> [--days N]` re-fetches timeline + labels and re-runs `cs-sweep-eval` itself (so a direct call cannot bypass the rules), posts the comment, then closes; if the marker comment already exists (a previous run closed-failed after commenting) it skips the comment, so a retry never double-posts. No modifier clearing (eligibility requires none). `state_machine.sh` gets `autoclose`: `delivered` -> `CLOSED:timeout` (distinct from `accept`'s `CLOSED:completed`). `cs-labels-apply` special-cases `CLOSED:timeout` BEFORE its unconditional old-label removal: it skips that removal, closes with reason `completed`, and leaves `delivered` (tested explicitly).
- **Distinguishable from acceptance.** Comment starts `**Auto-closed (not accepted):**` plus hidden marker `<!-- cs-autoclose -->`, says: closed after N days with no reject or reply, this is NOT a support-team acceptance, support team or customer can reopen it, then `start` moves `delivered -> in-progress`. The marker comment is the authoritative signature of a timeout close; the retained `delivered` label is secondary (a manual close of a delivered issue also leaves it). A real accept clears the label. A reopened issue is FLAGged (not re-closed) until someone runs `start`.
- **Scheduling decision: no cron here.** The sweep needs a token with write access to synxdb-support (cross-repo secret) and the support team should first see a real dry-run list; filed as a follow-up task (workflow in synxdb-support calling `sweep.sh --apply`). Alternative rejected: ccxp-skills cron (wrong repo for a customer-data token).
- Docs: `customer-support/SKILL.md` (table, workflow, notes), `lifecycle.md`/`glossary.md` if they mention the states (verified none do), and a dated amendment note on the T20261012-373882 journal doc.

## Test plan

- BATS (fakes via `CS_GH` + `CS_NOW`, no real issue touched): `tests/customer_support_sweep.bats` (eligible, too young, blocked, needs-upstream, foreign comment -> FLAG, own comment ok, reopened, relabelled-delivered clock reset, dry-run makes no write call, `--apply` comments then closes, idempotent on closed list, `--days` override).
- Updated: `customer_support_{audit,labels,transition}.bats` for new names plus alias cases (`triage`/`accepted` labelled issues pass audit; `triage` subcommand on an old-labelled issue works).
- Real-world check: dry-run only against `Synx-Data-Labs/synxdb-support`; list reported in Closed.

## Done criteria

- [x] Primary labels renamed with aliases — `tests/customer_support_audit.bats`, `tests/customer_support_labels.bats`, `customer-support/scripts/state_machine.sh`.
- [x] `triage` moves `new` -> `triaged` via the single entrypoint — `tests/customer_support_transition.bats`.
- [x] Sweep eligibility rules and dry-run default — `tests/customer_support_sweep.bats`.
- [x] `autoclose` goes through `transition.sh`, comment marked, `delivered` kept — `tests/customer_support_sweep.bats`.
- [x] `accept` still identity-gated, unchanged — existing `tests/customer_support_transition.bats`.
- [x] `SKILL.md` and T20261012-373882 doc updated — `customer-support/SKILL.md`, reviewed by `doc-impact.sh`.
- [x] Dry-run list recorded; follow-up cron task filed — `## Closed`.

## Escalations

- None (no Slack steps in this job; nothing needed a decision from the maintainer).

## Closed (2026-10-21)

- Shipped in ccxp-skills PR #400 (design PR #398). Central label mapping: `customer-support/scripts/label_names.sh` (coordinator request; a future `domain:value` rename edits that file only — NOT implemented, undecided).
- Met: label rename with old-name aliases (audit/state machine/primary lookup), `triage` verb `new -> triaged`, `sweep.sh` + `transition.sh autoclose` (dry-run default, `--days` floor 1, marker comment, `delivered` kept), SKILL.md + design reference amended; `bats tests/customer_support_*.bats` 110/110 green.
- Review caught one real bug in my own code (gate called under `||` so `--days 0` bypassed the floor); fixed with a test.
- Dry-run against real synxdb-support (read-only, 2026-10-21 19:00Z): `#30`, `#31`, `#32` all got `delivered` TODAY (00:22Z, 18:47Z, 06:42Z), so 0 would close now and 0 flagged; they become eligible 2026-11-04 (`#30`) / 2026-11-04+ if no outside comment. `#33` is `triaged`, not delivered. Nothing was closed or relabelled.
- doc-impact flagged `ccxp/SKILL.md` (matches an unrelated `sweep.sh` in `/todo`): reviewed, no change needed.
- Quality probe: shellcheck_info/max_fn_lines/file_loc regressed (new script + tests added), recorded in `dev/quality/metrics.jsonl`; record+warn only.
- synxdb-build-pipeline follow-ups: none for label names (read-only scan found only `/customer-support` mentions in its task files; `close-support-issue` there should be re-checked when T20261012-612044 lands).
- Follow-up filed: T20261021-291375 (schedule the sweep; needs synxdb-support write token).
- Escalations: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): partial — tests written alongside the code; the BATS run exposed the `--days 0` gate bug before the PR.
- Verification (`superpowers:verification-before-completion`): yes — full customer_support BATS run before PR, `/address-pr` gate.
- Systematic debugging (`superpowers:systematic-debugging`): no — one failing test, root cause obvious (`set -e` suppressed under `||`).
- Receiving code review (`superpowers:receiving-code-review`): yes — design PR review, 4 findings fixed, 0 pushbacks.
