---
status: In Progress
estimation: 2
source: Owner decision d19, 2026-11-09 ("add a --force parameter to task_claim.sh, so that we can manually take over an existing task")
description: task_claim.sh acquire <id> --force takes over a task held by another claimant (manual use only)
claimed_by: cc1-50ac6891:9e4681d6b34224d4
claimed_role: interactive
related: T20261109-274750
scheduled: 2026-11-09
---

# T20261109-745828: `task_claim.sh acquire --force` for manual takeover

## Problem

- No verb can take over a task held by another claimant, live or stale; `reclaimable` only frees dead ones. A claim whose holder id matches no clone (see T20261109-274750) had to be hand-edited in a claim PR.
- The owner asked for an explicit manual override on `acquire`.

## Solution

- `acquire <id> --force`: when the holder is another claimant (any shape, live or not), re-stamp `claimed_by`/`claimed_role`, set `status: In Progress`, stamp `scheduled`; print `taken-over:<previous>` (exit 0).
- Loud stderr warning naming the previous claimant and saying the takeover was forced, plus the suggested commit-message line.
- Record: new runtime frontmatter key `claimed_takeover_from: <previous claimed_by>` (allowlisted in `lint_tasks.py`), cleared by `release` / `release-others`. The claim PR still edits the same `claimed_by:` line, so a concurrent claim still conflicts: the merge is the lock.
- Free or already-mine tasks: `--force` is a no-op (normal `acquired` / `mine`, nothing recorded).
- Unknown flag: usage error, exit 64.
- Never implied: no skill script passes `--force`; a BATS test greps for it. `/claim` documents it as manual-only (owner words required).

## Done criteria

- [ ] BATS: takeover from another and from a live claimant, no-flag unchanged, previous claimant recorded, exit codes, unknown flag, no caller passes `--force`.
- [ ] Docs: `_session/README.md`, `claim/SKILL.md`, `lifecycle.md`, release note in the close journal.
