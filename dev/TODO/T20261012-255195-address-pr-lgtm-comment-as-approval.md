---
status: Open
estimation: 1
source: this conversation, 2026-10-12
---

# T20261012-255195: address-pr: treat an LGTM comment from a user with write access as an approval

## Problem

- **Type**: feature
- User request: "in address-pr, if you see LGTM in the comment, means the write already approved the PR." Assumption to confirm: "write" means a collaborator with write/maintain/admin permission on the repo (a maintainer).
- Today, for PRs in the wait-for-approval tier, `/address-pr` only recognizes a real GitHub `APPROVE` review (the `pr-approve.yml` bot path pinned to `HEAD_SHA`, `address-pr/SKILL.md:276-302`). A human maintainer who comments "LGTM" is not recognized, so the PR stalls or the user gets a "needs approval" notification.
- The merge decision is `address-pr/SKILL.md:357` ("Follow the merge policy in `dev/guidelines.md` ... auto-merge tier, or notify for wait-for-approval tier"). The policy itself is `dev/guidelines.md:11-20` (Branch and Merge Policy); note this repo has no `dev/branch-merge-policy.md` (referenced by `/stage`), so the tier definitions live in consumer repos or must be located before implementing.
- The staleness rule must stay consistent with `address-pr/SKILL.md:375` ("Never sneak changes into an approved PR": new commits after approval make it stale; do not merge).

## Proposed design (not decided)

- In the merge decision, treat a PR comment (issue comment, review comment, or review body) containing LGTM (word-boundary, case-insensitive, also "lgtm!") by a user whose repo permission (collaborators permission API) is write, maintain or admin as satisfying the human-approval requirement.
- Safety rules:
  - Bot accounts and the Claude Code review comment itself (`**Claude Code review:**`, `address-pr/SKILL.md:235-263`) never count.
  - PR author self-LGTM does not count by default (see open question 2).
  - Pinned to the current head: an LGTM created before the latest push is stale. Compare comment `created_at` to the head commit's push time, or require a re-LGTM after new commits.
  - Conservative match: the comment's first non-empty line must begin with LGTM. "not LGTM", "LGTM but ...", quoted replies and code blocks do not count.
  - Revoked by a later "changes requested" review or a later "NOT LGTM"/"hold" comment from a maintainer.
  - Never overrides GitHub branch protection: if the repo requires an approving review count (platform gate), an LGTM comment cannot satisfy it. Applies only where approval is a policy gate.
- Where: `address-pr/scripts/has-lgtm.sh` with bats tests, called from the merge-gate decision; update `address-pr/SKILL.md` and the report wording ("approved via LGTM by <user>").

## Open questions

1. Exact meaning of "write": any collaborator with write access, or specific named approvers?
2. Does self-LGTM by the PR author count? This repo's PRs are authored by the same account running the automation, so a strict "not the author" rule makes LGTM unusable here. Options: allow the author when they have write access and the comment is not the automation's own bot comment, or require a different human.
3. Staleness rule: compare to head commit time vs. require re-LGTM after any push.
4. Should address-pr also post a reaction or ack comment when it accepts an LGTM?
