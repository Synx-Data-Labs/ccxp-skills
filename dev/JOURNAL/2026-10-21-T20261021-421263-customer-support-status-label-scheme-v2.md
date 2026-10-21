---
status: Done
estimation: 3
source: this conversation, 2026-10-21 (user approved the new synxdb-support label scheme: "approved i8")
related: T20261021-266225
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261021-421263: customer-support: move to the status:* / type:* / severity:* / kb:* label scheme

## Problem

- **Type**: feature
- The synxdb-support labels are being renamed on GitHub (separate job); the skill must work before and after, so old names stay read aliases.
- Scheme: `status:new|triaged|in-progress|blocked|needs-upstream|delivered|wontfix|duplicate` (exactly one per issue, open or closed); `type:bug|enhancement|question`; `severity:1..4`; `kb:candidate|published`; `area:*`, `family:*`, `substrate:*`, `track:poc` unchanged. `invalid` dropped.

## TLDR

- `customer-support/scripts/label_names.sh` is the one mapping: new names, old names as read aliases (`cs-label-canon`, `cs-label-names`), `CS_STATUS_LABELS` for audit.
- `reject --reason wontfix|duplicate` swaps in the terminal `status:*` label, closes "not planned" / "duplicate". `invalid` rejected (exit 2).
- `blocked`/`needs-upstream` are statuses: `block` / `needs-upstream on` replace the status; `unblock` / `needs-upstream off` restore the previous status from the label timeline (fallback `status:triaged`).
- `accept` and the 14-day timeout close keep `status:delivered`; `sweep` matches delivered by current name or alias.
- `triage` accepts an issue with no status label (state `none` treated as new): covers legacy #20, #21, #23, #24, #25, #27.
- `audit` checks exactly one `status:*` across `--state all`.

## Test Plan

- [x] `bats tests/customer_support_*.bats` (135 tests) pass, including alias reads, none->triaged, timeline restore, reject reasons, closed-issue audit.
- [x] No real support issue touched (all gh calls stubbed via `CS_GH`).

## Notes

- Restoring `delivered` on unblock re-labels it, which restarts the sweep clock (intended).
- An issue still carrying an old stacked modifier (`triaged` + `blocked`) now counts as two statuses; `audit` flags it for a human.
