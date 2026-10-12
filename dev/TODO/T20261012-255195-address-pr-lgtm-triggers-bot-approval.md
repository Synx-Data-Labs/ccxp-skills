---
status: Design
estimation: 1
source: this conversation, 2026-10-12
claimed_by: cc1-50ac6891:4d9eb48c700d5e9a
claimed_role: interactive
---

# T20261012-255195: address-pr: an LGTM comment from the PR author triggers the bot approval

## Problem

- **Type**: feature
- User request (clarified): "in address-pr, if you see LGTM in the comment, means the writer already approved the PR. you can trigger the bot approval process." "Writer" = the PR author (the human who wrote/owns the PR).
- Today `/address-pr` dispatches the `pr-approve.yml` bot only after its own independent review returns a clean bill (`address-pr/SKILL.md:276-302`: workflow dispatch with `pr_number` and `commit_sha=HEAD_SHA`, then poll for an `APPROVED` review pinned to `HEAD_SHA`). A human LGTM comment is not recognized, so the PR stalls or the user gets a "needs approval" notification.
- The merge decision is `address-pr/SKILL.md:357` ("Follow the merge policy in `dev/guidelines.md` ... auto-merge tier, or notify for wait-for-approval tier"). The policy is `dev/guidelines.md:11-20`; this repo has no `dev/branch-merge-policy.md` (referenced by `/stage`), so tier definitions must be located before implementing.
- Staleness must stay consistent with `address-pr/SKILL.md:375` ("Never sneak changes into an approved PR").

## Proposed design (not decided)

- The LGTM comment is NOT itself treated as a GitHub approval. When address-pr sees a qualifying LGTM on the current head, it triggers the existing bot approval process (`pr-approve.yml` dispatch with `pr_number` and `commit_sha=HEAD_SHA`, poll for the `APPROVED` review pinned to `HEAD_SHA`) so a real APPROVE review lands. That real review is what satisfies `required_approving_review_count` on repos that enforce it.
- A qualifying LGTM is a comment (issue comment, review comment or review body) by the PR author; word-boundary, case-insensitive, "lgtm!" also fine. The author may be the account running the automation, so self-LGTM counts (no "not the author" rule); the automation's own comments do not.
- Guards:
  - Bots and the `**Claude Code review:**` comment (`address-pr/SKILL.md:235-263`) never count.
  - Staleness: an LGTM created before the latest push does not count; a re-LGTM is required.
  - Conservative match: the first non-empty line must begin with LGTM. "not LGTM", "LGTM but ...", quoted replies and code blocks do not count.
  - A later "hold" or "changes requested" revokes it.
- Where: `address-pr/scripts/has-lgtm.sh` with bats tests, called from the approval-gate dispatch; update `address-pr/SKILL.md` and the report wording ("approval triggered via LGTM by <user>").

## Open questions

1. Should LGTM replace or only supplement the independent-review clean bill as the trigger for dispatching the bot?
2. Who besides the author may trigger it (other write-access maintainers, checked via the collaborators permission API)?
3. Repos with no `pr-approve.yml`: nothing to trigger, so fall back to notify/wait (confirm).
4. Should address-pr post a reaction or ack comment when it accepts an LGTM?
