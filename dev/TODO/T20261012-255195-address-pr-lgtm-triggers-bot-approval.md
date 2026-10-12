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
- The merge decision is `address-pr/SKILL.md:357` ("Follow the merge policy in `dev/guidelines.md` ... auto-merge tier, or notify for wait-for-approval tier"). The policy lives only in `dev/guidelines.md:11-20` (verified: `dev/branch-merge-policy.md` does not exist in this repo; `drive/SKILL.md` cites it, a stale cross-repo reference, out of scope here).
- Staleness must stay consistent with `address-pr/SKILL.md:375` ("Never sneak changes into an approved PR").

## TLDR

- Add `address-pr/scripts/has-lgtm.sh <pr>`: exits 0 and prints the login only when the PR author's latest decisive comment after the last push is a clean `LGTM`.
- `address-pr/SKILL.md` step d calls it; a qualifying LGTM lets the existing `pr-approve.yml` dispatch (real `APPROVE` pinned to `HEAD_SHA`) fire when the review has no outstanding finding.
- LGTM supplements the independent review, never replaces it. It is not itself an approval, and branch protection is untouched.
- Repos without `pr-approve.yml` behave as today (notify/wait); the report just names the LGTM.

## Solution

### Assumptions (open questions answered with conservative defaults, user unreachable)

- **Q1 supplement, not replace.** The independent review for `HEAD_SHA` must still exist, and no finding may be unanswered (each fixed, or pushed back with a comment). Today the dispatch fires only on a fresh clean bill; with a valid LGTM it also fires when `LAST_REVIEWED_SHA == HEAD_SHA` or when all findings were answered by pushback, which is exactly where the PR stalled before. An LGTM never skips the review or silences an open finding.
- **Q2 author only.** Other write-access maintainers are deferred (would need the collaborators permission API plus a trust decision).
- **Q3 no `pr-approve.yml`.** Nothing is triggered; the existing notify/wait flow runs, and the report notes "LGTM seen, no approval workflow".
- **Q4 no ack comment or reaction.** The report line "approval triggered via LGTM by <user>" is the audit trail; the dispatched review is itself visible on the PR.

### Detector contract

- **Input**: PR number (live: `gh pr view --json author,commits,comments,reviews` plus `pulls/N/comments`), or `--from-json <file>` for the pure decision (used by tests).
- **Output**: exit 0 + login on stdout = qualifying LGTM; exit 1 + reason on stderr otherwise; exit 2 on usage, fetch, malformed-JSON or missing-author error (treated as "no LGTM", fail-safe).
- **Counts**: comments by the PR author (issue comment, review comment, or review body; current body, all pages, merged and sorted by timestamp across the three streams) created strictly after the push time. Optional `--after <iso>` raises that lower bound further.
- **Match**: first non-empty line, case-insensitive, is `lgtm` plus optional `!`/`.`/`,` and an optional short tail (`thanks`, `ship it`, `merge it`); anything else (`LGTM but ...`, `not LGTM`, quoted `>`, fenced code) does not count.
- **Never counts**: bot logins (`[bot]` suffix or `app/` prefix) and any body starting `**Claude Code review:**`.
- **Revoke**: first line starting `hold`, `do not merge`, `don't merge`, `wip`, `changes requested`, `needs changes`; the latest decisive comment (LGTM or hold) wins.
- **Push time** = the later of the newest commit `committedDate` and the newest `head_ref_force_pushed` timeline event (a rebase/amend keeps old commit dates, so the force-push event is needed). Residual gap: commit, then LGTM, then plain push can be misjudged; accepted because the review pinned to `HEAD_SHA` still has to exist.
- **Pushback path**: when findings were answered by pushback (not fixed), the skill passes `--after <time of our latest pushback comment>`, so the LGTM must postdate the pushback and cannot be a stale or automated one. If the PR author is the automation account itself, the LGTM is taken as the human operator's (assumption).
- **Guard stays platform-side**: the dispatch only requests a real `APPROVE`; `required_approving_review_count` and protection rules still decide merge.

### Alternatives rejected (alternative designs considered)

- LGTM as the sole trigger (skips independent review): rejected, unsafe default.
- Treat the comment itself as approval: rejected, does not satisfy `required_approving_review_count`.
- Any collaborator's LGTM: deferred, needs permission API and a policy decision.

## Test plan

- [ ] `tests/address_pr_has_lgtm.bats` (red first): author LGTM passes; `LGTM!`/`lgtm` pass; non-author, bot, `**Claude Code review:**`, stale (before push), `LGTM but`, `not LGTM`, quoted, fenced, later hold, hold then re-LGTM, review-body LGTM, empty input; one stubbed-`GH_SH` live-path test.
- [ ] Skill gates: `skill_score.py --check`, `test_skill_quality.py`, `bash _docs/lint-docs.sh`, shellcheck.

## Done criteria

- [ ] `has-lgtm.sh` implements the contract above: `tests/address_pr_has_lgtm.bats` (all cases green).
- [ ] `address-pr/SKILL.md` step d wires it in and the report wording is added: `address-pr/SKILL.md` approval-gate block (`grep -n has-lgtm address-pr/SKILL.md`).
- [ ] No skill-score regression: `skill_score.py --check dev/quality/skill-scores.json` passes (address-pr stays >= 61).
- [ ] Task citation gap fixed: this file cites `dev/guidelines.md:11-20`, not the missing policy file.

## Root cause

- Gap, not a regression: `address-pr/SKILL.md:276-302` dispatches the approval workflow only on a fresh clean bill from step d, and nothing reads human comments. Introduced with the gate in T20260922-603756 (deliberate: approval judgment was meant to be mechanical and automated); the human-LGTM signal was simply never modelled.

## Repo file references

| File | Role |
|---|---|
| `address-pr/SKILL.md:276-302` | approval-gate dispatch (verified) |
| `address-pr/scripts/auto-pick.sh` | pattern for stubbable `GH_SH` script (verified) |
| `tests/address_pr_auto_pick.bats` | pattern for hermetic bats (verified) |

## Closed

- Pending implementation PR.

## Skills invoked

- Design only so far; see Closed at task close.
