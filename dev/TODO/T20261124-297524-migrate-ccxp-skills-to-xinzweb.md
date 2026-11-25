---
status: Open
estimation: 1
needs: [owner-decision]
source: owner request, job 1545, 2026-11-24
description: Migrate ccxp-skills from the Synx-Data-Labs org to xinzweb (not authorized to start until the owner says go)
---

# T20261124-297524: Migrate ccxp-skills from Synx-Data-Labs/ to xinzweb/

## Problem

- **Type**: chore
- **Owner's words**: "for the ccxp-skills, create a new task, that I want to migrate it from synx-data-labs/ org to xinzweb/ tag."
  - "tag" is read as a typo for org/account, so the target is `xinzweb/ccxp-skills`.
  - **NOT AUTHORIZED TO START until the owner says go.** This task only records the plan and open questions; nothing is transferred, renamed, archived or changed on GitHub by filing it.
- **Today**: `Synx-Data-Labs/ccxp-skills` is a PUBLIC repo, default branch `main`; the active `gh` profile on this machine is `xinzweb` (a second profile, `75033us`, also exists).
- **Done looks like**: the repo lives at `xinzweb/ccxp-skills`, every consumer still installs, updates and releases from it, and the open questions below are answered and recorded.

## Open questions (decide with the owner; do not decide here)

- **Target account**
  - Is `xinzweb` a user account or an org? A user target changes the transfer flow, team and permission mapping, and GitHub App availability.
  - The transferring user needs admin on the source repo and create-repo rights on the target.
- **Ownership, IP and licence**
  - This is currently a Synx-Data-Labs company repo; company/owner approval is required before any transfer.
  - Confirm the licence file and copyright holder still make sense under the new owner, and whether contributors or CLA terms are affected.
- **Visibility**: public vs private after the move (currently public); who may see issues, PRs and releases.
- **Redirects**
  - GitHub redirects the old URL after transfer for web, git and API.
  - The redirect breaks if a new repo is later created at the old `Synx-Data-Labs/ccxp-skills` name; decide whether to reserve that name.
  - Marketplace and plugin source URLs (users' settings and plugin caches)
    - Inventory every place that names `Synx-Data-Labs/ccxp-skills`: `.claude-plugin/marketplace.json`, `plugin.json`, README install lines.
    - Decide the `/plugin` update path for existing users: rely on the redirect, or ask them to re-add the marketplace.
- **Actions and secrets**
  - List repo-level secrets and variables, org-level secrets the repo uses, and org-level runners or settings it depends on; none transfer with the repo.
  - List bot GitHub App installs (for example the `synx-merge-bot` approval gate in `pr-approve.yml`); re-install or replace on the new owner.
  - Never record secret values in this task.
- **Releases and tags**
  - Tag format is `ccxp-skills--v<ver>` (latest `ccxp-skills--v6.7.0`); confirm tags and releases carry over and release URLs still resolve.
  - Check anything that hard-codes release or tarball URLs.
- **Consumer repos**
  - Find repos that reference the repo (for example `synxdb-build-pipeline`, `lifecycle.md` consumers, `dev/` pointers back to the canonical source) and list what each must change.
  - Do not edit them under this task without an explicit per-repo go.
- **HUD**: the HUD version cell URL and the unreleased-commits lookup (`hud/scripts/`) point at the old owner/repo; decide how they are repointed and whether the redirect is relied on in the interim.
- **CI and repo settings**
  - Branch protection and rulesets, required checks and `required_approving_review_count` must be re-created or verified on the new owner.
  - Open issues and PRs: transfer keeps them, but assignees, labels and mentions of org members may break.
- **gh account profiles**: which profile (`xinzweb`, `75033us`) jobs use, and whether job config, clones and remotes in `~/workspace/synx-data-labs/` need switching.

## Suggested step order (once the owner says go)

- **Prepare**
  - Get written owner and company approval (IP, licence, visibility).
  - Answer every open question above; freeze merges during the move.
  - Inventory secrets, apps, consumer references and hard-coded URLs.
- **Move**
  - Transfer the repo (or, if policy requires, mirror then archive the old one); verify the redirect.
  - Re-create secrets, re-install apps, re-apply branch protection; run CI on a docs-only PR to prove it.
- **Repoint**
  - Update marketplace and plugin source URLs, HUD lookups, consumer repos and local remotes and clones.
  - Cut a patch release and test `/plugin update` from a clean and an existing install.
- **Close**: announce the new location, then journal the task.

## Rollback

- A transfer can be reversed by transferring the repo back to `Synx-Data-Labs`, provided nothing has been created at the old name.
- Keep the old owner's admin access and an offline `git clone --mirror` taken before the move.
- Restore any changed URLs in consumers by reverting their PRs; secrets and app installs must be re-created, so keep their inventory.
