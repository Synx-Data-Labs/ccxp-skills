---
status: Open
estimation: 1
source: this conversation, 2026-10-10
related: T20260928-101526
---

# T20261010-363414: Replace the `synx-merge-bot` reference with a generic merge-bot explanation

## Problem

- **Type**: chore
- `address-pr/SKILL.md:259` names a company-specific `synx-merge-bot` App, which contradicts the "no company-specific dependency" promise in `CLAUDE.md`.
- Just dropping the name would leave the approval-gate block unexplained. Readers also need to know why a merge-bot exists at all:
  - Branch protection with `required_approving_review_count: 1` blocks automation, because a PR's author cannot approve their own PR.
  - A separate bot identity can submit a real `APPROVE` review, pinned to the commit that `/address-pr` just reviewed, so automation can merge without a bypass list.
  - The bot stays mechanical. The review judgment lives in `/address-pr`, not in the bot.
- Done looks like:
  - `address-pr/SKILL.md` uses a generic name (for example `merge-bot` or `approval-bot`) for the App and a generic workflow name.
  - The block gives short setup instructions (create a GitHub App, store its credentials, add an approve workflow) and the reasoning above.
  - `grep -rn synx-merge-bot` is clean outside historical journal records.
- Other mentions to clean up (verify with grep):
  - `dev/quality/skill-review-2026-09-28/README.md:33` and `batch2.md:42,46,137` (review records; reword or leave as dated history).
  - `dev/TODO/T20260928-101526-fix-skill-review-2026-09-28-findings.md:52` (item 6 lists this residue).
